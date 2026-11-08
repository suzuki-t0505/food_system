defmodule FoodShip.Utils.Pdf.Fake do
  @moduledoc """
  テスト用の PDF アダプタ。Chromium を起動せず、`"%PDF-FAKE\\n" <> html` を返す。

  Controller のテストで、生成された帳票の HTML(日本語・数量・外部 URL が無いこと)を検査できる。
  """

  @behaviour FoodShip.Utils.Pdf

  @impl true
  def render(html), do: {:ok, "%PDF-FAKE\n" <> html}

  @impl true
  def child_specs(_opts), do: []
end
