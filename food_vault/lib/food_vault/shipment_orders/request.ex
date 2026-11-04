defmodule FoodVault.ShipmentOrders.Request do
  @moduledoc """
  出庫引当の要求(画面のフォーム・在庫 API の JSON)を検証して正規化する。

  明細は可変個で `cast_assoc` を使わないため、changeset ではなくエラーのリストを返す。
  エラーは `%{path: ["lines", 0, "req_cases"], message: "..."}`(`path` は入力のキーの並び)。
  キーは文字列でもアトムでもよい。`lines` はリスト、または `%{"0" => %{...}}` 形式(フォーム)。
  """

  @type t :: %{
          warehouse_id: String.t(),
          shipment_date: Date.t(),
          external_slip_id: String.t() | nil,
          lines: [map()]
        }

  @doc """
  要求を検証する。成功すると、明細を `item_id` 昇順に並べた要求を返す
  (各明細に入力上の位置 `index` を残す)。
  """
  @spec normalize(map()) :: {:ok, t()} | {:error, :validation_failed, [map()]}
  def normalize(attrs) when is_map(attrs) do
    {warehouse_id, e1} = cast_id(get(attrs, :warehouse_id), ["warehouse_id"], "を選択してください")
    {shipment_date, e2} = cast_required_date(get(attrs, :shipment_date))
    {external_slip_id, e3} = cast_slip_id(get(attrs, :external_slip_id))
    {lines, e4} = normalize_lines(get(attrs, :lines))

    case e1 ++ e2 ++ e3 ++ e4 do
      [] ->
        {:ok,
         %{
           warehouse_id: warehouse_id,
           shipment_date: shipment_date,
           external_slip_id: external_slip_id,
           lines: Enum.sort_by(lines, & &1.item_id)
         }}

      errors ->
        {:error, :validation_failed, errors}
    end
  end

  def normalize(_), do: {:error, :validation_failed, [%{path: [], message: "リクエストが正しくありません"}]}

  @doc """
  既存のオーダー(明細を preload 済み)が、要求と同じ内容か。

  `warehouse_id`・`shipment_date` と、明細の `item_id`・`req_cases`・`req_pieces`・
  `min_expiration_date`(`item_id` 順に正規化)を比べる。`external_slip_id` の冪等判定に使う。
  """
  def same?(order, request) do
    order.warehouse_id == request.warehouse_id and order.shipment_date == request.shipment_date and
      canonical(order.lines) == canonical(request.lines)
  end

  defp canonical(lines) do
    lines
    |> Enum.sort_by(& &1.item_id)
    |> Enum.map(&{&1.item_id, &1.req_cases, &1.req_pieces, &1.min_expiration_date})
  end

  ## 明細

  defp normalize_lines(lines) when is_map(lines) and not is_struct(lines) do
    lines
    |> Enum.sort_by(fn {key, _} -> sort_key(key) end)
    |> Enum.map(fn {_key, line} -> line end)
    |> normalize_lines()
  end

  defp normalize_lines([_ | _] = lines) do
    {casted, errors} =
      lines
      |> Enum.with_index()
      |> Enum.map(fn {line, index} -> normalize_line(line, index) end)
      |> Enum.unzip()

    {casted, List.flatten(errors) ++ duplicate_errors(casted)}
  end

  defp normalize_lines(_), do: {[], [%{path: ["lines"], message: "明細を 1 件以上入力してください"}]}

  defp sort_key(key) when is_binary(key) do
    case Integer.parse(key) do
      {int, ""} -> {0, int}
      _ -> {1, key}
    end
  end

  defp sort_key(key), do: {1, to_string(key)}

  defp normalize_line(line, index) when is_map(line) do
    path = ["lines", index]
    {item_id, e1} = cast_id(get(line, :item_id), path ++ ["item_id"], "を選択してください")
    {req_cases, e2} = cast_quantity(get(line, :req_cases), path ++ ["req_cases"])
    {req_pieces, e3} = cast_quantity(get(line, :req_pieces), path ++ ["req_pieces"])

    {min_date, e4} =
      cast_optional_date(get(line, :min_expiration_date), path ++ ["min_expiration_date"])

    e5 = quantity_present_error(req_cases, req_pieces, path)

    {%{
       index: index,
       item_id: item_id,
       req_cases: req_cases,
       req_pieces: req_pieces,
       min_expiration_date: min_date
     }, e1 ++ e2 ++ e3 ++ e4 ++ e5}
  end

  defp normalize_line(_line, index) do
    {%{index: index, item_id: nil, req_cases: nil, req_pieces: nil, min_expiration_date: nil},
     [%{path: ["lines", index], message: "明細が正しくありません"}]}
  end

  defp quantity_present_error(req_cases, req_pieces, path)
       when is_integer(req_cases) and is_integer(req_pieces) and req_cases + req_pieces == 0 do
    [%{path: path ++ ["req_cases"], message: "ケース数かバラ数のどちらかは 1 以上にしてください"}]
  end

  defp quantity_present_error(_req_cases, _req_pieces, _path), do: []

  defp duplicate_errors(lines) do
    lines
    |> Enum.filter(& &1.item_id)
    |> Enum.reduce({MapSet.new(), []}, fn line, {seen, errors} ->
      if MapSet.member?(seen, line.item_id) do
        error = %{path: ["lines", line.index, "item_id"], message: "は同じ商品が重複しています"}
        {seen, [error | errors]}
      else
        {MapSet.put(seen, line.item_id), errors}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  ## 値の変換

  defp get(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp cast_id(value, path, message) when is_binary(value) do
    case Ecto.ULID.cast(value) do
      {:ok, id} -> {id, []}
      :error -> {nil, [%{path: path, message: message}]}
    end
  end

  defp cast_id(_value, path, message), do: {nil, [%{path: path, message: message}]}

  defp cast_required_date(%Date{} = date), do: {date, []}

  defp cast_required_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {date, []}
      _ -> {nil, [%{path: ["shipment_date"], message: "を正しい日付で入力してください"}]}
    end
  end

  defp cast_required_date(_), do: {nil, [%{path: ["shipment_date"], message: "を入力してください"}]}

  defp cast_optional_date(value, _path) when value in [nil, ""], do: {nil, []}
  defp cast_optional_date(%Date{} = date, _path), do: {date, []}

  defp cast_optional_date(value, path) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {date, []}
      _ -> {nil, [%{path: path, message: "を正しい日付で入力してください"}]}
    end
  end

  defp cast_optional_date(_, path), do: {nil, [%{path: path, message: "を正しい日付で入力してください"}]}

  defp cast_quantity(value, _path) when value in [nil, ""], do: {0, []}
  defp cast_quantity(value, _path) when is_integer(value) and value >= 0, do: {value, []}

  defp cast_quantity(value, path) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} when int >= 0 -> {int, []}
      _ -> {nil, [%{path: path, message: "は 0 以上の整数で入力してください"}]}
    end
  end

  defp cast_quantity(_, path), do: {nil, [%{path: path, message: "は 0 以上の整数で入力してください"}]}

  defp cast_slip_id(value) when value in [nil, ""], do: {nil, []}

  defp cast_slip_id(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" ->
        {nil, []}

      String.length(value) > 255 ->
        {nil, [%{path: ["external_slip_id"], message: "は 255 文字以内で入力してください"}]}

      true ->
        {value, []}
    end
  end

  defp cast_slip_id(_), do: {nil, [%{path: ["external_slip_id"], message: "が正しくありません"}]}
end
