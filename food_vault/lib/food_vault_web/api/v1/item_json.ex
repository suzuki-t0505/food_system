defmodule FoodVaultWeb.Api.V1.ItemJSON do
  @moduledoc """
  商品の JSON 表現(在庫 API ⑦)。メーカー別のグルーピング用に `maker_id`・`maker_name` を含める。
  `expiration_type` は `consumption` / `best_before` / `none`。
  """

  def index(%{items: items}), do: %{items: Enum.map(items, &item/1)}

  defp item(item) do
    %{
      id: item.id,
      item_code: item.item_code,
      item_name: item.item_name,
      maker_id: item.maker_id,
      maker_name: item.maker.maker_name,
      units_per_case: item.units_per_case,
      expiration_type: Atom.to_string(item.expiration_type)
    }
  end
end
