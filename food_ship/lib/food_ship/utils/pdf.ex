defmodule FoodShip.Utils.Pdf do
  @moduledoc """
  PDF 生成の境界(外部 I/O)。HTML を受け取り、PDF のバイナリを返す。

  実際の生成は設定したアダプタに委譲する(`config :food_ship, FoodShip.Utils.Pdf, adapter: ...`)。

    * 本番・開発: `FoodShip.Utils.Pdf.Chromic`(ChromicPDF = ヘッドレス Chromium)
    * テスト: `FoodShip.Utils.Pdf.Fake`(`%PDF-FAKE` ＋ HTML をそのまま返す。HTML の内容を検査できる)

  帳票は都度生成して保存しない。HTML に外部リソースを書かない(architecture §10.2)。
  同時に生成できる件数はセッションプールの大きさで制限し、待ち切れないときは `{:error, :busy}`。
  """

  @type result :: {:ok, binary()} | {:error, :busy | :invalid_pdf | term()}

  @doc "アダプタが実装する関数。"
  @callback render(html :: binary()) :: result()

  @doc "アダプタが起動する子プロセスの仕様(`start: false` なら空)。"
  @callback child_specs(opts :: keyword()) :: [
              Supervisor.child_spec() | module() | {module(), term()}
            ]

  @doc "HTML から PDF を生成する。"
  @spec render(binary()) :: result()
  def render(html) when is_binary(html), do: adapter().render(html)

  @doc "アプリ起動時に監視木へ足す子プロセス。`start: false`(テスト)のときは空。"
  @spec child_specs() :: [Supervisor.child_spec() | module() | {module(), term()}]
  def child_specs do
    config = config()

    if Keyword.get(config, :start, false) do
      adapter().child_specs(config)
    else
      []
    end
  end

  defp adapter, do: Keyword.fetch!(config(), :adapter)
  defp config, do: Application.get_env(:food_ship, __MODULE__, [])
end
