---
title: "Phoenixで〇〇を実装したら△△エラーが出たので解決する"
tags:
  - Elixir
  - Phoenix
  - LiveView
private: false
---

<!--
Qiita ドラフトのテンプレート。構成と文体は style-guide.md（過去の投稿記事の傾向）に合わせている。
- 上の front matter は Qiita CLI（qiita-cli）の形式。手動で貼り付けて投稿する場合は front matter とこのコメントを除く
- 見出しは題材に合わせて言い換える・削る（「## 〇〇を実装」は実際の作業名にする）
- 「（スクリーンショット: 〜）」は投稿時に画像へ差し替える目印
-->

# はじめに

今回は〇〇を実装していたときに発生した△△エラーと、その解決方法をまとめます。

この記事では以下のバージョンを使用しています。

```bash
$ elixir -v
Erlang/OTP 29
Elixir 1.20.5

$ mix phx.new -v
Phoenix installer v1.8.16
```

## 〇〇を実装

まず、〇〇をするために以下のコードを追加しました。

```diff_elixir:lib/sample_web/live/sample_live.ex
defmodule SampleWeb.SampleLive do
...
+   def handle_event("save", params, socket) do
+     ...
+   end
...
end
```

## 発生したエラー

以下のコマンドを実行します。

```bash
mix test
```

すると以下のエラーが発生しました。

```
** (SampleError) エラーメッセージ（検索に掛かる部分は原文のまま）
```

（スクリーンショット: エラー画面）

## 原因

原因は〇〇でした。

```elixir:lib/sample_web/live/sample_live.ex
# 問題のあったコード
```

まず、`foo/1`で〜をしています。
続いて、`bar/2`で〜をしていますが、ここで〜となるためエラーになります。

:::note warn
最初は〜が原因だと考えて〜を試しましたが、〜のため解決しませんでした。
:::

## 解決方法

以下のように修正します。

```diff_elixir:lib/sample_web/live/sample_live.ex
defmodule SampleWeb.SampleLive do
...
-   修正前のコード
+   修正後のコード
...
end
```

〜とすることで、〜されるようになります。

もう一度コマンドを実行すると、エラーが出ずに成功しました。

```bash
mix test
```

:::note info
補足があればここに書きます。
:::

## 最後

〇〇は〜なので、〜するときは注意が必要でした。
自分は〜だと思い込んでいたので、原因に気づくまで時間がかかりました。

https://hexdocs.pm/phoenix/overview.html

ここまで読んでいただきありがとうございました。
