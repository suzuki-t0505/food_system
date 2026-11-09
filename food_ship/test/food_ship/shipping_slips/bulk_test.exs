defmodule FoodShip.ShippingSlips.BulkTest do
  # Req.Test のスタブを扱う(対象の取得テスト)ため async: false
  use FoodShip.DataCase, async: false

  import FoodShip.AccountsFixtures
  import FoodShip.ShippingSlipsFixtures

  alias FoodShip.{InventoryStub, ShippingSlips}
  alias FoodShip.ShippingSlips.{Bulk, ShippingSlip}

  setup {Req.Test, :set_req_test_from_context}

  setup do
    InventoryStub.stub_defaults()
    :ok
  end

  defp set_row(slip, attrs) do
    Repo.update_all(from(s in ShippingSlip, where: s.id == ^slip.id), set: attrs)
    slip
  end

  describe "run/4" do
    test "与えられた順に 1 件ずつ処理し、1 件ごとに通知する" do
      slips = for n <- 1..3, do: %ShippingSlip{id: "id-#{n}"}
      pid = self()

      fun = fn :scope, slip -> {:ok, slip} end

      notify = fn index, total, slip, result ->
        send(pid, {:notified, index, total, slip.id, result})
      end

      assert :ok = Bulk.run(:scope, slips, fun, notify)

      assert_received {:notified, 1, 3, "id-1", {:ok, %ShippingSlip{id: "id-1"}}}
      assert_received {:notified, 2, 3, "id-2", {:ok, %ShippingSlip{id: "id-2"}}}
      assert_received {:notified, 3, 3, "id-3", {:ok, %ShippingSlip{id: "id-3"}}}
    end

    test "1 件の例外は {:error, :unexpected} にして、残りを続ける" do
      slips = for n <- 1..3, do: %ShippingSlip{id: "id-#{n}"}
      pid = self()

      fun = fn :scope, slip ->
        if slip.id == "id-2", do: raise("boom"), else: {:ok, slip}
      end

      Bulk.run(:scope, slips, fun, fn index, _total, _slip, result ->
        send(pid, {:notified, index, result})
      end)

      assert_received {:notified, 1, {:ok, _}}
      assert_received {:notified, 2, {:error, :unexpected}}
      assert_received {:notified, 3, {:ok, _}}
    end

    test "exit や throw も {:error, :unexpected} にする" do
      slips = [%ShippingSlip{id: "a"}, %ShippingSlip{id: "b"}]
      pid = self()

      fun = fn :scope, slip ->
        if slip.id == "a", do: exit(:killed), else: throw(:oops)
      end

      Bulk.run(:scope, slips, fun, fn index, _total, _slip, result ->
        send(pid, {:notified, index, result})
      end)

      assert_received {:notified, 1, {:error, :unexpected}}
      assert_received {:notified, 2, {:error, :unexpected}}
    end

    test "空のリストは何も通知しない" do
      pid = self()

      fun = fn _scope, _slip -> {:ok, nil} end
      notify = fn _index, _total, _slip, _result -> send(pid, :called) end

      assert :ok = Bulk.run(:scope, [], fun, notify)

      refute_received :called
    end
  end

  describe "list_reallocation_targets/0" do
    test "pending / shortage を、出荷予定日の昇順 → slip_no の昇順で返す(全日付)" do
      scope = user_scope_fixture()

      late = slip_fixture(%{scheduled_ship_date: ~D[2026-11-25]}, scope)
      early_a = slip_fixture(%{scheduled_ship_date: ~D[2026-11-20]}, scope)
      early_b = slip_fixture(%{scheduled_ship_date: ~D[2026-11-20]}, scope)

      shortage =
        set_row(slip_fixture(%{scheduled_ship_date: ~D[2026-11-22]}, scope), status: :shortage)

      assert Enum.map(ShippingSlips.list_reallocation_targets(), & &1.id) ==
               [early_a.id, early_b.id, shortage.id, late.id]
    end

    test "引当済み・梱包完了・取消などは対象外" do
      scope = user_scope_fixture()

      pending = slip_fixture(%{}, scope)

      for status <- [:allocated, :packed, :cancelled, :reversed] do
        set_row(slip_fixture(%{}, scope), status: status)
      end

      assert Enum.map(ShippingSlips.list_reallocation_targets(), & &1.id) == [pending.id]
    end

    test "恒久エラーの pending は対象外。エラーなし・一時エラー・idempotency_conflict は対象" do
      scope = user_scope_fixture()

      none = slip_fixture(%{}, scope)
      connection = set_row(slip_fixture(%{}, scope), allocation_error: :connection)
      conflict = set_row(slip_fixture(%{}, scope), allocation_error: :idempotency_conflict)

      for error <- [:unauthorized, :not_found, :validation_failed] do
        set_row(slip_fixture(%{}, scope), allocation_error: error)
      end

      ids = ShippingSlips.list_reallocation_targets() |> Enum.map(& &1.id) |> MapSet.new()
      assert ids == MapSet.new([none.id, connection.id, conflict.id])
    end

    test "エラーなしの shortage は対象" do
      scope = user_scope_fixture()
      shortage = set_row(slip_fixture(%{}, scope), status: :shortage, shortage_pieces: 5)

      assert [%{id: id}] = ShippingSlips.list_reallocation_targets()
      assert id == shortage.id
    end

    test "発注元・商品・引当ロットを preload する" do
      scope = user_scope_fixture()
      slip_fixture(%{}, scope)

      assert [slip] = ShippingSlips.list_reallocation_targets()
      assert slip.client.client_name
      assert slip.shipping_item.item_code
      assert slip.allocated_lots == []
    end
  end

  describe "list_slips_by_ids/1" do
    test "指定した ID の伝票を、出荷予定日の昇順 → slip_no の昇順で返す" do
      scope = user_scope_fixture()

      late = slip_fixture(%{scheduled_ship_date: ~D[2026-11-25]}, scope)
      early_a = slip_fixture(%{scheduled_ship_date: ~D[2026-11-20]}, scope)
      early_b = slip_fixture(%{scheduled_ship_date: ~D[2026-11-20]}, scope)
      _other = slip_fixture(%{}, scope)

      slips = ShippingSlips.list_slips_by_ids([late.id, early_b.id, early_a.id])

      assert Enum.map(slips, & &1.id) == [early_a.id, early_b.id, late.id]
    end

    test "存在しない ID・不正な ID は無視する" do
      scope = user_scope_fixture()
      slip = slip_fixture(%{}, scope)

      assert [%{id: id}] =
               ShippingSlips.list_slips_by_ids([slip.id, Ecto.ULID.generate(), "not-an-id", nil])

      assert id == slip.id
      assert ShippingSlips.list_slips_by_ids([]) == []
    end
  end
end
