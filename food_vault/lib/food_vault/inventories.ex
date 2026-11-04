defmodule FoodVault.Inventories do
  @moduledoc """
  在庫(ロット)と受払履歴。

  ロットのロック・加減算・受払履歴の記録はこのモジュールに 1 か所だけ持ち、
  `FoodVault.ShipmentOrders` などは同じトランザクションの中でここの関数を呼ぶ。
  """

  import Ecto.Query, warn: false

  alias FoodVault.Inventories.InventoryLot
  alias FoodVault.Repo

  ## マスタのガード用の問い合わせ

  @doc "商品のロットが(在庫 0 を含めて)1 件でもあるか。"
  def item_has_lots?(item_id) do
    InventoryLot |> where([l], l.item_id == ^item_id) |> Repo.exists?()
  end

  @doc "商品に在庫(現在庫 > 0)のロットがあるか。"
  def item_has_stock?(item_id) do
    InventoryLot |> where([l], l.item_id == ^item_id) |> with_stock() |> Repo.exists?()
  end

  @doc "倉庫に在庫(現在庫 > 0)のロットがあるか。"
  def warehouse_has_stock?(warehouse_id) do
    InventoryLot |> where([l], l.warehouse_id == ^warehouse_id) |> with_stock() |> Repo.exists?()
  end

  defp with_stock(query), do: where(query, [l], l.case_qty > 0 or l.piece_qty > 0)
end
