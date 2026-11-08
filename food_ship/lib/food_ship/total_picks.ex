defmodule FoodShip.TotalPicks do
  @moduledoc """
  トータルピック(作成・再発行・取消・集計)。

  同じ「出荷予定日 × 発注元 × メーカー」の未ピックの引当済み伝票(`allocated` かつ
  `total_pick_id` が NULL)を束ねる。書き込み関数は先頭引数に `FoodShip.Accounts.Scope` を取り、
  権限が無ければ `{:error, :forbidden}` を返す(Web 層の検査との二重化)。

  ## ロック順序

  デッドロックを避けるため、常に**伝票 → ピック**の順でロックする。

    * 作成: 対象の伝票を `FOR UPDATE` → ピックを挿入
    * 再発行・取消: 紐づく伝票を `FOR UPDATE` → ピックを `FOR UPDATE`
    * `release/2`: 呼び出し側(`FoodShip.ShippingSlips`)がすでに伝票をロックしているので、
      そのあとでピックを `FOR UPDATE`

  ピック明細(商品 × 期限日の合算)は持たず、紐づく伝票の引当ロット明細から都度集計する。
  `FoodShip.ShippingSlips` はこのモジュールを呼ぶが、逆は呼ばない。
  """

  import Ecto.Query, warn: false

  alias FoodShip.Repo
  alias FoodShip.ShippingItems.ShippingItem
  alias FoodShip.ShippingSlips.{ShippingSlip, SlipAllocatedLot}
  alias FoodShip.TotalPicks.TotalPick
  alias FoodShip.Utils.Permission

  @filter_keys [:scheduled_ship_date, :client_id, :inventory_maker_id, :status]

  ## 参照

  @doc """
  ピックを取得する(発注元・発行者・紐づく伝票を preload 済み)。

  伝票は `slip_no` 昇順で、発送商品・引当ロット(期限日昇順)付き。
  """
  def get_total_pick!(id) do
    TotalPick |> Repo.get!(id) |> preload_pick()
  end

  @doc """
  ピックの一覧(`scheduled_ship_date` 降順、`pick_no` 降順)。ページ送りあり。

  `filters`: `:scheduled_ship_date`・`:client_id`・`:inventory_maker_id`・`:status`
  (指定しないキー・`nil` は絞り込まない)。各ピックの `slip_count` に紐づく伝票数が入る。
  """
  def list_total_picks(filters \\ %{}, page \\ 1) do
    filters = Map.take(filters, @filter_keys)

    slip_count =
      from s in ShippingSlip,
        where: s.total_pick_id == parent_as(:pick).id,
        select: count(s.id)

    query =
      from p in TotalPick,
        as: :pick,
        order_by: [desc: p.scheduled_ship_date, desc: p.pick_no],
        preload: [:client],
        select_merge: %{slip_count: subquery(slip_count)}

    query
    |> filter_picks(filters)
    |> Repo.paginate(page: page)
  end

  defp filter_picks(query, filters) do
    Enum.reduce(filters, query, fn
      {_key, nil}, query -> query
      {:scheduled_ship_date, date}, query -> where(query, [p], p.scheduled_ship_date == ^date)
      {:client_id, id}, query -> where(query, [p], p.client_id == ^id)
      {:inventory_maker_id, id}, query -> where(query, [p], p.inventory_maker_id == ^id)
      {:status, status}, query -> where(query, [p], p.status == ^status)
    end)
  end

  @doc """
  ピックを作成済みのメーカー(絞り込みの選択肢)。メーカー名は最新のピックの値。
  """
  def list_makers do
    from(p in TotalPick,
      group_by: p.inventory_maker_id,
      select: %{inventory_maker_id: p.inventory_maker_id, maker_name: max(p.maker_name)},
      order_by: [asc: max(p.maker_name)]
    )
    |> Repo.all()
  end

  @doc """
  トータルピック作成のプレビュー。出荷予定日の未ピックの引当済み伝票を、
  「発注元 × メーカー」のグループに分けて返す。

  各グループ: `client_id`・`client_code`・`client_name`・`inventory_maker_id`・`maker_name`・
  `slip_count`(伝票数)・`item_count`(商品の種類数)・`total_pieces`(合計バラ数)。
  """
  def list_candidates(%Date{} = date) do
    from(s in ShippingSlip,
      join: i in assoc(s, :shipping_item),
      join: c in assoc(s, :client),
      where:
        s.scheduled_ship_date == ^date and s.status == :allocated and is_nil(s.total_pick_id),
      group_by: [s.client_id, i.inventory_maker_id],
      order_by: [asc: min(c.client_code), asc: min(i.maker_name)],
      select: %{
        client_id: s.client_id,
        client_code: min(c.client_code),
        client_name: min(c.client_name),
        inventory_maker_id: i.inventory_maker_id,
        maker_name: min(i.maker_name),
        slip_count: count(s.id),
        item_count: count(s.shipping_item_id, :distinct),
        total_pieces: sum(s.total_piece_qty)
      }
    )
    |> Repo.all()
    |> Enum.map(&Map.update!(&1, :total_pieces, fn pieces -> pieces |> to_integer() end))
  end

  ## 作成

  @doc """
  選んだグループごとにトータルピックを作る(1 トランザクション)。

  `groups` は `[{client_id, inventory_maker_id}]`。グループごとに、出荷予定日の未ピックの
  `allocated` 伝票を `FOR UPDATE` で確保してピックに紐づける。同じ伝票に対する同時の作成は、
  後続が対象 0 件になって失敗する(二重ピックにならない)。

  どれかのグループの対象が 0 件(プレビューのあとに他の操作で変わった)なら、**全体を
  ロールバック**して `{:error, :no_target}`。`groups` が空なら `{:error, :empty_selection}`。
  """
  def create_total_picks(scope, %Date{} = date, groups) when is_list(groups) do
    with :ok <- authorize(scope),
         :ok <- ensure_selection(groups) do
      groups = groups |> Enum.uniq() |> Enum.sort()
      Repo.transact(fn -> create_all(scope, date, groups) end)
    end
  end

  # グループごとに作る。どれかが失敗したら `{:error, reason}`(呼び出し側の transact がロールバックする)
  defp create_all(scope, date, groups) do
    result =
      Enum.reduce_while(groups, {:ok, []}, fn group, {:ok, picks} ->
        case create_one(scope, date, group) do
          {:ok, pick} -> {:cont, {:ok, [pick | picks]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    with {:ok, picks} <- result, do: {:ok, Enum.reverse(picks)}
  end

  defp ensure_selection([]), do: {:error, :empty_selection}
  defp ensure_selection(_groups), do: :ok

  defp create_one(scope, date, {client_id, maker_id}) do
    item_ids = from(i in ShippingItem, where: i.inventory_maker_id == ^maker_id, select: i.id)

    slips =
      from(s in ShippingSlip,
        where:
          s.scheduled_ship_date == ^date and s.client_id == ^client_id and
            s.status == :allocated and is_nil(s.total_pick_id) and
            s.shipping_item_id in subquery(item_ids),
        order_by: [asc: s.id],
        lock: "FOR UPDATE"
      )
      |> Repo.all()
      |> Repo.preload(:shipping_item)

    case slips do
      [] ->
        {:error, :no_target}

      [first | _] ->
        {:ok, pick} =
          %TotalPick{}
          |> TotalPick.create_changeset(%{
            scheduled_ship_date: date,
            client_id: client_id,
            inventory_maker_id: maker_id,
            maker_name: first.shipping_item.maker_name,
            issued_at: DateTime.utc_now(:second),
            issued_by_user_id: scope.user.id
          })
          |> Repo.insert()

        ids = Enum.map(slips, & &1.id)

        from(s in ShippingSlip, where: s.id in ^ids)
        |> Repo.update_all(set: [total_pick_id: pick.id, updated_at: DateTime.utc_now(:second)])

        {:ok, pick}
    end
  end

  ## 再発行・取消

  @doc """
  再発行。`outdated` で、紐づく伝票が 1 件以上のときだけ。`revision` を加算して `issued` に戻し、
  `issued_at`・`issued_by_user_id` を更新する(再発行したあとで初めて PDF を出力できる)。
  """
  def reissue_total_pick(scope, %TotalPick{id: id}) do
    with :ok <- authorize(scope), do: Repo.transact(fn -> do_reissue(scope, id) end)
  end

  defp do_reissue(scope, id) do
    slips = lock_slips_of(id)
    pick = lock_pick(id)

    if pick.status == :outdated and slips != [] do
      pick
      |> Ecto.Changeset.change(
        status: :issued,
        revision: pick.revision + 1,
        issued_at: DateTime.utc_now(:second),
        issued_by_user_id: scope.user.id
      )
      |> Repo.update()
    else
      {:error, :invalid_status}
    end
  end

  @doc """
  取消。`issued` / `outdated` で、紐づく伝票がすべて `allocated`(未梱包)のときだけ。
  伝票は未ピックに戻る。梱包済みの伝票があれば `{:error, :has_packed_slips}`。
  """
  def cancel_total_pick(scope, %TotalPick{id: id}) do
    with :ok <- authorize(scope), do: Repo.transact(fn -> cancel_locked(id) end)
  end

  defp cancel_locked(id) do
    slips = lock_slips_of(id)
    pick = lock_pick(id)

    cond do
      pick.status not in [:issued, :outdated] -> {:error, :invalid_status}
      Enum.any?(slips, &(&1.status != :allocated)) -> {:error, :has_packed_slips}
      true -> do_cancel(pick, slips)
    end
  end

  defp do_cancel(pick, slips) do
    ids = Enum.map(slips, & &1.id)

    from(s in ShippingSlip, where: s.id in ^ids)
    |> Repo.update_all(set: [total_pick_id: nil, updated_at: DateTime.utc_now(:second)])

    pick |> Ecto.Changeset.change(status: :cancelled) |> Repo.update()
  end

  @doc """
  伝票がピックから外れたあとのピックの更新(`FoodShip.ShippingSlips` から呼ぶ内部 API)。

  `slip` は**更新前**の伝票(`total_pick_id` を持つ)。呼び出し側が、同じトランザクションの中で
  伝票を `FOR UPDATE` で確保し、`total_pick_id` を NULL にしたあとで呼ぶ。紐づく伝票が残って
  いなければピックを `cancelled`、残っていて `issued` なら `outdated` にする
  (`outdated` / `cancelled` はそのまま)。出庫取消(F-S7)も、同じようにこの関数を呼ぶ。
  """
  @spec release(Ecto.Repo.t(), %{total_pick_id: Ecto.ULID.t() | nil}) :: :ok
  def release(_repo, %{total_pick_id: nil}), do: :ok

  def release(repo, %{total_pick_id: pick_id}) do
    pick = lock_pick(pick_id)

    remaining =
      repo.aggregate(from(s in ShippingSlip, where: s.total_pick_id == ^pick_id), :count)

    status =
      cond do
        pick.status == :cancelled -> :cancelled
        remaining == 0 -> :cancelled
        pick.status == :issued -> :outdated
        true -> pick.status
      end

    if status != pick.status do
      {:ok, _pick} = pick |> Ecto.Changeset.change(status: status) |> repo.update()
    end

    :ok
  end

  ## 集計

  @doc """
  ピック表の明細と仕分け内訳。伝票の引当ロット明細から都度算出する(梱包済みも含む)。

    * `lines` - 商品コード順 → 期限日昇順(期限なしは最後)の「商品 × 期限日」ごとの行。
      `pieces`(合計バラ数)と、仕分け内訳 `slips`(`slip_no` 昇順の「伝票 × 数量」)を持つ。
      商品の先頭行だけが `order_count`(合計件数)と `box_count`(合計箱数)を持つ(他の行は `nil`)
    * `totals` - 全体の `pieces`・`order_count`・`box_count`

  件数・箱数を期限日ごとに分けないのは、ロットは個数単位なので件数が整数にならない場合があるため。
  """
  def summarize(%TotalPick{id: id}) do
    item_totals = item_totals_query(id) |> Repo.all() |> Map.new(&{&1.item_id, &1})

    lines =
      id
      |> lot_rows_query()
      |> Repo.all()
      |> build_lines()
      |> put_item_counts(item_totals)

    %{
      lines: lines,
      totals: %{
        pieces: lines |> Enum.map(& &1.pieces) |> Enum.sum(),
        order_count: item_totals |> Map.values() |> Enum.map(& &1.order_count) |> Enum.sum(),
        box_count: item_totals |> Map.values() |> Enum.map(& &1.box_count) |> Enum.sum()
      }
    }
  end

  # (伝票 × 引当ロット)の行。ピックに紐づく伝票すべて(梱包済みを含む)
  defp lot_rows_query(pick_id) do
    from l in SlipAllocatedLot,
      join: s in ShippingSlip,
      on: s.id == l.shipping_slip_id,
      join: i in ShippingItem,
      on: i.id == s.shipping_item_id,
      where: s.total_pick_id == ^pick_id,
      select: %{
        item_id: i.id,
        item_code: i.item_code,
        item_name: i.item_name,
        expiration_date: l.expiration_date,
        slip_id: s.id,
        slip_no: s.slip_no,
        pieces: l.allocated_pieces
      }
  end

  # 商品ごとの件数・箱数(伝票単位で合計。期限日の分割で重複しない)
  defp item_totals_query(pick_id) do
    from s in ShippingSlip,
      where: s.total_pick_id == ^pick_id,
      group_by: s.shipping_item_id,
      select: %{
        item_id: s.shipping_item_id,
        order_count: sum(s.order_count),
        box_count: sum(s.box_count)
      }
  end

  defp build_lines(rows) do
    rows
    |> Enum.group_by(&{&1.item_code, &1.item_id, &1.item_name, &1.expiration_date})
    |> Enum.map(fn {{item_code, item_id, item_name, expiration_date}, group} ->
      slips =
        group
        |> Enum.group_by(&{&1.slip_no, &1.slip_id})
        |> Enum.map(fn {{slip_no, slip_id}, rows} ->
          %{
            slip_id: slip_id,
            slip_no: slip_no,
            pieces: rows |> Enum.map(& &1.pieces) |> Enum.sum()
          }
        end)
        |> Enum.sort_by(& &1.slip_no)

      %{
        item_id: item_id,
        item_code: item_code,
        item_name: item_name,
        expiration_date: expiration_date,
        pieces: slips |> Enum.map(& &1.pieces) |> Enum.sum(),
        slips: slips,
        order_count: nil,
        box_count: nil
      }
    end)
    |> Enum.sort_by(&{&1.item_code, &1.expiration_date}, fn {code_a, date_a}, {code_b, date_b} ->
      code_a < code_b or (code_a == code_b and Date.compare(date_a, date_b) != :gt)
    end)
  end

  # 商品の先頭行にだけ件数・箱数を入れる
  defp put_item_counts(lines, item_totals) do
    {lines, _seen} =
      Enum.map_reduce(lines, MapSet.new(), fn line, seen ->
        if MapSet.member?(seen, line.item_id) do
          {line, seen}
        else
          totals = Map.fetch!(item_totals, line.item_id)

          {%{
             line
             | order_count: to_integer(totals.order_count),
               box_count: to_integer(totals.box_count)
           }, MapSet.put(seen, line.item_id)}
        end
      end)

    lines
  end

  ## 共通

  defp lock_slips_of(pick_id) do
    from(s in ShippingSlip,
      where: s.total_pick_id == ^pick_id,
      order_by: [asc: s.id],
      lock: "FOR UPDATE"
    )
    |> Repo.all()
  end

  defp lock_pick(id) do
    TotalPick |> where([p], p.id == ^id) |> lock("FOR UPDATE") |> Repo.one!()
  end

  defp preload_pick(pick) do
    lots = from(l in SlipAllocatedLot, order_by: [asc: l.expiration_date, asc: l.id])
    slips = from(s in ShippingSlip, order_by: [asc: s.slip_no])

    Repo.preload(
      pick,
      [
        :client,
        :issued_by_user,
        shipping_slips: {slips, [:shipping_item, :client, allocated_lots: lots]}
      ],
      force: true
    )
  end

  defp authorize(scope), do: Permission.authorize(scope.user, :manage_total_picks)

  defp to_integer(nil), do: 0
  defp to_integer(%Decimal{} = decimal), do: Decimal.to_integer(decimal)
  defp to_integer(integer) when is_integer(integer), do: integer
end
