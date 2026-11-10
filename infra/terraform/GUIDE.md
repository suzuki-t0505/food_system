# Terraform 構成の解説

`infra/terraform/` の各設定について、**何をしているか・なぜ必要か・設定しないとどうなるか**をまとめる。
手順は [README.md](README.md)、設計の経緯は [.steering/20261105-gcp-terraform/design.md](../../.steering/20261105-gcp-terraform/design.md) を参照。

- 対象: `infra/terraform/` の全 `.tf`(プロバイダ `hashicorp/google ~> 8.10`)
- 「しないとどうなるか」のうち GCP の既定値に関わる記述は、GCP / プロバイダの一般的な挙動に基づく。実環境で確かめたものではないため、値を変えるときは `terraform plan` と公式ドキュメントで確認すること

## 目次

1. [全体像](#1-全体像)
2. [versions.tf — バージョンと state の置き場所](#2-versionstf--バージョンと-state-の置き場所)
3. [variables.tf — 変数](#3-variablestf--変数)
4. [apis.tf — API の有効化](#4-apistf--api-の有効化)
5. [network.tf — VPC](#5-networktf--vpc)
6. [sql.tf — Cloud SQL](#6-sqltf--cloud-sql)
7. [secrets.tf — 共有の秘密](#7-secretstf--共有の秘密)
8. [registry.tf — Artifact Registry](#8-registrytf--artifact-registry)
9. [apps.tf — 2 アプリの呼び出し](#9-appstf--2-アプリの呼び出し)
10. [modules/app — 1 アプリ分のリソース](#10-modulesapp--1-アプリ分のリソース)
11. [lb.tf — ロードバランサ](#11-lbtf--ロードバランサ)
12. [armor.tf — Cloud Armor](#12-armortf--cloud-armor)
13. [ci.tf — GitHub Actions からのデプロイ](#13-citf--github-actions-からのデプロイ)
14. [outputs.tf — 出力](#14-outputstf--出力)
15. [tests/plan.tftest.hcl — テスト](#15-testsplantftesthcl--テスト)
16. [設定同士の依存関係(片方だけ変えると壊れる組)](#16-設定同士の依存関係片方だけ変えると壊れる組)
17. [運用上の注意点](#17-運用上の注意点)

---

## 1. 全体像

![GCP インフラ構成図](architecture.svg)

- 実線は通信・操作、青の太線は発送 → 在庫の内部 API 呼び出し、橙の破線は遮断される経路、灰色の破線は設定の適用・参照
- **Cloud Run は VPC のサブネットの中には無い。** Google が管理する基盤で動き、外向きの通信だけが Direct VPC egress でサブネットを通る(各インスタンスがサブネットの IP を 1 つ使う)。受信は LB から届き、サブネットは通らない
- デプロイ用 SA の「Cloud Run の更新」は 2 つのサービスと 2 つの Job が対象。Secret Manager も全サービス・Job が参照する。図ではそれぞれ矢印 1 本にまとめている

| 経路 | 結果 | 効いている設定 |
| :-- | :-- | :-- |
| 利用者 → LB → Cloud Run | 通る | ホスト名で在庫・発送に振り分け。WAF とレート制限を通過したものだけ |
| 利用者 → `*.run.app`(直接) | 届かない | Cloud Run の `ingress` を「内部と LB のみ」に制限 |
| 利用者 → LB → 在庫の `/api` | 403 | Cloud Armor の優先度 100 のルール |
| 発送 → 在庫 `/api/v1` | 通る | 発送の `egress = "ALL_TRAFFIC"`、サブネットの Private Google Access、Bearer トークン |
| Cloud Run・Job → Cloud SQL | 通る | Direct VPC egress と VPC ピアリング。Cloud SQL にパブリック IP は無い |
| 発送 → インターネット | 出られない | 全通信が VPC を通り、Cloud NAT が無いため |
| GitHub Actions → GCP | `dev` ブランチのみ | Workload Identity Federation の条件。サービスアカウントキーは作らない |

守りたいことは 4 つで、ほとんどの設定はこのどれかのためにある。

| 守りたいこと | 実現している設定 |
| :-- | :-- |
| 外部からの入口を LB の 1 か所に絞る | Cloud Run の `ingress`、Cloud SQL の `ipv4_enabled = false` |
| 在庫 API(`/api`)を外部に出さない | Cloud Armor の優先度 100 のルール、発送の `egress = "ALL_TRAFFIC"`、サブネットの Private Google Access |
| 秘密情報をコード・イメージ・環境変数の平文に置かない | `random_password` → Secret Manager → `secret_key_ref` |
| 長期間有効な鍵を作らない | Workload Identity Federation(`ci.tf`) |

ファイルの役割:

| ファイル | 役割 |
| :-- | :-- |
| `versions.tf` | Terraform / プロバイダのバージョン、state の保存先 |
| `variables.tf` / `outputs.tf` | 入力と出力 |
| `apis.tf` / `registry.tf` / `network.tf` / `sql.tf` / `secrets.tf` | 2 アプリで共有する基盤 |
| `apps.tf` + `modules/app/` | アプリごとのリソース(同じ形なのでモジュール化) |
| `lb.tf` / `armor.tf` | 公開の入口と防御 |
| `ci.tf` | 自動デプロイの認証と権限 |

---

## 2. versions.tf — バージョンと state の置き場所

| 設定 | なぜ必要か | 設定しないとどうなるか |
| :-- | :-- | :-- |
| `required_version = ">= 1.9"` | `terraform test` の `mock_provider`(1.7 以降)や、変数の `validation` で他の値を参照する機能(1.9 以降)を前提にしているため | 古い Terraform で実行したとき、原因の分かりにくい構文エラーになる。指定があれば「バージョンが古い」と明示される |
| `google = "~> 8.10"` | `~>` は「8.10 以上、9.0 未満」。メジャーバージョンが上がると属性の名前や既定値が変わることがある | 指定がないと `init` のたびに最新を取りにいき、ある日突然 `plan` に意図しない差分やエラーが出る |
| `random = "~> 3.9"` | パスワード・トークンの生成に使う。理由は上と同じ | 同上 |
| `.terraform.lock.hcl`(コミットする) | 各プロバイダの正確なバージョンとハッシュを固定する | 作業者・CI ごとに違うバージョンが入り、同じコードで結果が変わる |
| `backend "gcs" {}`(中身は空) | state を GCS に置く。バケット名は `backend.hcl` で `init` 時に渡す(部分設定)。バケット名にはプロジェクト ID を含めるため、コミット対象に書かない | `backend` ブロック自体が無いと state は作業者の PC のローカルファイルになる。PC の故障で state を失うと Terraform は既存リソースを「無いもの」と見なし、再作成しようとして名前の衝突で失敗する。複数人での同時 `apply` を防ぐロックも効かない |
| `provider "google"` の `project` / `region` | 各リソースで省略したときの既定値になる | すべてのリソースに `project` / `region` を書く必要があり、書き漏らすとエラーになる |

**state には秘密が入る。** `random_password` の結果(DB パスワード・`SECRET_KEY_BASE`・在庫 API トークン・初期管理者パスワード)は state に平文で保存される。そのため README では state バケットを `--uniform-bucket-level-access --public-access-prevention` で作り、バージョニングを有効にしている(誤って壊したときに前の版へ戻せる)。バケットを読める人は全秘密を読める、と考えること。

---

## 3. variables.tf — 変数

| 変数 | 既定 | 補足 |
| :-- | :-- | :-- |
| `project_id` / `domain` / `initial_admin_email` / `food_*_image_tag` | なし(必須) | 環境ごとに違う値・コミットしたくない値。既定を持たせないことで、指定漏れを `plan` の時点でエラーにする |
| `region` | `asia-northeast1` | Cloud Run・Cloud SQL・Artifact Registry・サブネットで共通に使う。ばらばらのリージョンにするとリージョン間の通信になり、遅延と転送料金が増える |
| `db_tier` | `db-f1-micro` | 共有コアの最小。コスト優先の値で、SLA の対象外・接続数が少ない([17 章](#17-運用上の注意点)) |
| `deletion_protection` | `true` | Cloud SQL を `destroy` や再作成から守る。`false` のまま運用すると、再作成を伴う変更(例: インスタンス名の変更)を `apply` しただけで DB とバックアップが消える |
| `min_instances` | `0` | アクセスが無いときはインスタンス 0(課金なし)。代わりに、しばらく空いたあとの最初のアクセスは起動待ち(コールドスタート)が入る。常に即応させたいなら `1` |
| `max_instances` | `2` | 暴走やアクセス集中時のコスト上限であり、DB 接続数の上限でもある(インスタンス数 × `POOL_SIZE` が DB に張られる) |
| `allowed_source_ranges` | `[]` | 空なら誰でもアクセス可。CIDR を入れるとそれ以外を 403 にする |
| `rate_limit_per_minute` | `600` | IP ごとの上限。LiveView は 1 画面でも複数のリクエストを出すので、低くしすぎると通常の操作で 429 になる |
| `github_repository` / `github_deploy_branch` | このリポジトリ / `dev` | デプロイを許可する GitHub 側の相手 |

`validation` を付けている理由:

| 対象 | 検証 | 無いとどうなるか |
| :-- | :-- | :-- |
| `allowed_source_ranges` | 10 件以下 | Cloud Armor の 1 ルールに書ける CIDR は 10 件まで。検証が無いと `apply` の途中で API エラーになる(`plan` は通ってしまう) |
| `github_repository` | `owner/repo` 形式 | 形式が違ってもリソースは作れてしまい、「デプロイが認証エラーになる」という分かりにくい形で発覚する |
| `github_deploy_branch` | 空でない | 空だと条件が `refs/heads/` となり、どのブランチからも認証できなくなる |

---

## 4. apis.tf — API の有効化

GCP はプロジェクトごとに、使うサービスの API を有効化する必要がある。**有効化していない API のリソースは作れない**(`API has not been used in project ... or it is disabled` のエラー)。

| API | 使っているリソース |
| :-- | :-- |
| `compute` | VPC・サブネット・LB・Cloud Armor・証明書 |
| `run` | Cloud Run サービス・Job |
| `sqladmin` | Cloud SQL |
| `servicenetworking` | Cloud SQL のプライベート IP(プライベートサービス接続) |
| `secretmanager` | Secret Manager |
| `artifactregistry` | コンテナイメージの置き場 |
| `cloudbuild` | 初回構築時の `gcloud builds submit`(README の手順 4) |
| `iam` / `iamcredentials` / `sts` | サービスアカウントと Workload Identity Federation。`sts` が GitHub のトークンを GCP のトークンへ交換し、`iamcredentials` がサービスアカウントの短命トークンを発行する |

| 設定 | なぜ必要か | 設定しないとどうなるか |
| :-- | :-- | :-- |
| `for_each = toset(local.services)` | API ごとに 1 リソースにする | `count` で書くと、リストの途中に API を足したときに番号がずれ、後ろの API が「削除 → 作成」の差分になる |
| `disable_on_destroy = false` | `terraform destroy` で API を無効化しない | `true` だと `destroy` 時に API を無効化しようとする。同じプロジェクトで Terraform 管理外のリソースがその API を使っていると、それも止まる(または無効化が失敗する) |
| 各リソースの `depends_on = [google_project_service.this]` | API の有効化が終わってからリソースを作らせる | Terraform は依存関係の無いリソースを並行して作るため、有効化より先にリソース作成が走り、初回の `apply` が失敗する(再実行すれば通るが、毎回それでは困る) |

---

## 5. network.tf — VPC

VPC を作る目的は 2 つ。Cloud SQL をプライベート IP だけで使うことと、発送 → 在庫の呼び出しを「内部トラフィック」にすること。

### 5.1 VPC とサブネット

| 設定 | なぜ必要か | 設定しないとどうなるか |
| :-- | :-- | :-- |
| `auto_create_subnetworks = false` | 使うサブネットだけを自分で定義する | `true` だと全リージョンにサブネットが自動で作られる。使わない IP 範囲が広く確保され、後述の `/16` の予約範囲や将来の VPC 接続と範囲がぶつかりやすくなる |
| サブネット `10.10.0.0/24` | Cloud Run の Direct VPC egress は、インスタンスごとにこのサブネットの IP を使う | サブネットが無いと Cloud Run を VPC につなげない。`/24`(約 250 個)は最大インスタンス数 2 × 2 アプリ + Job に対して十分な余裕。Cloud Run の最小は `/26` |
| `private_ip_google_access = true` | VPC の中から、外部 IP なしで Google の API や `*.run.app` に届くようにする。**発送 → 在庫の呼び出しを内部トラフィック扱いにするための条件** | 発送は `egress = "ALL_TRAFFIC"` で全通信を VPC に流している。この設定が無いと、VPC には外へ出る経路(Cloud NAT)が無いため `*.run.app` に届かず、発送から在庫 API を呼べなくなる。Secret Manager など Google API への通信にも影響する |

### 5.2 プライベートサービス接続(Cloud SQL 用)

Cloud SQL のインスタンスは利用者の VPC の中ではなく、Google が管理する別の VPC に作られる。その VPC と自分の VPC を**ピアリング**でつなぐのがプライベートサービス接続。

| 設定 | なぜ必要か | 設定しないとどうなるか |
| :-- | :-- | :-- |
| `google_compute_global_address`(`purpose = "VPC_PEERING"`、`address_type = "INTERNAL"`) | Google 側のサービスに割り当てる IP 範囲を、自分の VPC の中で予約する | 予約が無いと接続を作れず、Cloud SQL にプライベート IP を付けられない |
| `prefix_length = 16` | 予約する範囲の大きさ。範囲はアドレスを書かず、GCP に空きから選ばせている | 小さすぎると、Cloud SQL のインスタンスや他のマネージドサービスを足したときに IP が足りなくなる。あとから広げるのは手間がかかる |
| `google_service_networking_connection` | 予約した範囲を使ってピアリングを張る | 無いと Cloud SQL の作成が「プライベートサービス接続が無い」というエラーで失敗する |
| `deletion_policy = "ABANDON"` | `destroy` のとき、接続を削除しようとせず Terraform の管理から外すだけにする | Cloud SQL を消した直後は Google 側の後片付けが残っていて、接続の削除が「まだ使用中」で失敗することがある。その場合 `destroy` が途中で止まる。`ABANDON` にしておけば、VPC の削除と一緒にピアリングも消える |

---

## 6. sql.tf — Cloud SQL

1 つのインスタンスに DB を 2 つ(`food_vault` / `food_ship`)置く。インスタンスを分けないのはコストのため(インスタンスが課金の単位)。DB とユーザーはアプリごとに分けている([10.1](#101-db-と-db-ユーザー))。

| 設定 | なぜ必要か | 設定しないとどうなるか |
| :-- | :-- | :-- |
| `database_version = "POSTGRES_15"` | メジャーバージョンを固定する | 必須項目。バージョンを上げるのは影響の大きい作業なので、意図して変える |
| `edition = "ENTERPRISE"` | 共有コアの `db-f1-micro` を使えるのは Enterprise エディション | エディションとマシンタイプが合わないと作成時にエラーになる。明示しておけば、既定値の変更に左右されない |
| `tier = var.db_tier` | マシンの大きさ。変数にして環境ごとに変えられるようにする | — |
| `availability_type = "ZONAL"` | 1 つのゾーンだけで動かす(待機系なし) | `REGIONAL` にすると別ゾーンに待機系ができ、ゾーン障害時に自動で切り替わるが、料金はおよそ 2 倍。今はコストを優先している。**ゾーン障害時は復旧まで両システムが止まる** |
| `disk_autoresize = true` | ディスクが埋まりそうになると自動で広げる | 無効だとディスクが満杯になった時点で書き込みができず、アプリが止まる。なお自動で**縮む**ことはない |
| `ipv4_enabled = false` | パブリック IP を付けない | `true` だとインターネットから到達できる IP が付く。承認済みネットワークを設定しない限り接続はできないが、攻撃を受ける面が増える |
| `private_network` | この VPC からプライベート IP で接続する | `ipv4_enabled = false` で `private_network` も無いと、接続手段が無いため作成に失敗する |
| `backup_configuration.enabled = true` | 毎日の自動バックアップ | バックアップが無く、誤った `DELETE` やマイグレーションの失敗から戻せない |
| `point_in_time_recovery_enabled = true` | WAL(更新ログ)を保存し、任意の時刻の状態に復元できるようにする | 復元できるのは「毎日のバックアップ時点」だけになり、最大 1 日分のデータを失う |
| `start_time = "18:00"` | バックアップの開始時刻(UTC。日本時間 3:00) | 指定しないと GCP が時間帯を選ぶ。業務時間に重なると、負荷の小さいマシンでは体感できる遅さになることがある |
| `maintenance_window`(`day = 7`、`hour = 19`) | メンテナンス(再起動を伴う)を日本時間の月曜 4:00 に寄せる | 指定しないと任意のタイミングで再起動が入り、業務中に数分つながらなくなることがある |
| `query_insights_enabled = true` | 遅いクエリを GCP のコンソールで調べられる | 性能問題が起きたとき、原因のクエリを探す手段が減る |
| `deletion_protection = var.deletion_protection` | [3 章](#3-variablestf--変数)を参照 | — |
| `depends_on = [google_service_networking_connection.this]` | ピアリングができてからインスタンスを作らせる | インスタンスは `private_network` として VPC しか参照していないため、Terraform からは接続との前後関係が見えない。無いと並行して作られ、「プライベートサービス接続が無い」で失敗する |

DB への接続は暗号化(TLS)していない。経路がプライベート IP の VPC 内に限られるための判断(設計書 §4.1)。

---

## 7. secrets.tf — 共有の秘密

在庫 API のサービストークン。在庫側は「受け付けるトークンの一覧」(`INVENTORY_API_TOKENS`)、発送側は「送るトークン」(`INVENTORY_API_TOKEN`)として**同じ値**を使う。2 アプリにまたがるため、モジュールの外(ルート)に置いている。

| 設定 | なぜ必要か | 設定しないとどうなるか |
| :-- | :-- | :-- |
| `random_password`(`length = 64`) | 人が値を決めず、Terraform に十分長い乱数を作らせる。値は tfvars にもコードにも現れない | 人が決めた値は短くなりがち・使い回されがちで、tfvars 経由でコミットされる事故も起きる |
| `special = false` | 英数字だけにする。HTTP ヘッダー(`Authorization: Bearer ...`)や URL に入れても、エスケープの問題が起きない | 記号が混ざると、環境変数やヘッダーへの受け渡しで解釈が変わる文字が入りうる |
| `replication { auto {} }` | 秘密の保存場所を Google に任せる | レプリケーションの指定は必須。リージョンを限定したい規制があるなら `user_managed` にする |
| `google_secret_manager_secret_version` | 秘密の「入れ物」と「値(バージョン)」は別リソース | 入れ物だけ作って値を入れないと、Cloud Run が `latest` を参照したときに「バージョンが無い」でリビジョンの作成に失敗する |

---

## 8. registry.tf — Artifact Registry

| 設定 | なぜ必要か | 設定しないとどうなるか |
| :-- | :-- | :-- |
| `format = "DOCKER"`、`location = var.region` | コンテナイメージの置き場を Cloud Run と同じリージョンに作る | 別リージョンだと、Cloud Run が起動のたびにリージョンをまたいでイメージを取得し、起動が遅くなる |
| `local.registry` | `<region>-docker.pkg.dev/<project>/food-system` を 1 か所で組み立てる | `apps.tf` と `outputs.tf` で同じ文字列を別々に書くことになり、片方だけ直す事故が起きる。GitHub Actions(`deploy-dev.yml` の `REGISTRY`)も同じ形で組み立てているので、リポジトリ名を変えるときは両方直す |

リポジトリを Terraform で先に作るのは、**Cloud Run は存在しないイメージを指定すると作成に失敗する**ため。初回構築では `-target` でここまでを先に作り、イメージを push してから残りを `apply` する(README の手順 3〜5)。

---

## 9. apps.tf — 2 アプリの呼び出し

2 アプリは同じ形(DB・秘密・サービスアカウント・Cloud Run サービス・Job)なので `modules/app` にまとめ、違いだけを引数で渡している。モジュールにしないと、同じ約 300 行を 2 回書くことになり、片方だけ直し忘れる。

| 引数 | food_vault(在庫) | food_ship(発送) | 違いの理由 |
| :-- | :-- | :-- | :-- |
| `egress` | `PRIVATE_RANGES_ONLY` | `ALL_TRAFFIC` | 下記 |
| `env` | なし | `INVENTORY_API_BASE_URL` = 在庫サービスの `*.run.app` | 発送だけが在庫 API を呼ぶ |
| `secret_env` | `INVENTORY_API_TOKENS` | `INVENTORY_API_TOKEN` | 同じ秘密を、受ける側と送る側で別の環境変数名にして渡す |

### egress の違い

- `PRIVATE_RANGES_ONLY`: プライベート IP 宛て(= Cloud SQL)だけ VPC を通し、それ以外は Cloud Run から直接インターネットへ出る
- `ALL_TRAFFIC`: すべての通信を VPC に流す

在庫サービスの `ingress` は「内部と LB のみ」なので、発送からの呼び出しは**内部トラフィックとして届く必要がある**。`*.run.app` はパブリック IP のため、`PRIVATE_RANGES_ONLY` のままだと VPC を通らずインターネット経由になり、在庫の ingress に拒否される(404)。そこで発送は `ALL_TRAFFIC` にして VPC を通し、サブネットの Private Google Access 経由で在庫に届ける。

**代償として、発送はインターネットへ出られない**(VPC に Cloud NAT が無いため)。外部の API(配送業者など)を呼ぶ機能を足すときは Cloud NAT が必要になる。

### `depends_on = [google_secret_manager_secret_version.inventory_api_token]`

モジュールが受け取るのは秘密の ID(文字列)だけで、「値(バージョン)が入っていること」への依存は Terraform から見えない。これが無いと、値が入る前に Cloud Run の作成が走り、`latest` が見つからず失敗することがある。

### `INVENTORY_API_BASE_URL = module.food_vault.service_uri`

在庫サービスの URL を出力から受け取っているので、Terraform は「在庫 → 発送」の順で作る。URL を tfvars に手で書く方式だと、初回は在庫を作ってから URL を調べて書き写す 2 段階の作業になる。

---

## 10. modules/app — 1 アプリ分のリソース

### 10.1 DB と DB ユーザー

| 設定 | なぜ必要か | 設定しないとどうなるか |
| :-- | :-- | :-- |
| `google_sql_database`(名前 = `food_vault` / `food_ship`) | アプリごとの DB | インスタンスを作っただけでは既定の `postgres` DB しか無い |
| `google_sql_user` + `random_password.db` | アプリごとの DB ユーザーとパスワード | 既定の `postgres` ユーザーを 2 アプリで共用することになる。片方のアプリの秘密が漏れると両方の DB を操作でき、どちらのアプリの接続かも区別できない |
| `special = false` | パスワードを `DATABASE_URL`(`ecto://user:pass@host/db`)に埋め込むため | `@` `/` `:` `#` などが入ると URL の区切りと解釈され、接続先を誤る・接続に失敗する。しかも乱数次第なので「作り直したら急に壊れた」という形で起きる |

### 10.2 秘密(Secret Manager)

アプリごとに 3 つの秘密を作る。

| 秘密 | 中身 | 使う場所 |
| :-- | :-- | :-- |
| `<name>-database-url` | `ecto://<user>:<pass>@<Cloud SQL のプライベート IP>/<db>` | サービス・Job |
| `<name>-secret-key-base` | 64 文字の乱数。Phoenix がセッション Cookie や LiveView のトークンの署名に使う | サービス・Job |
| `<name>-initial-admin-password` | 初期管理者のパスワード(24 文字) | Job のみ |

- `DATABASE_URL` を丸ごと秘密にしているのは、パスワードを含むため。Terraform が IP・ユーザー・DB 名から組み立てるので、手で書き写す箇所が無い
- `SECRET_KEY_BASE` は**アプリごとに別の値**。同じ値にすると、片方のアプリで発行された署名付きトークンがもう片方でも正しい署名として通ってしまう
- `SECRET_KEY_BASE` を作り直すと、全利用者がログアウトされる(既存の Cookie の署名が検証できなくなる)
- `secret_ids` と `secrets` を別の `locals` に分け、`for_each` には `secret_ids`(秘密でない名前)を使っている。`for_each` のキーや対象に sensitive な値を使うとエラーになるため

### 10.3 サービスアカウントと権限

| 設定 | なぜ必要か | 設定しないとどうなるか |
| :-- | :-- | :-- |
| `google_service_account`(アプリごと) | Cloud Run がどの権限で動くかを決める | 指定しないと Compute Engine の既定サービスアカウントで動く。これは多くのプロジェクトで「編集者」相当の広い権限を持つため、アプリに脆弱性があったときの被害がプロジェクト全体に及ぶ |
| `secret_iam_member.own`(自アプリの 3 つの秘密) | 秘密を読む権限を、**秘密ごと**に与える | 権限が無いと Cloud Run が秘密を読めず、リビジョンの作成に失敗する。逆にプロジェクト全体に `secretAccessor` を付けると、相手アプリの `DATABASE_URL` まで読めてしまう |
| `secret_iam_member.shared`(`var.secret_env` の分) | 共有の秘密(在庫 API トークン)を読む権限 | 同上 |
| `roles/cloudsql.client` | Cloud SQL へ接続する権限 | プライベート IP で直接つなぐ今の構成では必須ではない(設計書 §4.3)。将来 Cloud SQL Auth Proxy や IAM 認証に切り替えたときに必要になる |

サービスと Job は同じサービスアカウントを共用している。どちらも同じ DB・同じ秘密を使うため。

### 10.4 Cloud Run サービス

| 設定 | なぜ必要か | 設定しないとどうなるか |
| :-- | :-- | :-- |
| `ingress = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"` | 受け付ける通信を「VPC 内から」と「外部 LB 経由」に限る | 既定は「すべて」。`https://food-vault-xxxx.run.app` にインターネットから直接届くようになり、**Cloud Armor(WAF・レート制限・`/api` の遮断・送信元制限)をすべて素通りされる** |
| `invoker_iam_disabled = true` | Cloud Run の IAM による呼び出し元チェックを使わない。LB は Cloud Run に対して認証をしないため | 無効化しない場合、`allUsers` に `roles/run.invoker` を付けないと LB 経由のアクセスがすべて 403 になる。`allUsers` への付与は組織ポリシー(ドメイン制限付き共有)で拒否されることがあるため、こちらの方式にしている |
| `deletion_protection = false` | `terraform destroy` や再作成を Terraform からできるようにする | プロバイダの既定は `true` で、消すには先に `false` へ変えて `apply` する必要がある。サービス自体はデータを持たないので保護していない(データを持つ Cloud SQL は保護している) |
| `timeout = "3600s"` | 1 リクエストの最大時間。Cloud Run では **WebSocket も 1 リクエストとして数える** | 既定は 300 秒。LiveView の WebSocket が 5 分ごとに切断され、そのたびに再接続と画面の再マウントが起きる(入力途中のフォームの状態などが失われうる)。3600 秒は上限で、それでも 60 分ごとに再接続は起きる |
| `execution_environment = "EXECUTION_ENVIRONMENT_GEN2"` | アプリは IPv6 の全アドレスで待ち受ける(`runtime.exs`)ため、Linux と完全互換の第 2 世代を使う | 第 1 世代はシステムコールを模擬する環境で、互換性に制限がある |
| `scaling`(`min` / `max`) | [3 章](#3-variablestf--変数)を参照 | `max` を指定しないと、アクセス集中時に多数のインスタンスが起動し、DB の接続数上限を超える |
| `vpc_access`(`network_interfaces`) | Direct VPC egress。Cloud SQL のプライベート IP に届くために必要 | VPC につながっていないと Cloud SQL へ届かず、アプリが起動時に DB 接続エラーになる。サーバーレス VPC アクセスコネクタでも実現できるが、常時起動のインスタンス料金がかかる |
| `container_port = 4000` | Phoenix が待ち受けるポート | 既定は 8080。Cloud Run は 8080 に疎通確認をするため、起動失敗と判定される |
| `limits`(1 vCPU / 1 GiB) | メモリの上限 | 既定は 512 MiB。超えるとインスタンスが強制終了される |
| `PHX_SERVER = "true"` | リリースで Web サーバーを起動させる(`runtime.exs` がこれを見てエンドポイントを起動する) | BEAM は起動するが HTTP を待ち受けず、起動失敗と判定される。**サービスにだけ**付けている(Job はサーバーを起動しない) |
| `PHX_HOST` | 公開ホスト名。URL の生成と、WebSocket の接続元チェック(`check_origin`)に使われる | LB のホスト名と一致しないと、LiveView の WebSocket が接続元の不一致で拒否され、画面が表示されても操作に反応しなくなる |
| `POOL_SIZE = 5` | インスタンスあたりの DB 接続数 | 大きくすると `db-f1-micro` の接続数上限に当たる([17 章](#17-運用上の注意点)) |
| `secret_key_ref`(`version = "latest"`) | 秘密を環境変数として渡す。値は Terraform の設定にも Cloud Run の設定画面にも現れない | 平文の `env` で渡すと、Cloud Run のリビジョン設定を見られる人全員が値を読める |
| `startup_probe`(TCP 4000、5 秒間隔 × 24 回) | ポート 4000 が開いたら起動完了とみなす。最大 120 秒待つ | プローブが通るまでトラフィックは流れない。猶予が短すぎると、起動に時間がかかったときに「起動失敗」と判定されて再起動を繰り返す |

#### `lifecycle.ignore_changes`

```hcl
ignore_changes = [
  template[0].containers[0].image,
  client,
  client_version,
]
```

イメージは GitHub Actions が `gcloud run services update --image` で更新する。Terraform の設定(`var.image`)は初回作成時の値のまま。

- **`image` を無視しないと**: `terraform apply` のたびに、Terraform は「設定と違う」と判断して tfvars のタグ(初回のイメージ)へ**巻き戻す**。ネットワークの設定を変えただけのつもりが、アプリが古いバージョンに戻る
- **`client` / `client_version` を無視しないと**: `gcloud` はデプロイのたびに「gcloud のどのバージョンで更新したか」を書き込む。これが毎回 `plan` の差分として出て、本当の差分が埋もれる

#### `depends_on`(IAM と秘密のバージョン)

サービスは秘密を ID の文字列で参照しているため、「読む権限が付いたこと」「値が入ったこと」への依存が Terraform から見えない。無いと権限付与より先にサービス作成が走り、秘密を読めずに失敗することがある。

### 10.5 Cloud Run Job(マイグレーション)

`/app/bin/<app> eval "<App>.Release.migrate_and_seed()"` を実行する。Terraform は Job を**作るだけ**で実行しない(実行は `gcloud run jobs execute` または GitHub Actions)。

なぜサービスの起動時にマイグレーションしないか: サービスは複数インスタンスが同時に起動しうるため、起動時に実行すると多重実行になる。また失敗したときに「サービスが起動しない」という形でしか分からない。Job なら 1 回だけ実行され、失敗したらデプロイを止められる。

| 設定 | なぜ必要か | 設定しないとどうなるか |
| :-- | :-- | :-- |
| `task_count = 1` | 1 回の実行で 1 タスクだけ動かす | 複数にすると同じマイグレーションが並行して走る |
| `max_retries = 0` | 失敗しても自動で再実行しない | 既定は 3 回。途中まで進んで失敗したマイグレーションが、原因を調べる前に繰り返し実行される |
| `timeout = "600s"` | 10 分で打ち切る | 大きなテーブルへのインデックス追加などで 10 分を超えるなら延ばす必要がある |
| `egress = "PRIVATE_RANGES_ONLY"`(発送の Job も) | Job が使うのは DB だけで、在庫 API は呼ばない | — |
| `command` / `args` | イメージ既定の起動コマンド(サーバー起動)を上書きする | サーバーが起動して終了しないため、Job がタイムアウトまで走り続ける |
| `INITIAL_ADMIN_EMAIL` / `INITIAL_ADMIN_PASSWORD` | シードで初期管理者を作るため | 在庫側は管理者が作られず、シードが途中で失敗する(設計書 §5.2) |
| `secret_env`(在庫の `INVENTORY_API_TOKENS`) | Job でも `runtime.exs` は読み込まれ、在庫は未設定だと起動時に落ちる | Job が起動直後にエラー終了する |
| `ignore_changes`(`image` など) | サービスと同じ | サービスと同じ |

---

## 11. lb.tf — ロードバランサ

外部アプリケーション LB は、複数のリソースをつなげて 1 つの LB になる。

```
転送ルール(IP:443) → HTTPS プロキシ(証明書) → URL マップ(ホスト名で振り分け)
   → バックエンドサービス(Cloud Armor・ログ) → サーバーレス NEG → Cloud Run
```

なぜ Cloud Run の URL を直接使わず LB を置くか: 独自ドメインと証明書、Cloud Armor、2 アプリを 1 つの IP にまとめる、の 3 つのため。Cloud Armor は LB のバックエンドサービスにしか付けられない。

| 設定 | なぜ必要か | 設定しないとどうなるか |
| :-- | :-- | :-- |
| `google_compute_global_address` | 固定の IP を予約する | 予約しないと転送ルールに一時的な IP が割り当てられ、転送ルールを作り直すと IP が変わる。DNS の A レコードが古い IP を指したままになり、つながらなくなる |
| `google_compute_managed_ssl_certificate` | 証明書の発行と更新を Google に任せる | 自分で証明書を取得・更新する運用になり、更新を忘れると期限切れで全利用者にブラウザの警告が出る |
| `domains = [vault, ship]` | 2 つのホスト名を 1 枚の証明書に入れる | 入っていないホスト名でアクセスすると証明書エラーになる |
| `google_compute_region_network_endpoint_group`(`SERVERLESS`) | LB から Cloud Run へ流すための接続口 | LB のバックエンドには NEG かインスタンスグループしか指定できず、Cloud Run を直接は指定できない |
| `load_balancing_scheme = "EXTERNAL_MANAGED"`(バックエンドサービスと転送ルールの両方) | 現行のグローバル外部アプリケーション LB を使う | `EXTERNAL` は旧式(従来型)。両方で値が揃っていないと作成時にエラーになる |
| `security_policy` | このバックエンドに Cloud Armor を適用する | ポリシーは作っただけでは効かない。**付け忘れたバックエンドは無防備になる**(`for_each` で両方に同じ設定を付けているのは、その漏れを防ぐため) |
| `log_config`(`sample_rate = 1.0`) | 全リクエストをログに残す。Cloud Armor がどのルールで拒否したかもここに出る | ログが無いと、403 / 429 の原因(WAF の誤検知か、レート制限か)を調べられない。アクセスが増えてログの費用が気になったら率を下げる |
| `default_url_redirect` | どのホスト名にも一致しないアクセス(IP の直打ちなど)を在庫のホストへ 301 で転送する | URL マップは既定の転送先が必須。ここを在庫のバックエンドにすると、任意のホスト名で在庫に届いてしまう |
| `strip_query = true` | 転送時にクエリ文字列を捨てる | 想定外のホスト名で来たリクエストの内容を、そのまま引き継がない |
| `host_rule` / `path_matcher` | `vault.<domain>` → 在庫、`ship.<domain>` → 発送 に振り分ける | — |
| `google_compute_target_https_proxy` | TLS を終端し、証明書と URL マップを結びつける | — |
| `google_compute_global_forwarding_rule`(`port_range = "443"`) | IP の 443 番で待ち受ける | これが無いと LB は外から見えない |

- バックエンドサービスにヘルスチェックが無いのは、サーバーレス NEG では使えないため(Cloud Run 側が管理する)
- **HTTP(80)は待ち受けていない**(コスト削減。`.steering/20261108-reduce-gcp-cost`)。`http://` でアクセスすると、リダイレクトされるのではなく接続できない。利用者には `https://` の URL を案内する
- 証明書は、DNS の A レコードが LB の IP を指してから発行される。それまでは `PROVISIONING` のままで、HTTPS はつながらない(README の手順 7)

---

## 12. armor.tf — Cloud Armor

1 つのポリシーを両方のバックエンドに付けている。**ルールは優先度の数字が小さい順に評価され、最初に一致したルールの動作で決まる**(以降のルールは見ない)。この性質が全体の設計を決めている。

| 優先度 | 条件 | 動作 |
| :-- | :-- | :-- |
| 100 | パスが `/api` で始まる | 403 |
| 1000〜1006 | WAF の事前構成ルールに一致 | 403 |
| 2000 | 許可された送信元(未指定なら全員) | 上限内は許可、超過は 429 |
| 2147483647 | 上のどれにも一致しない | 送信元を絞るときは 403、絞らないときは許可 |

### 12.1 優先度 100: `/api` の遮断

在庫 API は発送システム専用で、発送は VPC 経由で在庫の `*.run.app` を直接呼ぶ(LB を通らない)。したがって **LB 経由で `/api` に来るリクエストは、すべて想定外**として落とせる。

- 無いとどうなるか: 在庫 API がインターネットに公開され、守りが Bearer トークン 1 つだけになる。トークンが漏れた時点で、外部から在庫の引当などを実行できる
- 発送のバックエンドにも同じルールが効くが、発送には `/api` のパスが無いので影響はない
- 最優先(100)に置いているのは、送信元の許可(2000)より先に評価させるため。許可された送信元からでも `/api` は通さない

正規表現が複雑な理由:

```hcl
api_path_regex = join("|", [
  for c in setproduct(["a", "%61"], ["p", "%70"], ["i", "%69"], ["/", "$"]) : "^/+${join("", c)}"
])
```

Cloud Armor と Phoenix(Plug)で**パスの解釈が違う**ため、単純な `startsWith('/api')` ではすり抜けられる。

| すり抜けの例 | 理由 | 対策 |
| :-- | :-- | :-- |
| `//api/v1/...` | Plug は空のパス要素を無視するので、`/api/v1/...` として処理する | `^/+`(スラッシュ 1 個以上) |
| `/%61pi/v1/...` | Plug はパス要素を URL デコードする(`%61` = `a`) | 各文字の平文とパーセントエンコードの全組み合わせ(2×2×2 = 8 通り) |
| `/API/v1/...` | 大文字と小文字 | `request.path.lower()` |
| `/apiary` を誤って遮断 | 前方一致だと別のパスまで巻き込む | 終端を `/` か末尾(`$`)に限る(× 2 = 計 16 通り) |

Cloud Armor の式には URL デコードの関数が無く、正規表現でグループ化も使えないため、16 通りを `|` で並べた文字列を Terraform で生成している。

### 12.2 優先度 1000〜1006: WAF

Google が用意している OWASP のルールセット(SQL インジェクション・XSS・ローカル/リモートファイルインクルード・リモートコード実行・スキャナ検出・プロトコル攻撃)。

| 設定 | なぜ必要か | 設定しないとどうなるか |
| :-- | :-- | :-- |
| `evaluatePreconfiguredWaf(...)` | 典型的な攻撃パターンをアプリに届く前に落とす | アプリ側の対策(Ecto のパラメータ化クエリ、HEEx のエスケープ)だけが頼りになる。多層防御の 1 層が無くなる |
| `'sensitivity': 1` | 最も誤検知の少ないレベル。確度の高いパターンだけに反応する | 感度を上げると検出は増えるが、通常の入力(備考欄の記号や、SQL に似た文字列)まで 403 になりやすい |
| `for_each = local.waf_rules`(優先度をキーにした map) | ルールの追加・削除を 1 行で済ませる | — |

誤検知が出たら、該当ルールに `opt_out_rule_ids` を足して個別に外す(README)。

### 12.3 優先度 2000: レート制限 兼 送信元の許可

| 設定 | なぜ必要か | 設定しないとどうなるか |
| :-- | :-- | :-- |
| `action = "throttle"` | 上限内は通し、超過分だけ拒否する | `rate_based_ban` にすると、超過した IP を一定時間まるごと遮断する(より厳しい) |
| `enforce_on_key = "IP"` | 送信元 IP ごとに数える | 全体で 1 つのカウンタになり、1 人の大量アクセスで全員が 429 になる |
| `count` / `interval_sec = 60` | 1 分あたりの上限 | レート制限が無いと、ログイン画面への総当たりや大量リクエストがそのまま Cloud Run に届く。インスタンスが増えて課金が増え、DB 接続も埋まる |
| `exceed_action = "deny(429)"` | 超過時は 429(Too Many Requests) | — |
| `src_ip_ranges = 許可 CIDR または "*"` | 下記 | — |

**送信元の制限をこのルールで兼ねている理由**: `throttle` は上限内なら「許可」で評価を終える。もし「許可 CIDR 以外を拒否」を別ルールにして throttle の後ろに置くと、throttle が先に全員を許可してしまい、拒否ルールに到達しない。そこで throttle の対象そのものを許可 CIDR に絞り、対象外は既定ルールへ落とす形にしている。

### 12.4 既定ルール(優先度 2147483647)

- ポリシーには既定ルールが必須
- 送信元を絞っているときは `deny(403)`: 許可 CIDR 以外は 2000 に一致せず、ここで拒否される
- 絞っていないときは `allow`: ただし 2000 が `*` で全員に一致するので、実際にはここまで来ない

---

## 13. ci.tf — GitHub Actions からのデプロイ

### 13.1 Workload Identity Federation(WIF)

GitHub Actions は実行のたびに「どのリポジトリの、どのブランチの、どのワークフローか」を記した署名付きトークン(OIDC トークン)を発行できる。GCP がそれを検証し、条件に合えば短命の GCP トークンに交換する仕組みが WIF。

**なぜサービスアカウントキー(JSON)を使わないか**: キーは期限が無く、GitHub の Secrets に置くことになる。漏れると、失効させるまで誰でもどこからでもデプロイ権限を使える。WIF なら保存する秘密が無く、トークンは 1 回の実行の間だけ有効。

| 設定 | なぜ必要か | 設定しないとどうなるか |
| :-- | :-- | :-- |
| `google_iam_workload_identity_pool` | 外部の ID を受け入れる枠 | — |
| `issuer_uri = "https://token.actions.githubusercontent.com"` | GitHub Actions が発行したトークンだけを受け付ける | — |
| `attribute_mapping` | GitHub のトークンの項目を GCP 側の属性に写す。`google.subject` は必須。`attribute.repository` は下の `principalSet` で使う | 写していない項目は IAM の条件に使えない |
| `attribute_condition`(リポジトリとブランチの一致) | 条件に合わないトークンを、**交換の時点で**拒否する | この発行元は GitHub の全リポジトリで共通。条件が無いと、他人のリポジトリのワークフローもプールまでは入れてしまう(GitHub のような発行元では、条件なしのプロバイダは作成自体が拒否される)。ブランチの条件が無いと、**このリポジトリのどのブランチからでもデプロイできる**。つまりレビュー前の作業ブランチにワークフローを書いて push するだけで、本番を書き換えられる |
| `deployer_wif`(`roles/iam.workloadIdentityUser`、`principalSet://.../attribute.repository/<repo>`) | プールを通った ID のうち、このリポジトリのものにだけ、デプロイ用サービスアカウントとして振る舞うことを許す | これが無いとトークンの交換はできても、サービスアカウントになれず何もできない。プール全体(`/*`)に許すと、将来プロバイダや条件を足したときに意図しない相手まで通る |

リポジトリの制限は 2 か所(`attribute_condition` と `principalSet`)、ブランチの制限は `attribute_condition` の 1 か所で行っている。

### 13.2 デプロイ用サービスアカウントの権限

必要な操作だけを、できるだけ狭い範囲に与えている。

| 権限 | 範囲 | 何のためか | 無いとどうなるか |
| :-- | :-- | :-- | :-- |
| `roles/artifactregistry.writer` | リポジトリ `food-system` のみ | イメージの push | `docker push` が権限エラーになる |
| `roles/run.developer` | プロジェクト | Job・サービスのイメージ更新と Job の実行 | `gcloud run ... update` / `execute` が権限エラーになる |
| `roles/iam.serviceAccountUser` | 両アプリの実行用サービスアカウントの 2 つのみ | Cloud Run を更新するとき、そのサービスが使うサービスアカウントを「使わせる」権限(actAs)が要る | イメージの更新が `iam.serviceAccounts.actAs` の権限エラーになる |

- `serviceAccountUser` をプロジェクト全体に付けると、デプロイ用サービスアカウントが**プロジェクト内のどのサービスアカウントにもなりすませる**。より強い権限のサービスアカウントを指定してサービスを作れば、権限を広げられてしまう。対象を 2 つに絞っているのはそのため
- `roles/run.admin` ではなく `run.developer` にしているのは、IAM ポリシーの変更(公開範囲の変更など)をさせないため
- デプロイ用サービスアカウントは**秘密を読む権限も、DB へ接続する権限も持たない**。CI が乗っ取られても、秘密の値や DB の中身は直接は取れない

---

## 14. outputs.tf — 出力

`apply` 後の作業に必要な値を出す。無くても動くが、コンソールで探す手間と写し間違いが増える。

| 出力 | 使い道 |
| :-- | :-- |
| `lb_ip_address` | DNS の A レコードに登録する |
| `urls` | 公開 URL |
| `image_repository` | イメージの push 先 |
| `migrate_jobs` | `gcloud run jobs execute` に渡す Job 名 |
| `workload_identity_provider` / `deployer_service_account` | GitHub の Environment `dev` の Variables に登録する |
| `initial_admin_password_secrets` | 初期管理者パスワードが入っている秘密の名前 |
| `food_vault_internal_uri` | 在庫サービスの内部 URL(確認用) |

パスワードそのものは出力せず、**秘密の名前**だけを出している。値を出力にすると、`terraform output` の表示や CI のログに残るため。

---

## 15. tests/plan.tftest.hcl — テスト

`mock_provider` でプロバイダを偽物に差し替え、GCP の認証情報なしで `plan` の結果を検証する。

| テスト | 確認していること | 守っているもの |
| :-- | :-- | :-- |
| `default` | 証明書のドメイン、既定ルールが `allow`、`/api` 遮断ルールがある | `/api` 遮断の消し忘れ・消し間違い |
| `deploy_identity` | WIF の条件がリポジトリと `dev` に限定、デプロイ用の権限が想定どおり、actAs が 2 つだけ | 権限の広げすぎ |
| `deploy_branch_override` | 変数を変えると条件に反映される | 条件の値の決め打ち |
| `invalid_github_repository` / `too_many_source_ranges` | 不正な値が `validation` で弾かれる | 検証の削除 |
| `restricted_source` | 送信元を指定すると既定ルールが `deny` になる | 送信元制限が効かなくなる変更 |

テストが守っているのは**セキュリティ上の前提**。これらは壊れてもアプリは普通に動くため、動作確認では気づけない。

---

## 16. 設定同士の依存関係(片方だけ変えると壊れる組)

| 組み合わせ | 片方だけ変えると |
| :-- | :-- |
| 在庫の `ingress`(内部と LB のみ)+ 発送の `egress = "ALL_TRAFFIC"` + サブネットの `private_ip_google_access` | どれか 1 つを外すと、発送から在庫 API を呼べなくなる |
| `ingress`(内部と LB のみ)+ `invoker_iam_disabled = true` | `ingress` だけ「すべて」に戻すと、認証なしの `*.run.app` がインターネットに公開される |
| Cloud Armor の `/api` 遮断 + 発送が LB を通らずに在庫を呼ぶこと | 発送の `INVENTORY_API_BASE_URL` を公開 URL(`https://vault.<domain>`)に変えると、発送自身が 403 になる |
| `ipv4_enabled = false` + `private_network` + `vpc_access` + プライベートサービス接続 | どれが欠けても DB に届かない |
| `ignore_changes`(image)+ GitHub Actions によるイメージ更新 | `ignore_changes` を外すと、`apply` のたびに初回のイメージへ巻き戻る |
| `random_password.db` の `special = false` + `DATABASE_URL` への埋め込み | 記号を許すと、乱数次第で接続 URL が壊れる |
| `max_instances` × `POOL_SIZE` × 2 アプリ + `db_tier` の接続数上限 | どれかを増やすと、接続数の上限に当たる(17 章) |
| `PHX_HOST` + LB の `host_rule` + 証明書の `domains` | サブドメインの変数からすべて導いているので揃っている。どれかを直接書き換えると、証明書エラーか WebSocket の拒否になる |
| `local.registry` + `deploy-dev.yml` の `REGISTRY` | リポジトリ名を片方だけ変えると、push 先と Cloud Run の参照先がずれる |

---

## 17. 運用上の注意点

コードから読み取れる、知っておくべき制約。

- **DB の接続数に余裕が少ない**: 接続数は最大で「2 アプリ × `max_instances` 2 × `POOL_SIZE` 5 = 20」に、マイグレーション Job の分が加わる。Cloud SQL の `db-f1-micro` は既定の `max_connections` が 25 前後(うち数本は管理用に予約)とされるため、ほぼ上限。デプロイ中は新旧のリビジョンが同時に動いて一時的に増えることもある。`max_instances` や `POOL_SIZE` を増やすときは、`db_tier` を上げるか `max_connections` フラグの設定を合わせて検討する。実際の上限は `SHOW max_connections;` で確認できる
- **証明書のドメインを変えると `apply` が失敗しうる**: マネージド証明書はドメインの変更で再作成になるが、名前が `food-system` で固定されており、HTTPS プロキシが使用中の証明書は削除できない。`domain` やサブドメインを変えるときは、証明書の名前を変えて `create_before_destroy` を付けるなどの対応が要る
- **秘密を作り直しても、動いているインスタンスには反映されない**: 環境変数として渡した秘密は、インスタンスの起動時に読み込まれる。`-replace` で値を変えたあとは、新しいリビジョンをデプロイする(README)
- **在庫 API トークンを作り直すと、切り替えの間は発送 → 在庫が 401 になりうる**: 両アプリが同じ値を使うため、片方だけ新しいリビジョンになった時間帯は不一致になる
- **`db_tier` の変更は再起動を伴う**: 数分の停止が入る
- **Workload Identity プールは削除後 30 日間、同じ ID で作り直せない**: `destroy` → `apply` をやり直すときは ID を変える(README)
- **発送はインターネットへ出られない**: 外部 API を呼ぶ機能を足すときは Cloud NAT を追加する
- **Cloud SQL は 1 ゾーン構成**: ゾーン障害時は両システムが止まる。可用性が要るなら `availability_type = "REGIONAL"`(料金は増える)
- **`min_instances = 0` のコールドスタート**: 朝一番などのアクセスは、起動を待つ分だけ遅い
- **Terraform の実行に使う権限は強い**: README の前提は作業者の Owner 相当。`terraform apply` は GitHub Actions では実行しておらず、作業者が手元で行う運用になっている
