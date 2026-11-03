---
name: create-mock
description: 機能仕様（PDF・ドキュメント）をもとに、既存システムのデザインを踏襲したHTMLモックを ./mock/{YYYYMMDD}/ に生成する。クライアント向けUIイメージ提示用。/create-mock で呼び出す。
allowed-tools: Read, Write, Edit, Bash, Agent, AskUserQuestion
---

# HTMLモック作成スキル

機能仕様書（PDF・Markdownなど）をもとに、既存システム（Phoenix/LiveView + Tailwind CSS + DaisyUI）のデザインを再現したスタティックHTMLモックを `./mock/{YYYYMMDD}/` に生成する。

---

## フェーズ1: 仕様の読み込みと確認

### 1-1. 仕様ファイルを確認する

引数にファイルパスが指定されていればそれを読む。指定がなければユーザーに確認する。

### 1-2. 出力先ディレクトリを決定する

実行日の日付を取得し、出力先ディレクトリを決定する:

```bash
date +%Y%m%d
```

出力先: `./mock/{YYYYMMDD}/`（例: `./mock/20260606/`）

### 1-3. 既存モックを確認する

```bash
ls ./mock/ 2>/dev/null || echo "mock dir not found"
```

`./mock/` 配下に既存の日付フォルダがあれば確認し、既存の画面構成を把握する。

### 1-3. 仕様を読んでから以下の4点をユーザーに確認する（まとめて1回）

```
AskUserQuestion([
  {
    question: "ファイル構成はどうしますか？",
    header: "ファイル構成",
    options: [
      { label: "機能ごとに別HTMLファイル（推奨）", description: "画面単位で1ファイル。管理しやすく差し替えも簡単。" },
      { label: "1ファイルにまとめる", description: "タブやセクションで切り替え。ファイルは1つで済む。" }
    ]
  },
  {
    question: "既存画面に追加がある場合の扱いは？",
    header: "既存画面の扱い",
    options: [
      { label: "画面全体を再現（推奨）", description: "既存部分も含めて完全な画面として出力。クライアントに全体像を見せられる。" },
      { label: "追加部分のみ出力", description: "差分だけ出力。実装者向けには明確だが単体では意味が伝わりにくい。" }
    ]
  }
])
```

不明点があれば追加で質問する（ただし、まとめて一度だけ）。

---

## フェーズ2: 実装計画の提示

仕様と回答をもとに、作成するファイル一覧をユーザーに提示して承認を得る:

> 「以下のファイルを作成します。出力先: `mock/{YYYYMMDD}/`
>
> | ファイル | 内容 | 区分 |
> |---|---|---|
> | `index.html` | モック一覧ナビゲーション | 新規 |
> | `{screen}.html` | ... | 既存＋追加 / 新規 |
>
> 承認いただけたら実装を開始します。」

---

## フェーズ3: 実装

### 3-1. 出力先ディレクトリを作成する

```bash
mkdir -p ./mock/{YYYYMMDD}
```

`{YYYYMMDD}` はフェーズ1で取得した実行日（例: `20260606`）。

### 3-2. ファイルを1つずつ作成する

`index.html` から始め、各画面を `./mock/{YYYYMMDD}/` 配下に順番に作成する。

**実装ルール:**
- 1ファイル作成するたびに完了を報告する（承認待ちは不要、報告のみ）
- 独立したファイルは並列作成してよい
- JSはバニラJSのみ（フレームワーク不可）

---

## 設計仕様（必ず守ること）

### CDN読み込み（全ファイル共通）

```html
<link href="https://cdn.jsdelivr.net/npm/daisyui@4/dist/full.min.css" rel="stylesheet">
<script src="https://cdn.tailwindcss.com"></script>
<link href="https://fonts.googleapis.com/css2?family=Noto+Sans+JP:wght@400;500;600&display=swap" rel="stylesheet">
<style>body { font-family: 'Noto Sans JP', sans-serif; }</style>
```

DaisyUIをTailwindより先に読み込むこと（競合回避）。

### レイアウト構造（全ファイル共通）

