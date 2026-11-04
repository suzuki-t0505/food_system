# クラウド環境用 Docker セットアップ

Claude Code のクラウド環境でだけ使う。ローカル開発では不要で、`Dockerfile.dev` と `docker-compose.yml` は変更しない。

## 背景

クラウド環境のコンテナは直接インターネットに出られず、ホスト側のプロキシ (`127.0.0.1`) 経由のみ。
そのためビルドと実行を `--network host` で行い、プロキシ用 CA と https の apt ソースを入れたベースイメージを使う。

## 使い方

環境設定のセットアップスクリプトに次を追加する。

```bash
cd food_system && bash scripts/cloud/setup.sh
```

実行後、新しいシェルでは `COMPOSE_FILE` に override が入り、通常どおり使える。

```bash
make setup
make mix_test
```

## 前提

- ネットワークアクセスで `deb.debian.org`、`repo.hex.pm`、`builds.hex.pm`、`registry.npmjs.org` と Docker Hub が許可されていること。
- `HTTPS_PROXY` が設定されていること (クラウド環境で自動設定)。

## ファイル

- `setup.sh`: dockerd 起動、ベースイメージとアプリイメージのビルド、DB 起動、`COMPOSE_FILE` の設定
- `docker-compose.cloud.yml`: web サービスを host ネットワークで動かす override (`db` は `127.0.0.1` に解決)
