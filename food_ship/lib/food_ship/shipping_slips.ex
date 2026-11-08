defmodule FoodShip.ShippingSlips do
  @moduledoc """
  出荷伝票(登録・引当・再引当・数量変更)。

  書き込み関数は先頭引数に `FoodShip.Accounts.Scope` を取り、権限が無ければ
  `{:error, :forbidden}` を返す(Web 層の検査との二重化)。操作者(`operator`)は
  `scope.user.email` で、在庫 API に渡す。

  ## 在庫 API とトランザクション

  在庫側の状態はローカル DB のトランザクションでロールバックできないため、**在庫 API の呼び出しは
  トランザクションの外**で行う。手順は「先に `pending` で保存 → API → 結果で更新」。

  同じ伝票の同時操作は、API を呼ぶ前の短いトランザクションで伝票を `FOR UPDATE` で読んで
  `allocation_attempted_at`(マイクロ秒)を更新して「確保」し、結果の反映は確保時の
  `status` と `allocation_attempted_at` が変わっていない行にだけ行う。変わっていたら
  `{:error, :stale}`(別の操作が先に進んでいる)。

  `external_slip_id` は伝票の `id`(ULID)。再引当・数量変更でも同じ値を使い、在庫側の
  `cancelled` 以外の同一 ID だけが冪等判定されるため、「解除 → 同じ ID で再引当」ができる。
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias FoodShip.Clients.Client
  alias FoodShip.ExpirationRules
  alias FoodShip.Inventory.Client, as: InventoryClient
  alias FoodShip.Repo
  alias FoodShip.ShippingItems.ShippingItem
  alias FoodShip.ShippingSlips.{AllocationResult, ShippingSlip, SlipAllocatedLot}
  alias FoodShip.Utils.{Calc, Permission}

  @unpacked [:pending, :allocated, :shortage]

  ## 参照

  @doc "伝票を取得する(発注元・発送商品・引当ロットを preload 済み)。"
  def get_shipping_slip!(id) do
    ShippingSlip |> Repo.get!(id) |> preload_slip()
  end

  @doc """
  出荷予定日の伝票(`slip_no` 昇順。発注元・発送商品・引当ロットを preload 済み)。

  `filter`: `:all`(すべて)・`:unpacked`(梱包前 = `pending` / `allocated` / `shortage`)・
  `:shortage`(在庫不足のみ)。
  """
  def list_shipping_slips(%Date{} = date, filter \\ :all) do
    ShippingSlip
    |> where([s], s.scheduled_ship_date == ^date)
    |> filter_status(filter)
    |> order_by([s], asc: s.slip_no)
    |> Repo.all()
    |> preload_slip()
  end

  @doc """
  `from_date` 以降の出荷予定日ごとの残件数(`pending` / `allocated` / `shortage` の合計)。

  取消済み以外の伝票が 1 件でもある日付だけを、日付順に返す。作業画面のタブに使う。
  """
  def summarize_ship_dates(%Date{} = from_date) do
    ShippingSlip
    |> where([s], s.scheduled_ship_date >= ^from_date and s.status != :cancelled)
    |> group_by([s], s.scheduled_ship_date)
    |> order_by([s], asc: s.scheduled_ship_date)
    |> select([s], %{
      date: s.scheduled_ship_date,
      remaining: filter(count(s.id), s.status in ^@unpacked)
    })
    |> Repo.all()
  end

  @doc "出荷予定日に梱包完了の伝票があるか。あれば、未梱包の伝票は追加伝票としてハイライトする。"
  def any_packed?(%Date{} = date) do
    Repo.exists?(
      from s in ShippingSlip, where: s.scheduled_ship_date == ^date and s.status == :packed
    )
  end

  defp filter_status(query, :all), do: query
  defp filter_status(query, :unpacked), do: where(query, [s], s.status in ^@unpacked)
  defp filter_status(query, :shortage), do: where(query, [s], s.status == :shortage)

  @doc """
  対象倉庫(在庫側のデフォルト倉庫)が設定されているか。未設定の間は登録・再引当・数量変更を受け付けない。

  画面の表示のたびに呼ぶので、在庫 API はリトライなしで呼ぶ。通信に失敗したときは、未設定とは
  断定できないので `true`(警告を出さない)。操作の側で通信エラーが表示される。
  """
  def warehouse_configured? do
    InventoryClient.default_warehouse_id(retry: false) != {:error, :warehouse_not_configured}
  end

  @doc "フォーム用の changeset。登録(`id` なし)は計算値を入れて検証する。"
  def change_shipping_slip(slip, attrs \\ %{})

  def change_shipping_slip(%ShippingSlip{id: nil} = slip, attrs) do
    {attrs, _client, _item} = build_attrs(attrs)
    ShippingSlip.create_changeset(slip, attrs)
  end

  def change_shipping_slip(%ShippingSlip{} = slip, attrs) do
    {attrs, _item} = build_update_attrs(slip, attrs)
    ShippingSlip.update_changeset(slip, attrs)
  end

  @doc """
  画面のリアルタイム表示用の計算結果。入力が足りない項目は `nil`。

  `params` はフォームの値(文字列キー): `client_id`・`shipping_item_id`・`scheduled_ship_date`・
  `order_count`。`min_remaining_days` は適用される出荷期限ルール(無ければ `nil` = 制限なし)。
  """
  def preview(params) do
    params = stringify(params)
    item = fetch(ShippingItem, params["shipping_item_id"])
    count = parse_count(params["order_count"])
    date = parse_date(params["scheduled_ship_date"])
    client_id = cast_id(params["client_id"])
    rule = item && client_id && ExpirationRules.get_rule(client_id, item.id)

    Map.merge(
      %{
        total_piece_qty: nil,
        default_box_count: nil,
        min_remaining_days: rule && rule.min_remaining_days,
        min_expiration_date:
          rule && date && Calc.min_expiration_date(date, rule.min_remaining_days)
      },
      quantities(item, count)
    )
  end

  defp quantities(%ShippingItem{} = item, count) when is_integer(count) do
    %{
      total_piece_qty: Calc.total_piece_qty(count, item.pieces_per_order),
      default_box_count: Calc.default_box_count(count, item.boxes_per_order)
    }
  end

  defp quantities(_item, _count), do: %{}

  ## 登録

  @doc """
  伝票を `pending` で登録する(在庫 API は呼ばない。続けて `allocate_shipping_slip/2` を呼ぶ)。

  `attrs`: `client_id`・`shipping_item_id`・`scheduled_ship_date`・`order_count`・
  `client_slip_no`(任意)・`box_count`(任意。省略時は件数 × 標準箱数)。出庫総数量・最低許容期限日は
  マスタから計算する。発注元・発送商品がアーカイブ済みなら changeset エラー。
  デフォルト倉庫が未設定(`{:error, :warehouse_not_configured}`)・在庫 API に接続できない
  (`{:error, :connection}` など)のときは保存しない。
  """
  def create_shipping_slip(scope, attrs) do
    with :ok <- authorize(scope, :manage_shipping_slips),
         {:ok, _warehouse_id} <- ensure_warehouse() do
      {attrs, client, item} = build_attrs(attrs)

      attrs = Map.put(attrs, "created_by_user_id", scope.user.id)

      %ShippingSlip{}
      |> ShippingSlip.create_changeset(attrs)
      |> validate_master(:client_id, client)
      |> validate_master(:shipping_item_id, item)
      |> Repo.insert()
      |> case do
        {:ok, slip} -> {:ok, preload_slip(slip)}
        {:error, changeset} -> {:error, changeset}
      end
    end
  end

  @doc """
  件数・出荷予定日(・箱数)を変更し、`pending` に戻す。`pending` / `allocated` / `shortage` のみ。

  数量・最低許容期限日は現在のマスタで再計算する。**旧オーダー(`inventory_order_id`・引当ロット)は
  残す**。呼び出し側は続けて `allocate_shipping_slip/2` を実行する(旧オーダーの照会・解除 → 再引当)。
  """
  def update_shipping_slip(scope, %ShippingSlip{id: id}, attrs) do
    with :ok <- authorize(scope, :manage_shipping_slips),
         {:ok, _warehouse_id} <- ensure_warehouse() do
      Repo.transact(fn -> update_unpacked(lock_slip(id), attrs) end)
    end
  end

  defp update_unpacked(%ShippingSlip{status: status} = slip, attrs) when status in @unpacked do
    {attrs, _item} = build_update_attrs(slip, attrs)

    case slip |> ShippingSlip.update_changeset(attrs) |> Repo.update() do
      {:ok, slip} -> {:ok, preload_slip(slip)}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp update_unpacked(_slip, _attrs), do: {:error, :invalid_status}

  ## 引当・再引当

  @doc """
  引当・再引当(functional-design §6.2)。`pending` / `shortage` のみ。

  1. 伝票を確保し、最低許容期限日を現在のルールで再計算する
  2. 過去に API を呼んでいた(`allocation_attempted_at` か `inventory_order_id` がある)場合は、
     在庫側を `external_slip_id` で照会し、引当済みのオーダーを解除してローカルの引当を消す
     (在庫側が出庫済みなら、再引当せずに `packed` へ突合する)
  3. 在庫側へ引当を要求し、応答の引当合計を検証して結果を反映する

  戻り値は `{:ok, slip, info}`(`slip.status` は `allocated` / `shortage` / `pending` /
  突合した `packed`。`info.errors` は 422 `validation_failed` の内容)、または
  `{:error, :invalid_status | :stale | :forbidden | :warehouse_not_configured}`。

  引当先は、在庫側のデフォルト倉庫(呼び出しのたびに取得する)。取得に失敗したとき
  (`{:error, :connection | :unauthorized}`)は、伝票の状態を変えずにエラーを返す。
  """
  def allocate_shipping_slip(scope, %ShippingSlip{id: id}) do
    with :ok <- authorize(scope, :manage_shipping_slips),
         {:ok, warehouse_id} <- ensure_warehouse(),
         {:ok, {slip, remote?}} <- claim(id, [:pending, :shortage], &recompute_expiration/1) do
      operator = scope.user.email

      with {:ok, slip} <- release_for_allocation(scope, slip, remote?, operator) do
        allocate_remote(slip, warehouse_id, operator)
      end
    end
  end

  # 旧オーダーを解除する。続けて引当できるときだけ `{:ok, slip}` を返す。
  # 突合した(出庫済み)・解除に失敗したときは `{:ok, slip, info}` で終わり、`allocate_shipping_slip/2`
  # の呼び出し元へそのまま返る(解除に失敗したら `pending` ＋引当エラー)
  defp release_for_allocation(_scope, slip, false, _operator), do: {:ok, slip}

  defp release_for_allocation(scope, slip, true, operator) do
    case release_remote_orders(slip, operator, "再引当のため") do
      :ok ->
        clear_local_order(slip)

      {:shipped, order} ->
        with {:ok, slip} <-
               mark_packed(
                 scope,
                 slip,
                 order,
                 {:replace, AllocationResult.lots_from_order(order)}
               ) do
          {:ok, slip, %{reconciled: true}}
        end

      {:error, reason} ->
        with {:ok, slip} <- fail_pending(slip, AllocationResult.error_for(reason)) do
          {:ok, slip, %{}}
        end
    end
  end

  defp allocate_remote(slip, warehouse_id, operator) do
    params = %{
      warehouse_id: warehouse_id,
      shipment_date: slip.scheduled_ship_date,
      external_slip_id: slip.id,
      operator: operator,
      lines: [
        %{
          item_id: slip.shipping_item.inventory_item_id,
          req_cases: 0,
          req_pieces: slip.total_piece_qty,
          min_expiration_date: slip.min_expiration_date
        }
      ]
    }

    result = InventoryClient.allocate(params)

    case AllocationResult.from_response(slip, result) do
      {:allocated, order_id, lots} ->
        attrs = %{
          status: :allocated,
          inventory_order_id: order_id,
          shortage_pieces: nil,
          allocation_error: nil
        }

        with {:ok, slip} <- apply_outcome(slip, attrs, {:replace, lots}), do: {:ok, slip, %{}}

      {:shortage, pieces} ->
        attrs = %{
          status: :shortage,
          inventory_order_id: nil,
          shortage_pieces: pieces,
          allocation_error: nil
        }

        with {:ok, slip} <- apply_outcome(slip, attrs, {:replace, []}), do: {:ok, slip, %{}}

      {:pending, error, extra} ->
        attrs =
          %{status: :pending, shortage_pieces: nil, allocation_error: error}
          |> maybe_put(:inventory_order_id, extra[:order_id])

        with {:ok, slip} <- apply_outcome(slip, attrs, :keep),
             do: {:ok, slip, Map.take(extra, [:errors])}
    end
  end

  ## 梱包完了・箱数

  @doc """
  梱包完了(functional-design §6.4)。`allocated` のみ。在庫側の出庫確定 API を呼び、成功したら
  `packed`・`packed_at`・`packed_by_user_id` を保存する(在庫側の `shipped_at` を `packed_at` にする)。

    * 409 `invalid_state` は在庫側を照会し、すでに `shipped` なら発送側も `packed` に更新する。
      それ以外は `{:error, {:remote_state, status}}`
    * 在庫側が停止している間は `{:error, :connection}` で `allocated` のまま(復旧後にやり直す。
      在庫側は冪等)
    * 他の操作で状態が変わっていたら `{:error, :stale}`
  """
  def pack_shipping_slip(scope, %ShippingSlip{id: id}) do
    with :ok <- authorize(scope, :pack_shipping_slips) do
      slip = ShippingSlip |> Repo.get!(id) |> preload_slip()

      if slip.status == :allocated and not is_nil(slip.inventory_order_id) do
        ship_remote(scope, slip)
      else
        {:error, :invalid_status}
      end
    end
  end

  defp ship_remote(scope, slip) do
    case InventoryClient.ship_order(slip.inventory_order_id, scope.user.email) do
      {:ok, order} -> mark_packed(scope, slip, order, :keep)
      {:error, :invalid_state} -> reconcile_shipped(scope, slip)
      {:error, reason} -> {:error, reason}
    end
  end

  # 409 のとき、在庫側を照会する。出庫済みなら発送側も梱包完了にし、それ以外は最新の状態を返す
  defp reconcile_shipped(scope, slip) do
    case InventoryClient.get_order(slip.inventory_order_id) do
      {:ok, %{status: :shipped} = order} -> mark_packed(scope, slip, order, :keep)
      {:ok, order} -> {:error, {:remote_state, order.status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  箱数の修正(在庫には影響しない)。1 以上の整数。梱包前(`pending` / `allocated` / `shortage`)のみ。
  """
  def update_box_count(scope, %ShippingSlip{id: id}, box_count) do
    with :ok <- authorize(scope, :pack_shipping_slips) do
      Repo.transact(fn -> update_box_count_unpacked(lock_slip(id), box_count) end)
    end
  end

  defp update_box_count_unpacked(%ShippingSlip{status: status} = slip, box_count)
       when status in @unpacked do
    case slip |> ShippingSlip.box_count_changeset(%{"box_count" => box_count}) |> Repo.update() do
      {:ok, slip} -> {:ok, preload_slip(slip)}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp update_box_count_unpacked(_slip, _box_count), do: {:error, :invalid_status}

  ## 取消

  @doc """
  梱包前の取消(functional-design §6.6)。`pending` / `shortage` / `allocated` のみ。

  過去に在庫 API を呼んでいた(または在庫側にオーダーがある)場合は、在庫側を照会して引当済みの
  オーダーを解除してから `cancelled`(`cancelled_at`・`cancelled_by_user_id`)にする。
  解除に失敗したらローカルは変えず `{:error, reason}`(再度取消できる)。在庫側が出庫済みなら
  `{:error, {:remote_state, :shipped}}`(梱包完了で状態を合わせる)。
  """
  def cancel_shipping_slip(scope, %ShippingSlip{id: id}) do
    with :ok <- authorize(scope, :manage_shipping_slips),
         {:ok, {slip, remote?}} <- claim(id, @unpacked, fn _slip -> %{} end),
         :ok <- release_for_cancel(slip, remote?, scope.user.email) do
      attrs = %{
        status: :cancelled,
        cancelled_at: DateTime.utc_now(:second),
        cancelled_by_user_id: scope.user.id,
        inventory_order_id: nil,
        shortage_pieces: nil,
        allocation_error: nil
      }

      apply_outcome(slip, attrs, {:replace, []})
    end
  end

  defp release_for_cancel(_slip, false, _operator), do: :ok

  defp release_for_cancel(slip, true, operator) do
    case release_remote_orders(slip, operator, "発送システムで伝票を取り消したため") do
      :ok -> :ok
      {:shipped, _order} -> {:error, {:remote_state, :shipped}}
      {:error, reason} -> {:error, reason}
    end
  end

  ## 在庫側のオーダーの解除(再引当・取消で共通)

  # `external_slip_id` で照会し、引当済みのオーダーを解除する。
  #   :ok                  - 在庫側に引当済みのオーダーが無い(解除した・元から無い)
  #   {:shipped, order}    - 在庫側が出庫済み(引当・取消はできない。突合が必要)
  #   {:error, reason}     - 照会・解除に失敗(`Inventory.Client` のエラー、または
  #                          `{:remote_state, :reversed}`)
  defp release_remote_orders(slip, operator, reason) do
    with {:ok, orders} <- InventoryClient.list_orders_by_slip(slip.id) do
      orders = Enum.reject(orders, &(&1.status == :cancelled))

      cond do
        order = Enum.find(orders, &(&1.status == :shipped)) -> {:shipped, order}
        Enum.any?(orders, &(&1.status == :reversed)) -> {:error, {:remote_state, :reversed}}
        true -> cancel_orders(orders, operator, reason)
      end
    end
  end

  defp cancel_orders(orders, operator, reason) do
    Enum.reduce_while(orders, :ok, fn order, :ok ->
      case InventoryClient.cancel_order(order.order_id, operator, reason) do
        {:ok, _order} -> {:cont, :ok}
        # すでに無いなら解除済みと同じ
        {:error, :not_found} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # 解除に成功したら、旧オーダーの ID と引当ロットをローカルから消す(1 トランザクション)
  defp clear_local_order(slip),
    do: apply_outcome(slip, %{inventory_order_id: nil}, {:replace, []})

  defp fail_pending(slip, error) do
    apply_outcome(slip, %{status: :pending, shortage_pieces: nil, allocation_error: error}, :keep)
  end

  # 在庫側が出庫済みなので、発送側も `packed` に合わせる。梱包者は操作したユーザー。
  # `lots` は引当ロットの扱い(`:keep` か `{:replace, lots}`)
  defp mark_packed(scope, slip, order, lots) do
    attrs = %{
      status: :packed,
      inventory_order_id: order.order_id,
      shortage_pieces: nil,
      allocation_error: nil,
      packed_at: order.shipped_at || DateTime.utc_now(:second),
      packed_by_user_id: scope.user.id
    }

    apply_outcome(slip, attrs, lots)
  end

  ## 確保と結果の反映

  # API を呼ぶ前に、伝票を `FOR UPDATE` で読んで状態を検査し、`allocation_attempted_at` を
  # 現在時刻にして確保する。戻り値の `remote?` は「在庫側にオーダーが残っている可能性」
  # (過去に API を呼んだ、または `inventory_order_id` がある)。
  defp claim(id, allowed_statuses, extra_fun) do
    Repo.transact(fn ->
      slip = lock_slip(id)

      if slip.status in allowed_statuses do
        remote? = not is_nil(slip.allocation_attempted_at) or not is_nil(slip.inventory_order_id)

        changes =
          slip
          |> extra_fun.()
          |> Map.put(:allocation_attempted_at, DateTime.utc_now())

        {:ok, claimed} = slip |> Ecto.Changeset.change(changes) |> Repo.update()
        {:ok, {preload_slip(claimed), remote?}}
      else
        {:error, :invalid_status}
      end
    end)
  end

  defp recompute_expiration(slip) do
    rule = ExpirationRules.get_rule(slip.client_id, slip.shipping_item_id)

    %{
      min_expiration_date:
        Calc.min_expiration_date(slip.scheduled_ship_date, rule && rule.min_remaining_days),
      allocation_error: nil
    }
  end

  # 確保した時点(`status`・`allocation_attempted_at`)のままの行にだけ `attrs` を反映する。
  # `lots` は `:keep`(引当ロットを変えない)か `{:replace, lots}`(旧行を削除して新行を保存)。
  defp apply_outcome(%ShippingSlip{} = slip, attrs, lots) do
    attrs = Map.put(attrs, :updated_at, DateTime.utc_now(:second))

    multi =
      Multi.new()
      |> Multi.run("update_slip", fn repo, _changes ->
        {count, _} =
          ShippingSlip
          |> where([s], s.id == ^slip.id and s.status == ^slip.status)
          |> where_attempted_at(slip.allocation_attempted_at)
          |> repo.update_all(set: Map.to_list(attrs))

        if count == 1, do: {:ok, count}, else: {:error, :stale}
      end)
      |> replace_lots(slip, lots)

    case Repo.transact(multi) do
      {:ok, _changes} -> {:ok, slip.id |> then(&Repo.get!(ShippingSlip, &1)) |> preload_slip()}
      {:error, "update_slip", :stale, _changes} -> {:error, :stale}
    end
  end

  defp where_attempted_at(query, nil), do: where(query, [s], is_nil(s.allocation_attempted_at))
  defp where_attempted_at(query, at), do: where(query, [s], s.allocation_attempted_at == ^at)

  defp replace_lots(multi, _slip, :keep), do: multi

  defp replace_lots(multi, slip, {:replace, lots}) do
    multi =
      Multi.delete_all(
        multi,
        "delete_lots",
        from(l in SlipAllocatedLot, where: l.shipping_slip_id == ^slip.id)
      )

    lots
    |> Enum.with_index()
    |> Enum.reduce(multi, fn {lot, index}, multi ->
      Multi.insert(multi, "insert_lot_#{index}", %SlipAllocatedLot{
        shipping_slip_id: slip.id,
        inventory_lot_id: lot.inventory_lot_id,
        expiration_date: lot.expiration_date,
        allocated_pieces: lot.allocated_pieces
      })
    end)
  end

  ## 入力の組み立て(マスタからの計算)

  # 登録: 出庫総数量・箱数の初期値・最低許容期限日をマスタ(発送商品・出荷期限ルール)から計算する
  defp build_attrs(attrs) do
    attrs = stringify(attrs)
    client = fetch(Client, attrs["client_id"])
    item = fetch(ShippingItem, attrs["shipping_item_id"])
    count = parse_count(attrs["order_count"])
    date = parse_date(attrs["scheduled_ship_date"])
    rule = item && client && ExpirationRules.get_rule(client.id, item.id)

    computed =
      %{}
      |> put_computed(
        "total_piece_qty",
        item && count && Calc.total_piece_qty(count, item.pieces_per_order)
      )
      |> put_computed(
        "min_expiration_date",
        rule && date && Calc.min_expiration_date(date, rule.min_remaining_days)
      )

    attrs =
      attrs
      |> Map.merge(computed)
      |> Map.put("input_source", "manual")
      |> put_box_count(item && count && Calc.default_box_count(count, item.boxes_per_order))

    {attrs, client, item}
  end

  # 変更: 現在のマスタで再計算する(登録済みの伝票の商品・発注元は変えない)
  defp build_update_attrs(slip, attrs) do
    attrs = stringify(attrs)
    slip = Repo.preload(slip, :shipping_item)
    item = slip.shipping_item
    count = parse_count(attrs["order_count"])
    date = parse_date(attrs["scheduled_ship_date"])
    rule = ExpirationRules.get_rule(slip.client_id, slip.shipping_item_id)

    computed =
      %{}
      |> put_computed(
        "total_piece_qty",
        count && Calc.total_piece_qty(count, item.pieces_per_order)
      )
      |> put_computed(
        "min_expiration_date",
        rule && date && Calc.min_expiration_date(date, rule.min_remaining_days)
      )

    attrs =
      attrs
      |> Map.merge(computed)
      |> Map.put("min_expiration_date", computed["min_expiration_date"])
      |> put_box_count(count && Calc.default_box_count(count, item.boxes_per_order))

    {attrs, item}
  end

  defp put_computed(map, _key, nil), do: map
  defp put_computed(map, key, value), do: Map.put(map, key, value)

  # 箱数が空(未入力)のときだけ初期値を入れる(手修正は尊重する)
  defp put_box_count(attrs, default) do
    case attrs["box_count"] do
      value when value in [nil, ""] ->
        if default, do: Map.put(attrs, "box_count", default), else: attrs

      _ ->
        attrs
    end
  end

  # 存在しない・アーカイブ済みの発注元・発送商品は選べない
  defp validate_master(changeset, field, master) do
    cond do
      Keyword.has_key?(changeset.errors, field) -> changeset
      match?(%{archived_at: nil}, master) -> changeset
      true -> Ecto.Changeset.add_error(changeset, field, "は選べません。")
    end
  end

  ## 共通

  defp lock_slip(id) do
    ShippingSlip |> where([s], s.id == ^id) |> lock("FOR UPDATE") |> Repo.one!()
  end

  defp preload_slip(slip) do
    lots = from(l in SlipAllocatedLot, order_by: [asc: l.expiration_date, asc: l.id])
    Repo.preload(slip, [:client, :shipping_item, allocated_lots: lots], force: true)
  end

  # 在庫側のデフォルト倉庫の ID。`{:ok, id}` か、`{:error, :warehouse_not_configured | :connection | ...}`
  defp ensure_warehouse, do: InventoryClient.default_warehouse_id()

  defp authorize(scope, action), do: Permission.authorize(scope.user, action)

  defp fetch(schema, id) do
    case cast_id(id) do
      nil -> nil
      id -> Repo.get(schema, id)
    end
  end

  defp cast_id(value) do
    case Ecto.Type.cast(Ecto.ULID, value) do
      {:ok, id} when not is_nil(id) -> id
      _ -> nil
    end
  end

  defp parse_count(value) when is_integer(value) and value > 0, do: value

  defp parse_count(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {count, ""} when count > 0 -> count
      _ -> nil
    end
  end

  defp parse_count(_value), do: nil

  defp parse_date(%Date{} = date), do: date

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parse_date(_value), do: nil

  defp stringify(attrs), do: Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
