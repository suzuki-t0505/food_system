defmodule FoodShip.Utils.Logger.JSONFormatterTest do
  use ExUnit.Case, async: true

  alias FoodShip.Utils.Logger.JSONFormatter

  @config %{metadata: [:request_id, :remote_ip, :mfa, :file, :line]}

  defp event(msg, meta \\ %{}) do
    %{level: :info, msg: msg, meta: Map.merge(%{time: 1_700_000_000_000_000}, meta)}
  end

  defp decode(iodata),
    do: iodata |> IO.iodata_to_binary() |> String.trim_trailing("\n") |> Jason.decode!()

  test "1 行の JSON で出力する" do
    output = JSONFormatter.format(event({:string, "起動しました。"}), @config) |> IO.iodata_to_binary()

    assert String.ends_with?(output, "\n")
    assert length(String.split(output, "\n", trim: true)) == 1
    assert %{"message" => "起動しました。", "level" => "info"} = Jason.decode!(output)
  end

  test "メタデータ (request_id / remote_ip / mfa / file / line) を含む" do
    meta = %{
      request_id: "req-1",
      remote_ip: "192.0.2.1",
      mfa: {MyApp.Foo, :bar, 2},
      file: ~c"lib/foo.ex",
      line: 42
    }

    json = JSONFormatter.format(event({:string, "x"}, meta), @config) |> decode()

    assert json["request_id"] == "req-1"
    assert json["remote_ip"] == "192.0.2.1"
    assert json["mfa"] == "MyApp.Foo.bar/2"
    assert json["file"] == "lib/foo.ex"
    assert json["line"] == 42
    assert json["time"] == "2023-11-14T22:13:20.000000Z"
  end

  test "カテゴリ付きのレポートは message / category / variable を出力する" do
    report = %{message: "作成しました。", category: "作成", variable: %{id: 1}}

    json = JSONFormatter.format(event({:report, report}), @config) |> decode()

    assert json["message"] == "作成しました。"
    assert json["category"] == "作成"
    assert json["variable"] == %{"id" => 1}
  end

  test "キーワードで渡したメタデータの指定でも出力できる" do
    json =
      JSONFormatter.format(event({:string, "x"}, %{request_id: "r", line: 1}),
        metadata: [:request_id]
      )
      |> decode()

    assert json["request_id"] == "r"
    refute Map.has_key?(json, "line")
  end

  test "PID・タプル・構造体など JSON にできない値で落ちない" do
    report = %{
      message: "x",
      category: "その他",
      variable: %{pid: self(), tuple: {1, 2}, mod: URI.parse("http://a")}
    }

    json = JSONFormatter.format(event({:report, report}), @config) |> decode()

    assert is_binary(json["variable"]["pid"])
    assert json["variable"]["tuple"] == "{1, 2}"
    assert is_binary(json["variable"]["mod"]) or is_map(json["variable"]["mod"])
  end

  test "フォーマット文字列と引数のメッセージも出力できる" do
    json = JSONFormatter.format(event({~c"~s と ~p", ["a", :b]}), @config) |> decode()

    assert json["message"] == "a と b"
  end

  test "check_config/1 は map とキーワードを受け付ける" do
    assert JSONFormatter.check_config(%{}) == :ok
    assert JSONFormatter.check_config(metadata: []) == :ok
    assert {:error, _} = JSONFormatter.check_config(:invalid)
  end
end