```html
<body class="bg-white flex overflow-hidden" style="max-height:100vh">

  <!-- ハンバーガーメニュー制御（モバイル） -->
  <input id="navi-input" class="hidden peer" type="checkbox">
  <label for="navi-input" class="cursor-pointer hidden peer-checked:block bg-gray-600/90 h-full fixed right-0 top-0 w-full z-[60]"></label>

  <!-- サイドバー -->
  <aside class="bg-gray-600 hidden peer-checked:flex lg:flex flex-col fixed lg:static h-full min-w-60 max-h-screen overflow-y-auto z-[70] pt-16 lg:pt-6 justify-between">
    <ul class="grid grid-cols-1 gap-y-4 text-white px-4 w-full">
      <!-- ナビリンク -->
    </ul>
    <ul class="grid grid-cols-1 my-4 gap-y-4 text-white px-4 w-full border-t-2">
      <!-- 画面切り替えリンク（管理者↔担当者） -->
    </ul>
  </aside>

  <!-- メインコンテンツ -->
  <main class="flex-1 min-w-0">
    <label for="navi-input" class="bg-white flex items-center cursor-pointer fixed h-10 ml-4 left-0 rounded top-2 w-10 z-[60] lg:hidden">
      <!-- ハンバーガーアイコン（Heroicons: bars-3） -->
    </label>
    <div id="header" class="sticky top-0 z-40 h-[57px] flex justify-end px-4 py-2 border-b bg-white w-full lg:items-center lg:px-10">
      <!-- ユーザー名表示 -->
    </div>
    <div style="height: calc(100vh - 57px); overflow-y: auto;">
      <div class="px-6 py-10 lg:px-8">
        <div class="w-full md:max-w-2xl mx-auto">
          <!-- ページタイトル -->
          <div class="flex items-center justify-between gap-6 mb-4">
            <h1 class="text-lg font-semibold leading-8 text-zinc-800">{ページ名}</h1>
          </div>
          <div class="border-t border-zinc-100 mb-6"></div>
          <!-- ページ本体 -->
        </div>
      </div>
    </div>
  </main>
</body>
```

### カラーパレット

| 用途 | クラス |
|---|---|
| サイドバー背景 | `bg-gray-600` |
| サイドバーテキスト | `text-white` |
| アクティブナビ | `border-b-2 border-blue-400` |
| カード | `rounded-2xl bg-white shadow-sm ring-1 ring-zinc-200` |
| セクション見出し | `text-base font-semibold text-zinc-900` |
| ラベル | `text-sm text-zinc-500` |
| 値テキスト | `text-sm font-medium text-zinc-900` |
| 区切り線 | `border-t border-zinc-100` |

### DaisyUIコンポーネント

- ボタン（主）: `btn`
- ボタン（副）: `btn btn-outline btn-sm`
- ボタン（削除）: `btn btn-outline btn-error btn-sm`
- 入力: `input input-bordered input-sm`
- セレクト: `select select-bordered select-sm`
- バッジ: `badge badge-warning badge-sm` / `badge badge-info badge-sm`
- カード: `card card-body`

### NEW / 改定バッジ

既存画面への追加・変更箇所には必ずバッジを付与:

```html
<!-- 新機能 -->
<span class="badge badge-warning badge-sm">★ NEW</span>
<!-- 既存機能の変更 -->
<span class="badge badge-info badge-sm">改定</span>
```

### アイコン

Heroicons の inline SVG を使用（CDNなし）。よく使うアイコン:

```html
<!-- ダッシュボード -->
<svg fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="w-5 h-5"><path stroke-linecap="round" stroke-linejoin="round" d="M2.25 7.125C2.25 6.504 2.754 6 3.375 6h6c.621 0 1.125.504 1.125 1.125v3.75c0 .621-.504 1.125-1.125 1.125h-6a1.125 1.125 0 0 1-1.125-1.125v-3.75ZM14.25 8.625c0-.621.504-1.125 1.125-1.125h5.25c.621 0 1.125.504 1.125 1.125v8.25c0 .621-.504 1.125-1.125 1.125h-5.25a1.125 1.125 0 0 1-1.125-1.125v-8.25ZM3.75 16.125c0-.621.504-1.125 1.125-1.125h5.25c.621 0 1.125.504 1.125 1.125v2.25c0 .621-.504 1.125-1.125 1.125h-5.25a1.125 1.125 0 0 1-1.125-1.125v-2.25Z"/></svg>
<!-- ユーザー -->
<svg fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="w-5 h-5"><path stroke-linecap="round" stroke-linejoin="round" d="M15.75 6a3.75 3.75 0 1 1-7.5 0 3.75 3.75 0 0 1 7.5 0ZM4.501 20.118a7.5 7.5 0 0 1 14.998 0A17.933 17.933 0 0 1 12 21.75c-2.676 0-5.216-.584-7.499-1.632Z"/></svg>
<!-- カレンダー -->
<svg fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="w-5 h-5"><path stroke-linecap="round" stroke-linejoin="round" d="M6.75 3v2.25M17.25 3v2.25M3 18.75V7.5a2.25 2.25 0 0 1 2.25-2.25h13.5A2.25 2.25 0 0 1 21 7.5v11.25m-18 0A2.25 2.25 0 0 0 5.25 21h13.5A2.25 2.25 0 0 0 21 18.75m-18 0v-7.5A2.25 2.25 0 0 1 5.25 9h13.5A2.25 2.25 0 0 1 21 11.25v7.5"/></svg>
<!-- ハンバーガー（bars-3） -->
<svg fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="w-6 h-6"><path stroke-linecap="round" stroke-linejoin="round" d="M3.75 6.75h16.5M3.75 12h16.5m-16.5 5.25h16.5"/></svg>
```

