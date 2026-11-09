defmodule FoodShip.ShippingSlips.CsvParser do
  @moduledoc """
  伝票の CSV 取込用の解析(純粋関数。DB には触れない)。

  形式は functional-design §6.1: UTF-8(BOM 付きも可)・1 行目は見出し行・1 行 = 1 伝票。
  列は `client_code, client_slip_no, scheduled_ship_date, item_code, order_count`。

  RFC 4180 の範囲を扱う: ダブルクォートでの囲み・`""` のエスケープ・囲みの中のカンマと改行・
  CRLF / LF。各項目は前後の空白を除く。空行は無視する。

  `parse/1` の戻り値は `{:ok, rows}` か `{:error, message}`。`rows` は
  `%{line: レコードの開始行(1 始まり、見出し行が 1), fields: [項目]}` のリストで、
  列数の検査は呼び出し側(行ごとのエラーとして報告するため)で行う。
  """

  @max_bytes 1_048_576
  @max_rows 2_000
  @columns ~w(client_code client_slip_no scheduled_ship_date item_code order_count)
  @bom <<0xEF, 0xBB, 0xBF>>

  @type row :: %{line: pos_integer(), fields: [String.t()]}

  @doc "列名(見出し行と同じ順)。"
  def columns, do: @columns

  @doc "ファイルサイズの上限(バイト)。"
  def max_bytes, do: @max_bytes

  @doc "データ行(見出しを除く)の上限。"
  def max_rows, do: @max_rows

  @spec parse(binary()) :: {:ok, [row()]} | {:error, String.t()}
  def parse(binary) when is_binary(binary) do
    with :ok <- check_size(binary),
         {:ok, text} <- check_utf8(binary),
         {:ok, records} <- records(text),
         {:ok, rows} <- split_header(records) do
      check_rows(rows)
    end
  end

  defp check_size(binary) when byte_size(binary) > @max_bytes,
    do: {:error, "ファイルが大きすぎます(上限 1 MB)。"}

  defp check_size(_binary), do: :ok

  defp check_utf8(binary) do
    text = strip_bom(binary)

    if String.valid?(text),
      do: {:ok, text},
      else: {:error, "UTF-8 の文字コードで保存し直してください。"}
  end

  defp strip_bom(@bom <> rest), do: rest
  defp strip_bom(binary), do: binary

  defp split_header([%{fields: fields} | rows]) do
    if Enum.map(fields, &String.downcase/1) == @columns do
      {:ok, rows}
    else
      {:error, "1 行目の見出しが正しくありません(#{Enum.join(@columns, ", ")} の順)。"}
    end
  end

  defp split_header([]),
    do: {:error, "1 行目の見出しが正しくありません(#{Enum.join(@columns, ", ")} の順)。"}

  defp check_rows([]), do: {:error, "データ行がありません。"}

  defp check_rows(rows) when length(rows) > @max_rows,
    do: {:error, "行数が多すぎます(上限 #{@max_rows} 行)。"}

  defp check_rows(rows), do: {:ok, rows}

  ## レコードへの分割

  defp records(text) do
    scan(text, %{line: 1, start: 1, acc: [], fields: [], records: [], quoted: false})
  end

  # 引用符の中
  defp scan(<<"\"\"", rest::binary>>, %{quoted: true} = st), do: scan(rest, push(st, "\""))
  defp scan(<<"\"", rest::binary>>, %{quoted: true} = st), do: scan(rest, %{st | quoted: false})

  defp scan(<<"\n", rest::binary>>, %{quoted: true} = st),
    do: scan(rest, %{push(st, "\n") | line: st.line + 1})

  defp scan(<<char::utf8, rest::binary>>, %{quoted: true} = st),
    do: scan(rest, push(st, <<char::utf8>>))

  defp scan(<<>>, %{quoted: true}), do: {:error, "ダブルクォートが閉じられていません。"}

  # 引用符の外
  defp scan(<<"\"", rest::binary>>, %{acc: []} = st), do: scan(rest, %{st | quoted: true})
  defp scan(<<",", rest::binary>>, st), do: scan(rest, end_field(st))
  defp scan(<<"\r\n", rest::binary>>, st), do: scan(rest, end_record(st))
  defp scan(<<"\n", rest::binary>>, st), do: scan(rest, end_record(st))
  defp scan(<<"\r", rest::binary>>, st), do: scan(rest, end_record(st))
  defp scan(<<char::utf8, rest::binary>>, st), do: scan(rest, push(st, <<char::utf8>>))
  defp scan(<<>>, st), do: {:ok, st |> end_record() |> Map.fetch!(:records) |> Enum.reverse()}

  defp push(st, chars), do: %{st | acc: [chars | st.acc]}

  defp end_field(st) do
    field = st.acc |> Enum.reverse() |> IO.iodata_to_binary() |> String.trim()
    %{st | acc: [], fields: [field | st.fields]}
  end

  # 空行(項目が空 1 つだけ)は無視する
  defp end_record(st) do
    st = end_field(st)

    records =
      case Enum.reverse(st.fields) do
        [""] -> st.records
        fields -> [%{line: st.start, fields: fields} | st.records]
      end

    %{st | fields: [], records: records, line: st.line + 1, start: st.line + 1}
  end
end
