defmodule FoodVault.InventoriesTest do
  use FoodVault.DataCase, async: true

  import FoodVault.AccountsFixtures
  import FoodVault.InventoriesFixtures
  import FoodVault.MastersFixtures

  alias FoodVault.{Inventories, Items, Repo, Warehouses}
  alias FoodVault.Inventories.{InventoryLot, InventoryTransaction}

  defp receipt(attrs) do
    Map.merge(%{expiration_date: ~D[2027-01-01], received_date: ~D[2026-11-01]}, Map.new(attrs))
  end

  describe "receive_inventory/2" do
    setup do
      %{
        warehouse: warehouse_fixture(),
        item: item_fixture(),
        staff: user_fixture(%{role: :staff})
      }
    end

    test "新規ロットを作り、受払履歴(receive)を操作者付きで残す", ctx do
      attrs =
        receipt(%{
          warehouse_id: ctx.warehouse.id,
          item_id: ctx.item.id,
          case_qty: 2,
          piece_qty: 5
        })

      assert {:ok, %{lot: lot, transaction: tx}} = Inventories.receive_inventory(ctx.staff, attrs)
      assert lot.case_qty == 2 and lot.piece_qty == 5
      assert lot.allocated_case_qty == 0
      assert lot.expiration_date == ~D[2027-01-01]

      assert %InventoryTransaction{
               transaction_type: :receive,
               case_diff: 2,
               piece_diff: 5,
               lot_id: lot_id,
               user_id: user_id,
               operator: nil
             } = tx

      assert lot_id == lot.id
      assert user_id == ctx.staff.id
    end

    test "同じ倉庫・商品・期限日・入荷日のロットには加算する", ctx do
      attrs = receipt(%{warehouse_id: ctx.warehouse.id, item_id: ctx.item.id, case_qty: 2})
      {:ok, %{lot: first}} = Inventories.receive_inventory(ctx.staff, attrs)

      {:ok, %{lot: second}} =
        Inventories.receive_inventory(ctx.staff, %{attrs | case_qty: 3} |> Map.put(:piece_qty, 4))

      assert second.id == first.id
      assert second.case_qty == 5 and second.piece_qty == 4
      assert Repo.aggregate(InventoryLot, :count) == 1
      assert Repo.aggregate(InventoryTransaction, :count) == 2
    end

    test "期限日か入荷日が違えば別ロット", ctx do
      base = %{warehouse_id: ctx.warehouse.id, item_id: ctx.item.id, case_qty: 1}
      {:ok, %{lot: a}} = Inventories.receive_inventory(ctx.staff, receipt(base))

      {:ok, %{lot: b}} =
        Inventories.receive_inventory(
          ctx.staff,
          receipt(Map.put(base, :expiration_date, ~D[2027-02-01]))
        )

      {:ok, %{lot: c}} =
        Inventories.receive_inventory(
          ctx.staff,
          receipt(Map.put(base, :received_date, ~D[2026-11-02]))
        )

      assert length(Enum.uniq([a.id, b.id, c.id])) == 3
    end

    test "期限なしの商品は期限日が 9999-12-31 で保存され、入力は無視される", ctx do
      item = item_fixture(%{expiration_type: :none})

      assert {:ok, %{lot: lot}} =
               Inventories.receive_inventory(ctx.staff, %{
                 warehouse_id: ctx.warehouse.id,
                 item_id: item.id,
                 expiration_date: ~D[2027-01-01],
                 received_date: ~D[2026-11-01],
                 case_qty: 1
               })

      assert lot.expiration_date == ~D[9999-12-31]
    end

    test "期限なし以外の商品は期限日が必須", ctx do
      assert {:error, changeset} =
               Inventories.receive_inventory(ctx.staff, %{
                 warehouse_id: ctx.warehouse.id,
                 item_id: ctx.item.id,
                 received_date: ~D[2026-11-01],
                 case_qty: 1
               })

      assert %{expiration_date: ["期限日を入力してください"]} = errors_on(changeset)
      assert Repo.aggregate(InventoryLot, :count) == 0
    end

    test "入荷日を省略すると今日(JST)", ctx do
      assert {:ok, %{lot: lot}} =
               Inventories.receive_inventory(ctx.staff, %{
                 warehouse_id: ctx.warehouse.id,
                 item_id: ctx.item.id,
                 expiration_date: ~D[2027-01-01],
                 case_qty: 1
               })

      assert lot.received_date == FoodVault.Utils.ConvertDatetime.today_jst()
    end

    test "数量が 0/0・負数・空欄は拒否する(空欄は 0 扱い)", ctx do
      base = receipt(%{warehouse_id: ctx.warehouse.id, item_id: ctx.item.id})

      assert {:error, cs} =
               Inventories.receive_inventory(
                 ctx.staff,
                 Map.merge(base, %{case_qty: 0, piece_qty: 0})
               )

      assert %{case_qty: [_]} = errors_on(cs)

      assert {:error, cs} =
               Inventories.receive_inventory(
                 ctx.staff,
                 Map.merge(base, %{case_qty: "", piece_qty: ""})
               )

      assert %{case_qty: [_]} = errors_on(cs)

      assert {:error, cs} =
               Inventories.receive_inventory(ctx.staff, Map.merge(base, %{case_qty: -1}))

      assert %{case_qty: [_]} = errors_on(cs)

      assert {:ok, _} =
               Inventories.receive_inventory(
                 ctx.staff,
                 Map.merge(base, %{case_qty: "", piece_qty: "3"})
               )
    end

    test "アーカイブ済みの倉庫・商品、存在しない ID は拒否する", ctx do
      admin = user_scope_fixture()
      {:ok, _} = Warehouses.archive_warehouse(admin, ctx.warehouse)
      attrs = receipt(%{warehouse_id: ctx.warehouse.id, item_id: ctx.item.id, case_qty: 1})

      assert {:error, cs} = Inventories.receive_inventory(ctx.staff, attrs)
      assert %{warehouse_id: [_]} = errors_on(cs)

      {:ok, _} = Items.archive_item(admin, ctx.item)
      warehouse = warehouse_fixture()

      assert {:error, cs} =
               Inventories.receive_inventory(ctx.staff, %{attrs | warehouse_id: warehouse.id})

      assert %{item_id: [_]} = errors_on(cs)

      assert {:error, cs} =
               Inventories.receive_inventory(ctx.staff, %{attrs | item_id: Ecto.ULID.generate()})

      assert %{item_id: [_]} = errors_on(cs)

      assert {:error, cs} = Inventories.receive_inventory(ctx.staff, %{attrs | item_id: "bad"})
      assert %{item_id: [_]} = errors_on(cs)

      assert Repo.aggregate(InventoryLot, :count) == 0
    end

    test "viewer は拒否し、API の操作者は operator として記録する", ctx do
      attrs = receipt(%{warehouse_id: ctx.warehouse.id, item_id: ctx.item.id, case_qty: 1})
      viewer = user_fixture(%{role: :viewer})

      assert {:error, :forbidden} = Inventories.receive_inventory(viewer, attrs)
      assert Repo.aggregate(InventoryLot, :count) == 0

      assert {:ok, %{transaction: tx}} =
               Inventories.receive_inventory({:api, "ship@example.com"}, attrs)

      assert tx.operator == "ship@example.com"
      assert is_nil(tx.user_id)
    end
  end

  describe "受払履歴の追記専用" do
    test "更新・削除は DB が拒否する" do
      lot = lot_fixture()
      tx = Repo.one!(InventoryTransaction)
      assert tx.lot_id == lot.id

      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        Repo.update_all(InventoryTransaction, set: [note: "x"])
      end
    end

    test "削除も拒否する" do
      lot_fixture()

      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        Repo.delete_all(InventoryTransaction)
      end
    end

    test "操作者が無い履歴は追加できない" do
      lot = lot_fixture()

      assert {:error, changeset} =
               %{lot_id: lot.id, transaction_type: :adjust, case_diff: 1, piece_diff: 0}
               |> InventoryTransaction.insert_changeset()
               |> Repo.insert()

      assert %{user_id: [_]} = errors_on(changeset)
    end
  end

  describe "lock_lots_by_ids/1 と record_transaction/6" do
    test "ロックキー順(倉庫・商品・期限日・入荷日・ID)で返す" do
      item = item_fixture()
      w = warehouse_fixture()
      late = lot_fixture(%{warehouse_id: w.id, item_id: item.id, expiration_date: ~D[2027-03-01]})

      early =
        lot_fixture(%{warehouse_id: w.id, item_id: item.id, expiration_date: ~D[2027-02-01]})

      assert Inventories.lock_lots_by_ids([late.id, early.id]) |> Enum.map(& &1.id) ==
               [early.id, late.id]
    end

    test "受払履歴を追加できる" do
      lot = lot_fixture()
      admin = admin_fixture()

      assert {:ok, %InventoryTransaction{transaction_type: :adjust, note: "理由"}} =
               Inventories.record_transaction(admin, lot.id, :adjust, 1, 0, note: "理由")
    end
  end

  describe "list_inventory_lots/1" do
    setup do
      item = item_fixture()
      w1 = warehouse_fixture()
      w2 = warehouse_fixture()
      far = lot_fixture(%{warehouse_id: w1.id, item_id: item.id, expiration_date: ~D[2027-06-01]})

      near =
        lot_fixture(%{warehouse_id: w2.id, item_id: item.id, expiration_date: ~D[2027-02-01]})

      %{item: item, w1: w1, w2: w2, far: far, near: near}
    end

    test "期限の近い順に並ぶ", %{far: far, near: near, item: item} do
      ids = Inventories.list_inventory_lots(%{"item_id" => item.id}).entries |> Enum.map(& &1.id)
      assert ids == [near.id, far.id]
    end

    test "倉庫・商品・期限で絞り込める", %{w1: w1, far: far, near: near, item: item} do
      assert [%{id: id}] = Inventories.list_inventory_lots(%{"warehouse_id" => w1.id}).entries
      assert id == far.id

      other = lot_fixture()
      assert [%{id: id}] = Inventories.list_inventory_lots(%{"item_id" => other.item_id}).entries
      assert id == other.id

      ids =
        Inventories.list_inventory_lots(%{
          "item_id" => item.id,
          "expiration_from" => "2027-03-01",
          "expiration_to" => "2027-12-31"
        }).entries
        |> Enum.map(& &1.id)

      assert ids == [far.id]
      refute near.id in ids
    end

    test "不正なフィルタ値は無視する", %{item: item} do
      page =
        Inventories.list_inventory_lots(%{
          "item_id" => item.id,
          "warehouse_id" => "bad",
          "expiration_from" => "not a date"
        })

      assert length(page.entries) == 2
    end

    test "在庫 0 のロットは既定で非表示、include_empty で表示" do
      lot = lot_fixture()
      lot |> Ecto.Changeset.change(case_qty: 0) |> Repo.update!()

      refute Enum.any?(Inventories.list_inventory_lots(%{}).entries, &(&1.id == lot.id))

      assert Enum.any?(
               Inventories.list_inventory_lots(%{"include_empty" => "true"}).entries,
               &(&1.id == lot.id)
             )
    end

    test "倉庫・商品・メーカーを preload する", %{far: far} do
      entry = Inventories.list_inventory_lots(%{}).entries |> Enum.find(&(&1.id == far.id))
      assert entry.warehouse.warehouse_name == "テスト倉庫"
      assert entry.item.maker.maker_name == "テストメーカー"
    end
  end

  describe "list_inventory_summaries/1" do
    test "倉庫 × 商品でロットを合算し、最も近い期限の順に並べる" do
      item = item_fixture()
      w = warehouse_fixture()

      lot_fixture(%{
        warehouse_id: w.id,
        item_id: item.id,
        case_qty: 2,
        piece_qty: 1,
        expiration_date: ~D[2027-03-01]
      })

      lot_fixture(%{
        warehouse_id: w.id,
        item_id: item.id,
        case_qty: 1,
        piece_qty: 4,
        expiration_date: ~D[2027-02-01]
      })

      other = lot_fixture(%{expiration_date: ~D[2027-01-15]})

      [first, second] =
        Inventories.list_inventory_summaries(%{})
        |> Map.fetch!(:entries)

      assert first.item_id == other.item_id
      assert second.item_id == item.id
      assert second.case_qty == 3
      assert second.piece_qty == 5
      assert second.earliest_expiration == ~D[2027-02-01]
      assert second.units_per_case == 12
    end

    test "在庫 0 のロットだけの商品は既定で出ない" do
      lot = lot_fixture()
      lot |> Ecto.Changeset.change(case_qty: 0) |> Repo.update!()

      assert Inventories.list_inventory_summaries(%{}).entries == []
      assert [_] = Inventories.list_inventory_summaries(%{"include_empty" => "true"}).entries
    end
  end

  describe "list_inventory_transactions/1" do
    setup do
      staff = user_fixture(%{role: :staff})
      lot = lot_fixture(%{actor: staff, case_qty: 3})
      other = lot_fixture(%{actor: {:api, "ship@example.com"}})
      %{staff: staff, lot: lot, other: other}
    end

    test "ロット・商品・倉庫・処理区分・操作者で絞り込める", ctx do
      assert [tx] = Inventories.list_inventory_transactions(%{"lot_id" => ctx.lot.id}).entries
      assert tx.lot.warehouse.warehouse_name == "テスト倉庫"
      assert tx.user.id == ctx.staff.id

      assert [_] =
               Inventories.list_inventory_transactions(%{"item_id" => ctx.lot.item_id}).entries

      assert [_] =
               Inventories.list_inventory_transactions(%{"warehouse_id" => ctx.lot.warehouse_id}).entries

      assert [_] = Inventories.list_inventory_transactions(%{"user_id" => ctx.staff.id}).entries

      assert length(
               Inventories.list_inventory_transactions(%{"transaction_type" => "receive"}).entries
             ) == 2

      assert Inventories.list_inventory_transactions(%{"transaction_type" => "ship"}).entries ==
               []

      assert length(
               Inventories.list_inventory_transactions(%{"transaction_type" => "bad"}).entries
             ) == 2
    end

    test "期間(JST の日付)で絞り込める" do
      today = FoodVault.Utils.ConvertDatetime.today_jst()
      tomorrow = Date.add(today, 1)
      yesterday = Date.add(today, -1)

      assert length(
               Inventories.list_inventory_transactions(%{
                 "from" => Date.to_iso8601(today),
                 "to" => Date.to_iso8601(today)
               }).entries
             ) == 2

      assert Inventories.list_inventory_transactions(%{"from" => Date.to_iso8601(tomorrow)}).entries ==
               []

      assert Inventories.list_inventory_transactions(%{"to" => Date.to_iso8601(yesterday)}).entries ==
               []
    end

    test "新しい順に並ぶ", ctx do
      ids = Inventories.list_inventory_transactions(%{}).entries |> Enum.map(& &1.lot_id)
      assert ids == [ctx.other.id, ctx.lot.id]
    end
  end
end