### ダッシュボード形式のリスト表示

ダッシュボードや「今後の現場」など、単純なリスト表示には以下の形式を使う（検索・ページネーション不要）:

```html
<section>
  <div class="card bg-white shadow-sm ring-1 ring-zinc-200 rounded-2xl">
    <div class="card-body p-5">
      <h2 class="text-base font-semibold text-zinc-900">{セクション名}</h2>
      <ul class="space-y-1 mt-2">
        <li><a href="#" class="text-sm text-blue-600 hover:underline">{表示テキスト}</a></li>
      </ul>
    </div>
  </div>
</section>
```

### 複数エントリの動的追加（JS）

フォームで項目を動的に追加・削除する場合のパターン:

```html
<div id="entries" class="space-y-4">
  <div class="entry rounded-xl border border-zinc-200 p-4 space-y-3 bg-zinc-50">
    <!-- フィールド -->
    <button type="button" onclick="removeEntry(this)" class="btn btn-outline btn-error btn-sm">削除</button>
  </div>
</div>
<button type="button" onclick="addEntry()" class="btn btn-outline btn-sm w-full">＋追加する</button>

<script>
function addEntry() {
  const container = document.getElementById('entries');
  const first = container.querySelector('.entry');
  const clone = first.cloneNode(true);
  clone.querySelectorAll('input,select,textarea').forEach(el => el.value = '');
  container.appendChild(clone);
}
function removeEntry(btn) {
  const container = document.getElementById('entries');
  if (container.querySelectorAll('.entry').length <= 1) return;
  btn.closest('.entry').remove();
}
</script>
```

### セクションの開閉（JS）

```html
<button type="button" onclick="toggleSection('section-id')" class="btn btn-outline btn-sm">
  アップロードフォームを開く
</button>
<div id="section-id" class="hidden mt-3">
  <!-- コンテンツ -->
</div>

<script>
function toggleSection(id) {
  const el = document.getElementById(id);
  el.classList.toggle('hidden');
}
</script>
```

---

## フェーズ4: index.html の作成・更新

`./mock/{YYYYMMDD}/index.html` を作成する。

また、`./mock/index.html`（ルートの一覧）が存在する場合は、今回の日付フォルダへのリンクを追記する。なければルートの `index.html` も新規作成する。

`./mock/{YYYYMMDD}/index.html` の形式:

```html
<!DOCTYPE html>
<html lang="ja">
<head>
  <meta charset="UTF-8">
  <title>Unifield モック一覧</title>
  <link href="https://cdn.jsdelivr.net/npm/daisyui@4/dist/full.min.css" rel="stylesheet">
  <script src="https://cdn.tailwindcss.com"></script>
  <link href="https://fonts.googleapis.com/css2?family=Noto+Sans+JP:wght@400;500;600&display=swap" rel="stylesheet">
  <style>body { font-family: 'Noto Sans JP', sans-serif; }</style>
</head>
<body class="bg-zinc-50 min-h-screen p-8">
  <div class="max-w-2xl mx-auto">
    <h1 class="text-xl font-bold text-zinc-900 mb-6">Unifield モック一覧</h1>
    <div class="space-y-2">
      <!-- リンク一覧 -->
      <a href="{file}" class="block rounded-xl bg-white shadow-sm ring-1 ring-zinc-200 px-5 py-3 hover:bg-zinc-50">
        <div class="text-sm font-medium text-zinc-900">{画面名}</div>
        <div class="text-xs text-zinc-500 mt-0.5">{説明}</div>
      </a>
    </div>
  </div>
</body>
</html>
```

---

## 完了報告

全ファイル作成後:

> 「モックの作成が完了しました。
>
> **出力先:** `mock/{YYYYMMDD}/`
>
> **作成ファイル（{N}件）:**
> - `mock/{YYYYMMDD}/index.html` — 一覧ナビゲーション
> - `mock/{YYYYMMDD}/{file}.html` — {説明}
> ...
>
> `mock/{YYYYMMDD}/index.html` をブラウザで開くと全画面にアクセスできます。」

---

## 重要なルール

- **デザインの一貫性**: 上記の設計仕様を必ず守る。既存モックがあれば必ずそのデザインを踏襲する
- **JSはバニラのみ**: `<script>` タグ内に直接記述。外部JSライブラリは不可（DaisyUI/Tailwindt内蔵JSを除く）
- **不明点は最初にまとめて質問**: 実装中に手を止めて質問しない。フェーズ1で一括確認する
- **承認不要で進める**: ファイル作成ごとの承認は不要。完了報告のみ行う
- **`./mock/{YYYYMMDD}/` に出力**: 必ず実行日の日付フォルダを作成してその中に出力する。他のディレクトリには出力しない
