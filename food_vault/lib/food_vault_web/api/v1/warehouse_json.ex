defmodule FoodVaultWeb.Api.V1.WarehouseJSON do
  @moduledoc "倉庫の JSON 表現(在庫 API ⑥)。"

  def index(%{warehouses: warehouses}), do: %{warehouses: Enum.map(warehouses, &warehouse/1)}

  defp warehouse(warehouse) do
    %{
      id: warehouse.id,
      warehouse_code: warehouse.warehouse_code,
      warehouse_name: warehouse.warehouse_name
    }
  end
end
