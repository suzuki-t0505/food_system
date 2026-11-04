defmodule FoodVault.ShipmentOrders do
  @moduledoc """
  出庫オーダー: 引当・出庫確定・引当解除。

  ロットのロックと数量の更新は `FoodVault.Inventories` に 1 か所だけあり、ここは同じ
  トランザクションの中でそれを呼ぶ。更新はすべて単一トランザクションで、途中で失敗したら
  全体をロールバックする。

  ## 操作者(actor)

  書き込み関数の第 1 引数。画面のユーザー(`%User{}`)か、在庫 API の `{:api, operator}`。
  画面のユーザーは `:manage_shipment_order` 権限(`staff` 以上)が必要で、`external_slip_id` が
  ある(発送システム起源の)オーダーの確定・解除はできない(緊急操作 F-V8 は P1)。

  ## 戻り値

    * 引当・確定・解除の成功: `{:ok, %{shipment_order: order, replayed?: boolean}}`。
      `replayed?` が true なら冪等な再送で、履歴は追加していない
    * `{:error, :insufficient_stock, shortages}` - 在庫不足(全体をロールバック済み)。
      `shortages` は不足した**全明細分**の `[%{item_id, shortage_cases, shortage_pieces}]`
    * `{:error, :validation_failed, errors}` - 入力不正(`errors` は `Request` を参照)
    * `{:error, :idempotency_conflict, existing}` - 同じ `external_slip_id` で内容が違う。
      `existing` は既存のオーダー(`id`・`status` を持つ)。競合の再比較で既存が見つからなかった
      稀なケースだけ `nil`
    * `{:error, :invalid_state}` - その状態からは遷移できない
    * `{:error, :forbidden}` - 権限なし
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias FoodVault.{Inventories, Items, Repo, Warehouses}

  alias FoodVault.ShipmentOrders.{
    AllocationPlan,
    Request,
    ShipmentAllocation,
    ShipmentOrder,
    ShipmentOrderEvent,
    ShipmentOrderLine
  }

  alias FoodVault.Utils.Permission

  ## 参照

  @doc """
  出庫オーダーの一覧(ページング、出庫予定日の新しい順)。

  params: `"status"`・`"warehouse_id"`・`"shipment_date"`(ISO 日付)・
  `"origin"`(`"screen"` / `"external"`)。不正な値は無視する。
  """
  def list_shipment_orders(params \\ %{}) do
    ShipmentOrder
    |> filter_status(params["status"])
    |> filter_id(:warehouse_id, params["warehouse_id"])
    |> filter_shipment_date(params["shipment_date"])
    |> filter_origin(params["origin"])
    |> order_by([o], desc: o.shipment_date, desc: o.inserted_at, desc: o.id)
    |> preload(:warehouse)
    |> Repo.paginate(params)
  end

  @doc "出庫オーダーを取得する。倉庫・明細(商品・引当ロット)・履歴(操作ユーザー)を preload する。"
  def get_shipment_order!(id), do: Repo.get!(detail_query(), id)

  @doc """
  出庫オーダーを ID で取得する(`get_shipment_order!/1` と同じ preload)。

  ULID の形式でない ID・存在しない ID は `{:error, :not_found}`(例外にしない。在庫 API 用)。
  """
  def fetch_shipment_order(id) do
    with {:ok, id} <- Ecto.ULID.cast(id),
         %ShipmentOrder{} = order <- Repo.get(detail_query(), id) do
      {:ok, order}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  `external_slip_id` が一致するオーダーを新しい順に返す(`cancelled` を含む。在庫 API の照会用)。

  該当なしは `[]`。preload は `get_shipment_order!/1` と同じ。
  """
  def list_shipment_orders_by_slip(external_slip_id) when is_binary(external_slip_id) do
    detail_query()
    |> where([o], o.external_slip_id == ^external_slip_id)
    |> order_by([o], desc: o.inserted_at, desc: o.id)
    |> Repo.all()
  end

  defp detail_query do
    allocations =
      from(a in ShipmentAllocation, order_by: [asc: a.inserted_at, asc: a.id], preload: :lot)

    lines =
      from(l in ShipmentOrderLine,
        order_by: [asc: l.inserted_at, asc: l.id],
        preload: [:item, allocations: ^allocations]
      )

    events =
      from(e in ShipmentOrderEvent, order_by: [asc: e.inserted_at, asc: e.id], preload: :user)

    preload(ShipmentOrder, [:warehouse, lines: ^lines, events: ^events])
  end

  @doc "そのロットを引き当てている `allocated` のオーダー(出庫予定日順)。"
  def list_allocating_orders(lot_id) do
    query =
      from o in ShipmentOrder,
        join: l in assoc(o, :lines),
        join: a in assoc(l, :allocations),
        where: a.lot_id == ^lot_id and o.status == :allocated,
        order_by: [asc: o.shipment_date, asc: o.id],
        select: {o, l.item_id, a.allocated_cases, a.allocated_pieces},
        preload: :warehouse

    Repo.all(query)
  end

  defp filter_status(query, value) do
    case Enum.find(ShipmentOrder.statuses(), &(Atom.to_string(&1) == value)) do
      nil -> query
      status -> where(query, [o], o.status == ^status)
    end
  end

  defp filter_id(query, field, value) when is_binary(value) do
    case Ecto.ULID.cast(value) do
      {:ok, id} -> where(query, [o], field(o, ^field) == ^id)
      :error -> query
    end
  end

  defp filter_id(query, _field, _value), do: query

  defp filter_shipment_date(query, value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> where(query, [o], o.shipment_date == ^date)
      _ -> query
    end
  end

  defp filter_shipment_date(query, _), do: query

  defp filter_origin(query, "screen"), do: where(query, [o], is_nil(o.external_slip_id))
  defp filter_origin(query, "external"), do: where(query, [o], not is_nil(o.external_slip_id))
  defp filter_origin(query, _), do: query

  ## 引当

  @doc """
  出庫引当(自動引当)。

  `attrs`: `warehouse_id`・`shipment_date`・`lines`(各 `item_id`・`req_cases`・`req_pieces`・
  任意の `min_expiration_date`)・任意の `external_slip_id`。

  `external_slip_id` がある場合は冪等: 取消済み以外に同じ ID のオーダーがあれば、
  内容が一致すれば既存を返し(`replayed?: true`)、違えば `{:error, :idempotency_conflict, existing}`。
  同時の登録でユニーク制約に当たった側も、既存を再取得して同じ判定をする。

  1 つの明細でも在庫が足りなければ、荷崩しを含めて全体をロールバックする。
  """
  def allocate_shipment_order(actor, attrs) do
    with :ok <- Permission.authorize(actor, :manage_shipment_order),
         {:ok, request} <- Request.normalize(attrs),
         :none <- find_replay(request) do
      create_order(actor, request, true)
    else
      {:replay, result} -> result
      error -> error
    end
  end

  defp find_replay(%{external_slip_id: nil}), do: :none

  defp find_replay(%{external_slip_id: slip_id} = request) do
    case get_active_order_by_slip(slip_id) do
      nil -> :none
      order -> {:replay, replay_result(order, request)}
    end
  end

  defp replay_result(order, request) do
    if Request.same?(order, request) do
      {:ok, %{shipment_order: get_shipment_order!(order.id), replayed?: true}}
    else
      {:error, :idempotency_conflict, order}
    end
  end

  defp get_active_order_by_slip(slip_id) do
    ShipmentOrder
    |> where([o], o.external_slip_id == ^slip_id and o.status != :cancelled)
    |> preload(:lines)
    |> Repo.one()
  end

  defp create_order(actor, request, retry?) do
    actor
    |> allocation_multi(request)
    |> Repo.transact()
    |> case do
      {:ok, %{order: order}} ->
        {:ok, %{shipment_order: get_shipment_order!(order.id), replayed?: false}}

      {:error, :masters, {:validation, errors}, _} ->
        {:error, :validation_failed, errors}

      {:error, :plans, {:shortage, shortages}, _} ->
        {:error, :insufficient_stock, shortages}

      {:error, :order, %Ecto.Changeset{}, _} ->
        resolve_duplicate(actor, request, retry?)
    end
  end

  # 同時に同じ external_slip_id が登録された: 勝った側の既存オーダーと比べる。
  # 勝った側がその間に取消されていれば、一度だけやり直す
  defp resolve_duplicate(actor, request, retry?) do
    case find_replay(request) do
      {:replay, result} -> result
      :none when retry? -> create_order(actor, request, false)
      :none -> {:error, :idempotency_conflict, nil}
    end
  end

  defp allocation_multi(actor, request) do
    Multi.new()
    |> Multi.run(:masters, fn _repo, _ -> lock_masters(request) end)
    |> Multi.run(:lots, fn _repo, _ -> {:ok, lock_lots(request)} end)
    |> Multi.run(:plans, fn _repo, %{masters: masters, lots: lots} ->
      plan_lines(request, masters.items, lots)
    end)
    |> Multi.run(:order, fn _repo, _ -> insert_order(request) end)
    |> Multi.run(:lines, fn _repo, %{order: order, plans: plans} ->
      {:ok, Enum.map(plans, &insert_line(order, &1))}
    end)
    |> Multi.run(:lot_updates, fn _repo, %{order: order, lots: lots, plans: plans} ->
      apply_plans(actor, order, lots, plans)
    end)
    |> Multi.run(:event, fn _repo, %{order: order} ->
      insert_event(order.id, :created, actor, nil)
    end)
  end

  # 倉庫 → 商品(item_id 昇順)の順に FOR SHARE で読み、アーカイブ済み・存在しないものを検証エラーにする
  defp lock_masters(request) do
    warehouse = Warehouses.lock_active_warehouse_for_share(request.warehouse_id)
    items = request.lines |> Enum.map(& &1.item_id) |> Items.lock_active_items_for_share()
    items_by_id = Map.new(items, &{&1.id, &1})

    errors =
      warehouse_errors(warehouse) ++
        for line <- request.lines, not Map.has_key?(items_by_id, line.item_id) do
          %{path: ["lines", line.index, "item_id"], message: "は有効な商品を選択してください"}
        end

    if errors == [],
      do: {:ok, %{warehouse: warehouse, items: items_by_id}},
      else: {:error, {:validation, errors}}
  end

  defp warehouse_errors(nil), do: [%{path: ["warehouse_id"], message: "は有効な倉庫を選択してください"}]
  defp warehouse_errors(_), do: []

  defp lock_lots(request) do
    item_ids = Enum.map(request.lines, & &1.item_id)
    Inventories.lock_allocatable_lots(request.warehouse_id, item_ids, request.shipment_date)
  end

  # 明細ごとに先出し順のロットから引当計画を立てる。不足は全明細分を集める
  defp plan_lines(request, items, lots) do
    lots_by_item = Enum.group_by(lots, & &1.item_id)

    results =
      for line <- request.lines do
        candidates =
          lots_by_item
          |> Map.get(line.item_id, [])
          |> Enum.filter(&allocatable?(&1, request.shipment_date, line))

        units = Map.fetch!(items, line.item_id).units_per_case
        {line, AllocationPlan.plan_line(candidates, units, line.req_cases, line.req_pieces)}
      end

    case shortages(results) do
      [] -> {:ok, for({line, {:ok, plan}} <- results, do: %{line: line, plan: plan})}
      shortages -> {:error, {:shortage, shortages}}
    end
  end

  # 出庫可能期限: expiration_date >= GREATEST(出庫予定日, COALESCE(最低許容期限日, 出庫予定日))
  defp allocatable?(lot, shipment_date, line) do
    lower_bound = Enum.max([shipment_date, line.min_expiration_date || shipment_date], Date)
    Date.compare(lot.expiration_date, lower_bound) != :lt
  end

  defp shortages(results) do
    for {line, {:shortage, short}} <- results do
      %{item_id: line.item_id, shortage_cases: short.cases, shortage_pieces: short.pieces}
    end
  end

  defp insert_order(request) do
    %ShipmentOrder{}
    |> ShipmentOrder.create_changeset(%{
      warehouse_id: request.warehouse_id,
      shipment_date: request.shipment_date,
      external_slip_id: request.external_slip_id
    })
    |> Repo.insert()
  end

  defp insert_line(order, %{line: line, plan: plan}) do
    shipment_line =
      %ShipmentOrderLine{}
      |> ShipmentOrderLine.create_changeset(%{
        shipment_order_id: order.id,
        item_id: line.item_id,
        req_cases: line.req_cases,
        req_pieces: line.req_pieces,
        min_expiration_date: line.min_expiration_date
      })
      |> Repo.insert!()

    for allocation <- plan.allocations do
      %ShipmentAllocation{}
      |> ShipmentAllocation.create_changeset(%{
        shipment_order_line_id: shipment_line.id,
        lot_id: allocation.lot_id,
        allocated_cases: allocation.cases,
        allocated_pieces: allocation.pieces
      })
      |> Repo.insert!()
    end

    shipment_line
  end

  # 計画をロット(ロック済みの値)に適用し、荷崩しを受払履歴(auto_break)に 1 ロット 1 行で記録する
  defp apply_plans(actor, order, lots, plans) do
    lots_by_id = Map.new(lots, &{&1.id, &1})
    allocations = Enum.flat_map(plans, & &1.plan.allocations)
    breaks = Enum.flat_map(plans, & &1.plan.breaks)

    deltas =
      Map.merge(
        Enum.group_by(allocations, & &1.lot_id),
        Enum.group_by(breaks, & &1.lot_id),
        fn _lot_id, allocs, brks -> allocs ++ brks end
      )

    for {lot_id, _} <- deltas do
      lot = Map.fetch!(lots_by_id, lot_id)
      alloc = sum_for(allocations, lot_id)
      brk = sum_for(breaks, lot_id)

      :ok =
        Inventories.update_lot_quantities(lot_id,
          case_qty: lot.case_qty - brk.cases,
          piece_qty: lot.piece_qty + brk.pieces,
          allocated_case_qty: lot.allocated_case_qty + alloc.cases,
          allocated_piece_qty: lot.allocated_piece_qty + alloc.pieces
        )
    end

    for %{lot_id: lot_id, cases: cases, pieces: pieces} <- breaks do
      {:ok, _} =
        Inventories.record_transaction(actor, lot_id, :auto_break, -cases, pieces,
          shipment_order_id: order.id
        )
    end

    {:ok, :applied}
  end

  defp sum_for(entries, lot_id) do
    entries
    |> Enum.filter(&(&1.lot_id == lot_id))
    |> Enum.reduce(%{cases: 0, pieces: 0}, fn e, acc ->
      %{cases: acc.cases + e.cases, pieces: acc.pieces + e.pieces}
    end)
  end

  ## 出庫確定・引当解除

  @doc """
  出庫確定(`allocated` → `shipped`)。

  引当ロットを 1 クエリでロックし、現在庫と引当済数を引当分だけ減らす。
  受払履歴(`ship`、ロット単位)とオーダー履歴(`shipped`)を残す。すでに `shipped` なら
  何もせず `replayed?: true` で現状を返す。それ以外の状態は `{:error, :invalid_state}`。
  """
  def ship_shipment_order(actor, %ShipmentOrder{} = order), do: transition(actor, order, :ship)

  @doc """
  引当解除(`allocated` → `cancelled`)。

  引当済数だけを減らし(現在庫は変えない)、引当明細は削除せず残す。すでに `cancelled` なら
  `replayed?: true` で現状を返す。`opts` の `:reason` はオーダー履歴に残す(任意)。
  """
  def cancel_shipment_order(actor, %ShipmentOrder{} = order, opts \\ []),
    do: transition(actor, order, :cancel, opts)

  defp transition(actor, order, action, opts \\ []) do
    with :ok <- Permission.authorize(actor, :manage_shipment_order),
         :ok <- authorize_origin(actor, order) do
      Repo.transact(fn -> do_transition(actor, order.id, action, opts) end)
    end
  end

  # 発送システム起源のオーダーを画面から確定・解除するのは緊急操作(F-V8, P1)。未実装のため拒否する
  defp authorize_origin({:api, _operator}, _order), do: :ok

  defp authorize_origin(_user, order) do
    if ShipmentOrder.origin(order) == :screen, do: :ok, else: {:error, :forbidden}
  end

  defp do_transition(actor, order_id, action, opts) do
    order = lock_order(order_id)

    case check_state(order, action) do
      :proceed -> apply_transition(actor, order, action, opts)
      :replay -> {:ok, %{shipment_order: get_shipment_order!(order.id), replayed?: true}}
      :invalid -> {:error, :invalid_state}
    end
  end

  defp lock_order(id) do
    ShipmentOrder |> where([o], o.id == ^id) |> lock("FOR UPDATE") |> Repo.one!()
  end

  defp check_state(%{status: :allocated}, _action), do: :proceed
  defp check_state(%{status: :shipped}, :ship), do: :replay
  defp check_state(%{status: :cancelled}, :cancel), do: :replay
  defp check_state(_order, _action), do: :invalid

  defp apply_transition(actor, order, action, opts) do
    allocations = order_allocations(order.id)
    lots = allocations |> Enum.map(& &1.lot_id) |> Enum.uniq() |> Inventories.lock_lots_by_ids()
    lots_by_id = Map.new(lots, &{&1.id, &1})

    {changeset, event_type} = transition_changes(order, action)

    Enum.each(allocations, &apply_allocation(actor, order, lots_by_id, &1, action))

    {:ok, _} = Repo.update(changeset)
    {:ok, _} = insert_event(order.id, event_type, actor, opts[:reason])

    {:ok, %{shipment_order: get_shipment_order!(order.id), replayed?: false}}
  end

  defp transition_changes(order, :ship), do: {ShipmentOrder.ship_changeset(order), :shipped}
  defp transition_changes(order, :cancel), do: {ShipmentOrder.cancel_changeset(order), :cancelled}

  defp order_allocations(order_id) do
    query =
      from a in ShipmentAllocation,
        join: l in assoc(a, :shipment_order_line),
        where: l.shipment_order_id == ^order_id

    Repo.all(query)
  end

  defp apply_allocation(actor, order, lots_by_id, allocation, :ship) do
    lot = Map.fetch!(lots_by_id, allocation.lot_id)

    # 同じオーダー内でロットが重複することはない(明細ごとに商品が異なる)ので、ロット単位で差し引く
    :ok =
      Inventories.update_lot_quantities(lot.id,
        case_qty: lot.case_qty - allocation.allocated_cases,
        piece_qty: lot.piece_qty - allocation.allocated_pieces,
        allocated_case_qty: lot.allocated_case_qty - allocation.allocated_cases,
        allocated_piece_qty: lot.allocated_piece_qty - allocation.allocated_pieces
      )

    {:ok, _} =
      Inventories.record_transaction(
        actor,
        lot.id,
        :ship,
        -allocation.allocated_cases,
        -allocation.allocated_pieces,
        shipment_order_id: order.id
      )
  end

  defp apply_allocation(_actor, _order, lots_by_id, allocation, :cancel) do
    lot = Map.fetch!(lots_by_id, allocation.lot_id)

    :ok =
      Inventories.update_lot_quantities(lot.id,
        allocated_case_qty: lot.allocated_case_qty - allocation.allocated_cases,
        allocated_piece_qty: lot.allocated_piece_qty - allocation.allocated_pieces
      )
  end

  defp insert_event(order_id, type, actor, reason) do
    %{shipment_order_id: order_id, event_type: type, reason: reason}
    |> Map.merge(Inventories.actor_fields(actor))
    |> ShipmentOrderEvent.insert_changeset()
    |> Repo.insert()
  end
end
