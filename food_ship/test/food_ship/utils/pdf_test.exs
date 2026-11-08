defmodule FoodShip.Utils.PdfTest do
  # Application 環境を一時的に書き換えるので async: false
  use ExUnit.Case, async: false

  alias FoodShip.Utils.Pdf

  @html """
  <!doctype html>
  <html lang="ja"><head><meta charset="utf-8"><style>
  @page { size: A4 portrait; margin: 12mm }
  body { font-family: "Noto Sans JP", "Noto Sans CJK JP", sans-serif }
  </style></head>
  <body><h1>トータルピック表 TP-000001</h1><table border="1"><tr><td>缶詰</td><td>50</td></tr></table></body></html>
  """

  describe "render/1(test 環境は Fake)" do
    test "HTML を受け取り、PDF として返す" do
      assert {:ok, "%PDF" <> _ = pdf} = Pdf.render(@html)
      assert pdf =~ "トータルピック表 TP-000001"
    end
  end

  describe "child_specs/0" do
    test "test 環境は起動しない(start: false)" do
      assert Pdf.child_specs() == []
    end

    test "start: true のときはアダプタの子プロセス仕様を返す" do
      original = Application.get_env(:food_ship, Pdf)

      on_exit(fn -> Application.put_env(:food_ship, Pdf, original) end)

      Application.put_env(
        :food_ship,
        Pdf,
        adapter: Pdf.Chromic,
        start: true,
        pool_size: 3,
        timeout: 5000,
        no_sandbox: true,
        chrome_executable: "/usr/bin/chromium"
      )

      assert [{ChromicPDF, opts}] = Pdf.child_specs()
      assert opts[:session_pool] == [size: 3, timeout: 5000]
      assert opts[:no_sandbox] == true
      assert opts[:chrome_executable] == "/usr/bin/chromium"
    end

    test "Chromium のパスが未設定なら chrome_executable を渡さない" do
      assert [{ChromicPDF, opts}] = Pdf.Chromic.child_specs(pool_size: 1)
      refute Keyword.has_key?(opts, :chrome_executable)
      assert opts[:no_sandbox] == false
    end
  end

  # 実 Chromium で PDF を生成する。`PDF_TEST=1`(`PDF_CHROME_PATH` で実行パスを指定可)のときだけ実行
  describe "Pdf.Chromic(実 Chromium)" do
    @describetag :pdf

    setup do
      original = Application.get_env(:food_ship, Pdf)
      on_exit(fn -> Application.put_env(:food_ship, Pdf, original) end)

      config = Keyword.merge(original, adapter: Pdf.Chromic, start: true, no_sandbox: true)
      Application.put_env(:food_ship, Pdf, config)

      start_supervised!(%{
        id: :chromic_pdf_test,
        start: {Supervisor, :start_link, [Pdf.child_specs(), [strategy: :one_for_one]]},
        type: :supervisor
      })

      :ok
    end

    test "日本語を含む HTML から PDF(%PDF)を得る" do
      assert {:ok, "%PDF" <> _ = pdf} = Pdf.render(@html)
      assert byte_size(pdf) > 1000
    end
  end
end
