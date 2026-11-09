defmodule FoodShip.ShippingSlips.CsvImport do
  @moduledoc """
  伝票 CSV の行の検証(`CsvParser` の次の段階)。形式 → マスタ → ファイル内の重複の順に、
  **エラーを全行ぶん集めて**返す。DB には書かない(読むのはマスタの参照だけ)。

  既存の伝票との重複・数量の検証は、手入力と同じ `ShippingSlip.create_changeset/2` で
  `FoodShip.ShippingSlips.import_csv/2` が行う。

  `prepare/1` の戻り値の `entries` は、`import_csv/2` が `build_attrs` に渡せる形
  (`"client_id"`・`"shipping_item_id"`・`"client_slip_no"`・`"scheduled_ship_date"`(Date)・
  `"order_count"`(整数))で、`line` は CSV の行番号。
  """

  import Ecto.Query, warn: false

  alias FoodShip.Clients.Client
  alias FoodShip.Repo
  alias FoodShip.ShippingItems.ShippingItem
  alias FoodShip.ShippingSlips.CsvParser

  # 4 バイト整数の列に収まるように、件数の上限を決める(出庫総数量はさらに別に検査する)
  @max_order_count 1_000_000

  @type error :: %{line: pos_integer(), message: String.t()}
  @type entry :: %{line: pos_integer(), attrs: map(), client_code: String.t()}

  @doc "件数の上限。"
  def max_order_count, do: @max_order_count

  @doc """
  行を検証する。戻り値は `{検証を通った行, エラー}`(エラーは行番号順。`Enum.sort_by/2` は安定なので、
  同じ行のエラーは検出順)。
  """
  @spec prepare([CsvParser.row()]) :: {[entry()], [error()]}
  def prepare(rows) do
    parsed = Enum.map(rows, &parse_row/1)

    clients = lookup(Client, :client_code, parsed, :client_code)
    items = lookup(ShippingItem, :item_code, parsed, :item_code)

    {entries, errors, _seen} =
      Enum.reduce(parsed, {[], [], %{}}, fn row, {entries, errors, seen} ->
        check_row(row, clients, items, entries, errors, seen)
      end)

    {Enum.reverse(entries), errors |> Enum.reverse() |> Enum.sort_by(& &1.line)}
  end

  ## 形式の検証

  defp parse_row(%{line: line, fields: [client_code, slip_no, date, item_code, count]}) do
    named = [
      client_code: client_code,
      client_slip_no: slip_no,
      scheduled_ship_date: date,
      item_code: item_code,
      order_count: count
    ]

    blank = for {name, ""} <- named, do: "#{name} は必須です。"

    {date_value, date_errors} = parse_date(date)
    {count_value, count_errors} = parse_count(count)

    %{
      line: line,
      errors: blank ++ date_errors ++ count_errors,
      client_code: client_code,
      slip_no: slip_no,
      item_code: item_code,
      date: date_value,
      count: count_value
    }
  end

  defp parse_row(%{line: line, fields: fields}) do
    %{
      line: line,
      errors: ["列数が正しくありません(#{length(CsvParser.columns())} 列必要。#{length(fields)} 列ありました)。"]
    }
  end

  defp parse_date(""), do: {nil, []}

  defp parse_date(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {date, []}
      _ -> {nil, ["scheduled_ship_date は YYYY-MM-DD 形式で入力してください。"]}
    end
  end

  defp parse_count(""), do: {nil, []}

  defp parse_count(value) do
    case Integer.parse(value) do
      {count, ""} when count >= 1 and count <= @max_order_count -> {count, []}
      _ -> {nil, ["order_count は 1 以上 #{@max_order_count} 以下の整数で入力してください。"]}
    end
  end

  ## マスタ

  # 形式が正しい行のコードをまとめて 1 クエリで引く。`%{コード => マスタ}`(アーカイブ済みも含む)
  defp lookup(schema, field, parsed, key) do
    codes =
      parsed
      |> Enum.map(&Map.get(&1, key))
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()

    schema
    |> where([m], field(m, ^field) in ^codes)
    |> Repo.all()
    |> Map.new(&{Map.fetch!(&1, field), &1})
  end

  ## 1 行の検査(マスタ・ファイル内の重複)

  defp check_row(%{errors: [_ | _]} = row, clients, items, entries, acc, seen) do
    # 形式のエラーがあっても、マスタのエラーは同じ行にまとめて報告する
    errors = row.errors ++ master_errors(row, clients, items)
    {entries, add_errors(acc, row.line, errors), seen}
  end

  defp check_row(row, clients, items, entries, acc, seen) do
    case master_errors(row, clients, items) do
      [] ->
        client = Map.fetch!(clients, row.client_code)
        item = Map.fetch!(items, row.item_code)
        key = {client.id, row.slip_no, item.id}

        case seen do
          %{^key => first_line} ->
            message = "client_slip_no「#{row.slip_no}」は #{first_line} 行目と重複しています。"
            {entries, add_errors(acc, row.line, [message]), seen}

          _ ->
            entry = %{
              line: row.line,
              client_code: row.client_code,
              attrs: %{
                "client_id" => client.id,
                "shipping_item_id" => item.id,
                "client_slip_no" => row.slip_no,
                "scheduled_ship_date" => row.date,
                "order_count" => row.count
              }
            }

            {[entry | entries], acc, Map.put(seen, key, row.line)}
        end

      errors ->
        {entries, add_errors(acc, row.line, errors), seen}
    end
  end

  defp master_errors(%{client_code: client_code, item_code: item_code}, clients, items) do
    master_error("client_code", client_code, clients) ++
      master_error("item_code", item_code, items)
  end

  # 列数が合わない行はコードを読めない
  defp master_errors(_row, _clients, _items), do: []

  defp master_error(_label, "", _masters), do: []

  defp master_error(label, code, masters) do
    case Map.get(masters, code) do
      nil -> ["#{label}「#{code}」は登録されていません。"]
      %{archived_at: nil} -> []
      _archived -> ["#{label}「#{code}」はアーカイブ済みです。"]
    end
  end

  defp add_errors(acc, line, messages) do
    Enum.reduce(messages, acc, fn message, acc -> [%{line: line, message: message} | acc] end)
  end
end
