# 実 Chromium を使う PDF のテストは `PDF_TEST=1` のときだけ実行する
ExUnit.start(exclude: if(System.get_env("PDF_TEST") == "1", do: [], else: [pdf: true]))
Ecto.Adapters.SQL.Sandbox.mode(FoodShip.Repo, :manual)
