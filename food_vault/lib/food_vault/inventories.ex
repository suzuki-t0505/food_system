defmodule FoodVault.Inventories do
  @moduledoc """
  在庫(ロット)と受払履歴。

  ロットのロック・加減算・受払履歴の記録はこのモジュールに 1 か所だけ持ち、
  `FoodVault.ShipmentOrders` などは同じトランザクションの中でここの関数を呼ぶ。

  ## 操作者(actor)

  書き込み関数の第 1 引数。画面のユーザー(`%User{}`)か、在庫 API の `{:api, operator}`。
  受払履歴には `user_id` / `operator` のどちらかが残る。

  ## ロック

  ロックの順序は全操作で共通: 倉庫(`FOR SHARE`)→ 商品(`FOR SHARE`、`id` 昇順)→
  ロット(1 クエリで `FOR UPDATE`、`lock_key_order/1` の昇順)。途中で追加のロットをロックしない。
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias FoodVault.Inventories.{InventoryLot, InventoryTransaction}
  alias FoodVault.{Items, Repo, Warehouses}
  alias FoodVault.Utils.{Calc, ConvertDatetime, Permission}

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

  ## 入荷

  @receipt_types %{
    warehouse_id: Ecto.ULID,
    item_id: Ecto.ULID,
    expiration_date: :date,
    received_date: :date,
    case_qty: :integer,
    piece_qty: :integer
  }

  @doc """
  入荷フォーム用の changeset(スキーマレス)。

  `received_date` の既定は今日(JST)、数量の既定は 0。数量が空欄でも 0 として扱う。
  期限区分に応じた期限日の検証は `receive_inventory/2` が商品を読んでから行う。
  """
  def change_receipt(attrs \\ %{}) do
    data = %{
      warehouse_id: nil,
      item_id: nil,
      expiration_date: nil,
      received_date: ConvertDatetime.today_jst(),
      case_qty: 0,
      piece_qty: 0
    }

    {data, @receipt_types}
    |> Ecto.Changeset.cast(attrs, Map.keys(@receipt_types))
    |> default_zero(:case_qty)
    |> default_zero(:piece_qty)
    |> Ecto.Changeset.validate_required([:warehouse_id, :item_id, :received_date])
    |> Ecto.Changeset.validate_number(:case_qty, greater_than_or_equal_to: 0)
    |> Ecto.Changeset.validate_number(:piece_qty, greater_than_or_equal_to: 0)
    |> validate_quantity_present()
  end

  defp default_zero(changeset, field) do
    if is_nil(Ecto.Changeset.get_field(changeset, field)) do
      Ecto.Changeset.put_change(changeset, field, 0)
    else
      changeset
    end
  end

  defp validate_quantity_present(changeset) do
    cases = Ecto.Changeset.get_field(changeset, :case_qty)
    pieces = Ecto.Changeset.get_field(changeset, :piece_qty)

    if is_integer(cases) and is_integer(pieces) and cases + pieces == 0 do
      Ecto.Changeset.add_error(changeset, :case_qty, "ケース数かバラ数のどちらかは 1 以上にしてください")
    else
      changeset
    end
  end

  @doc """
  入荷を登録する。

  `attrs`: `warehouse_id`・`item_id`・`expiration_date`・`received_date`・`case_qty`・`piece_qty`。
  期限区分が `none` の商品は期限日を `9999-12-31` にする(入力があっても無視)。それ以外は期限日が必須。

  同じ「倉庫 × 商品 × 期限日 × 入荷日」のロットがあれば加算し、なければ新規作成する
  (`INSERT ... ON CONFLICT DO UPDATE` で原子的。同時入荷でも加算は失われない)。
  受払履歴に `receive` を記録する。

  成功: `{:ok, %{lot: lot, transaction: transaction}}`。
  失敗: `{:error, changeset}`(入力不正・アーカイブ済みの倉庫/商品)、`{:error, :forbidden}`。
  """
  def receive_inventory(actor, attrs) do
    with :ok <- Permission.authorize(actor, :receive_inventory) do
      changeset = change_receipt(attrs)

      if changeset.valid? do
        actor |> receipt_multi(changeset) |> Repo.transact() |> unwrap_receipt()
      else
        {:error, %{changeset | action: :insert}}
      end
    end
  end

  defp receipt_multi(actor, changeset) do
    Multi.new()
    |> Multi.run(:target, fn _repo, _ -> lock_receipt_target(changeset) end)
    |> Multi.run(:lot, fn _repo, %{target: target} -> upsert_lot(target) end)
    |> Multi.run(:transaction, fn _repo, %{target: target, lot: lot} ->
      record_transaction(actor, lot.id, :receive, target.case_qty, target.piece_qty)
    end)
  end

  defp unwrap_receipt({:ok, %{lot: lot, transaction: transaction}}),
    do: {:ok, %{lot: lot, transaction: transaction}}

  defp unwrap_receipt({:error, :target, %Ecto.Changeset{} = invalid, _changes}),
    do: {:error, %{invalid | action: :insert}}

  # 倉庫・商品を FOR SHARE で読み、アーカイブ済みと期限日の不備を changeset のエラーにする
  defp lock_receipt_target(changeset) do
    data = Ecto.Changeset.apply_changes(changeset)
    warehouse = Warehouses.lock_active_warehouse_for_share(data.warehouse_id)
    item = data.item_id |> List.wrap() |> Items.lock_active_items_for_share() |> List.first()

    changeset
    |> require_present(:warehouse_id, warehouse, "は有効な倉庫を選択してください")
    |> require_present(:item_id, item, "は有効な商品を選択してください")
    |> put_expiration(item)
    |> case do
      %Ecto.Changeset{errors: []} = ok -> {:ok, Ecto.Changeset.apply_changes(ok)}
      invalid -> {:error, invalid}
    end
  end

  defp require_present(changeset, field, nil, message),
    do: Ecto.Changeset.add_error(changeset, field, message)

  defp require_present(changeset, _field, _record, _message), do: changeset

  defp put_expiration(changeset, nil), do: changeset

  defp put_expiration(changeset, %{expiration_type: :none}),
    do: Ecto.Changeset.put_change(changeset, :expiration_date, Calc.no_expiration_date())

  defp put_expiration(changeset, _item) do
    if Ecto.Changeset.get_field(changeset, :expiration_date) do
      changeset
    else
      Ecto.Changeset.add_error(changeset, :expiration_date, "期限日を入力してください")
    end
  end

  defp upsert_lot(target) do
    now = DateTime.utc_now(:second)

    Repo.insert(
      %InventoryLot{
        warehouse_id: target.warehouse_id,
        item_id: target.item_id,
        expiration_date: target.expiration_date,
        received_date: target.received_date,
        case_qty: target.case_qty,
        piece_qty: target.piece_qty
      },
      on_conflict: [
        inc: [case_qty: target.case_qty, piece_qty: target.piece_qty],
        set: [updated_at: now]
      ],
      conflict_target: [:warehouse_id, :item_id, :expiration_date, :received_date],
      returning: true
    )
  end

  ## ロックと受払履歴(ShipmentOrders・棚卸調整と共用)

  @doc "操作者を受払履歴・オーダー履歴の `user_id` / `operator` に変換する。"
  def actor_fields(%{id: id, role: _role}), do: %{user_id: id}
  def actor_fields({:api, operator}) when is_binary(operator), do: %{operator: operator}

  @doc """
  ロットの全操作共通のロックキー順に並べる。

  `(warehouse_id, item_id, expiration_date, received_date, id)` の昇順。
  """
  def lock_key_order(query) do
    order_by(query, [l],
      asc: l.warehouse_id,
      asc: l.item_id,
      asc: l.expiration_date,
      asc: l.received_date,
      asc: l.id
    )
  end

  @doc "指定ロットを 1 クエリでロック(`FOR UPDATE`)して、ロックキー順に返す。"
  def lock_lots_by_ids(lot_ids) do
    InventoryLot
    |> where([l], l.id in ^lot_ids)
    |> lock_key_order()
    |> lock("FOR UPDATE")
    |> Repo.all()
  end

  @doc """
  受払履歴を 1 行追加する。`actor` と `type` は必須、`opts` に
  `:shipment_order_id`・`:transfer_id`・`:note` を渡せる。
  """
  def record_transaction(actor, lot_id, type, case_diff, piece_diff, opts \\ []) do
    attrs =
      opts
      |> Map.new()
      |> Map.merge(actor_fields(actor))
      |> Map.merge(%{
        lot_id: lot_id,
        transaction_type: type,
        case_diff: case_diff,
        piece_diff: piece_diff
      })

    attrs |> InventoryTransaction.insert_changeset() |> Repo.insert()
  end

  ## 参照

  @doc "ロットを取得する(倉庫・商品・メーカーを preload)。"
  def get_inventory_lot!(id) do
    InventoryLot |> preload([:warehouse, item: :maker]) |> Repo.get!(id)
  end

  @doc """
  ロット一覧(ページング、期限の近い順)。

  params: `"warehouse_id"`・`"item_id"`・`"expiration_from"`・`"expiration_to"`(ISO 日付)・
  `"include_empty" => "true"`(既定は在庫 0 のロットを除く)。不正な値は無視する。
  """
  def list_inventory_lots(params \\ %{}) do
    InventoryLot
    |> filter_lots(params)
    |> order_by([l], asc: l.expiration_date, asc: l.received_date, asc: l.id)
    |> preload([:warehouse, item: :maker])
    |> Repo.paginate(params)
  end

  @doc """
  商品別の集計(倉庫 × 商品。ページング、最も近い期限の順)。

  params は `list_inventory_lots/1` と同じ。戻りの各要素は
  `%{warehouse_id, item_id, warehouse_code, warehouse_name, item_code, item_name,
  units_per_case, case_qty, piece_qty, allocated_case_qty, allocated_piece_qty, earliest_expiration}`。
  """
  def list_inventory_summaries(params \\ %{}) do
    grouped =
      from l in InventoryLot,
        join: i in assoc(l, :item),
        join: w in assoc(l, :warehouse),
        group_by: [
          l.warehouse_id,
          l.item_id,
          w.warehouse_code,
          w.warehouse_name,
          i.item_code,
          i.item_name,
          i.units_per_case
        ],
        select: %{
          warehouse_id: l.warehouse_id,
          item_id: l.item_id,
          warehouse_code: w.warehouse_code,
          warehouse_name: w.warehouse_name,
          item_code: i.item_code,
          item_name: i.item_name,
          units_per_case: i.units_per_case,
          case_qty: sum(l.case_qty),
          piece_qty: sum(l.piece_qty),
          allocated_case_qty: sum(l.allocated_case_qty),
          allocated_piece_qty: sum(l.allocated_piece_qty),
          earliest_expiration: min(l.expiration_date)
        }

    from(s in subquery(filter_lots(grouped, params)),
      order_by: [asc: s.earliest_expiration, asc: s.item_code, asc: s.warehouse_code]
    )
    |> Repo.paginate(params)
  end

  defp filter_lots(query, params) do
    query
    |> filter_id(:warehouse_id, params["warehouse_id"])
    |> filter_id(:item_id, params["item_id"])
    |> filter_date(:expiration_date, :gte, params["expiration_from"])
    |> filter_date(:expiration_date, :lte, params["expiration_to"])
    |> filter_empty(params["include_empty"])
  end

  defp filter_empty(query, "true"), do: query
  defp filter_empty(query, _), do: with_stock(query)

  defp filter_id(query, field, value) do
    case parse_id(value) do
      nil -> query
      id -> where(query, [l], field(l, ^field) == ^id)
    end
  end

  defp filter_date(query, field, :gte, value) do
    case parse_date(value) do
      nil -> query
      date -> where(query, [l], field(l, ^field) >= ^date)
    end
  end

  defp filter_date(query, field, :lte, value) do
    case parse_date(value) do
      nil -> query
      date -> where(query, [l], field(l, ^field) <= ^date)
    end
  end

  defp parse_id(value) when is_binary(value) do
    case Ecto.ULID.cast(value) do
      {:ok, id} -> id
      :error -> nil
    end
  end

  defp parse_id(_), do: nil

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parse_date(_), do: nil

  @doc """
  受払履歴の検索(ページング、新しい順)。

  params: `"lot_id"`・`"item_id"`・`"warehouse_id"`・`"user_id"`・`"transaction_type"`・
  `"from"`・`"to"`(JST の日付。両端を含む)。不正な値は無視する。
  """
  def list_inventory_transactions(params \\ %{}) do
    InventoryTransaction
    |> join(:inner, [t], l in assoc(t, :lot), as: :lot)
    |> filter_transactions(params)
    |> order_by([t], desc: t.inserted_at, desc: t.id)
    |> preload([:user, lot: [:warehouse, :item]])
    |> Repo.paginate(params)
  end

  defp filter_transactions(query, params) do
    query
    |> filter_transaction_id(:lot_id, params["lot_id"])
    |> filter_transaction_id(:user_id, params["user_id"])
    |> filter_lot_id(:item_id, params["item_id"])
    |> filter_lot_id(:warehouse_id, params["warehouse_id"])
    |> filter_transaction_type(params["transaction_type"])
    |> filter_period(params["from"], params["to"])
  end

  defp filter_transaction_id(query, field, value) do
    case parse_id(value) do
      nil -> query
      id -> where(query, [t], field(t, ^field) == ^id)
    end
  end

  defp filter_lot_id(query, field, value) do
    case parse_id(value) do
      nil -> query
      id -> where(query, [lot: l], field(l, ^field) == ^id)
    end
  end

  defp filter_transaction_type(query, value) do
    case Enum.find(InventoryTransaction.transaction_types(), &(Atom.to_string(&1) == value)) do
      nil -> query
      type -> where(query, [t], t.transaction_type == ^type)
    end
  end

  defp filter_period(query, from, to) do
    query =
      case parse_date(from) do
        nil -> query
        date -> where(query, [t], t.inserted_at >= ^ConvertDatetime.beginning_of_day_utc(date))
      end

    case parse_date(to) do
      nil -> query
      date -> where(query, [t], t.inserted_at < ^ConvertDatetime.end_of_day_utc(date))
    end
  end
end
