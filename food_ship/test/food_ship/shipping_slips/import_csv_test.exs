defmodule FoodShip.ShippingSlips.ImportCsvTest do
  # Req.Test のスタブを扱うため async: false
  use FoodShip.DataCase, async: false

  import FoodShip.AccountsFixtures
  import FoodShip.MastersFixtures
  import FoodShip.ShippingSlipsFixtures

  alias FoodShip.{Clients, InventoryStub, ShippingSlips}
  alias FoodShip.ShippingSlips.ShippingSlip

  setup {Req.Test, :set_req_test_from_context}

  # 取込では、在庫のデフォルト倉庫の取得が走る
  setup do
    InventoryStub.stub_defaults()

    scope = user_scope_fixture()
    client = client_fixture(%{client_code: "CL1"})
    item = shipping_item_fixture(%{item_code: "IT1"})
    {:ok, scope: scope, client: client, item: item}
  end

  @header "client_code,client_slip_no,scheduled_ship_date,item_code,order_count"

  defp csv(lines), do: Enum.join([@header | lines], "\n") <> "\n"

  defp slip_count, do: Repo.aggregate(ShippingSlip, :count)

  defp viewer_scope,
    do: user_scope_fixture(user_fixture(%{role: :viewer, must_change_password: false}))

  describe "import_csv/2: 正常系" do
    test "全行を csv / pending で保存し、引当順(出荷予定日 → ファイル順)で返す", %{scope: scope} do
      content =
        csv([
          "CL1,A-1,2026-11-22,IT1,3",
          "CL1,A-2,2026-11-20,IT1,5",
          "CL1,A-3,2026-11-20,IT1,1"
        ])

      assert {:ok, [{3, third}, {4, fourth}, {2, first}]} =
               ShippingSlips.import_csv(scope, content)

      assert [first.client_slip_no, third.client_slip_no, fourth.client_slip_no] ==
               ["A-1", "A-2", "A-3"]

      for slip <- [first, third, fourth] do
        assert slip.status == :pending
        assert slip.input_source == :csv
        assert slip.created_by_user_id == scope.user.id
        assert slip.client.client_code == "CL1"
        assert slip.shipping_item.item_code == "IT1"
      end

      assert slip_count() == 3
    end

    test "slip_no の採番はファイル順", %{scope: scope} do
      content = csv(["CL1,A-1,2026-11-22,IT1,3", "CL1,A-2,2026-11-20,IT1,5"])

      assert {:ok, [{3, file_second}, {2, file_first}]} = ShippingSlips.import_csv(scope, content)

      assert file_first.slip_no < file_second.slip_no
      assert file_first.scheduled_ship_date == ~D[2026-11-22]
    end

    test "数量はマスタから計算する(標準: 1 件 = 2 箱・12 バラ)", %{scope: scope} do
      assert {:ok, [{2, slip}]} =
               ShippingSlips.import_csv(scope, csv(["CL1,A-1,2026-11-20,IT1,3"]))

      assert slip.order_count == 3
      assert slip.box_count == 6
      assert slip.total_piece_qty == 36
      assert slip.min_expiration_date == nil
    end

    test "出荷期限ルールがあれば最低許容期限日を計算する", %{scope: scope, client: client, item: item} do
      expiration_rule_fixture(%{
        client_id: client.id,
        shipping_item_id: item.id,
        min_remaining_days: 30
      })

      assert {:ok, [{2, slip}]} =
               ShippingSlips.import_csv(scope, csv(["CL1,A-1,2026-11-20,IT1,3"]))

      assert slip.min_expiration_date == ~D[2026-12-20]
    end

    test "同じ発注元伝票番号でも、商品が違えば取り込める", %{scope: scope} do
      shipping_item_fixture(%{item_code: "IT2"})

      assert {:ok, [_, _]} =
               ShippingSlips.import_csv(
                 scope,
                 csv(["CL1,A-1,2026-11-20,IT1,3", "CL1,A-1,2026-11-20,IT2,3"])
               )
    end

    test "1,000 行の検証・保存が 30 秒以内", %{scope: scope} do
      lines = for n <- 1..1_000, do: "CL1,P-#{n},2026-11-#{rem(n, 20) + 1 + 9},IT1,2"

      {microseconds, result} = :timer.tc(fn -> ShippingSlips.import_csv(scope, csv(lines)) end)

      assert {:ok, saved} = result
      assert length(saved) == 1_000
      assert slip_count() == 1_000
      assert microseconds < 30_000_000
    end
  end

  describe "import_csv/2: 検証エラー(1 行でもあれば何も保存しない)" do
    test "行番号つきで、全行ぶんのエラーを返す", %{scope: scope} do
      {:ok, _} = Clients.archive_client(scope, client_fixture(%{client_code: "CL-OLD"}))

      content =
        csv([
          "CL1,,2026-11-20,IT1,3",
          "NOPE,A-2,2026-11-20,IT1,3",
          "CL1,A-3,2026/11/20,IT1,3",
          "CL1,A-4,2026-11-20,IT1,0",
          "CL1,A-5,2026-11-20,IT1,x",
          "CL1,A-6,2026-11-20,NOPE,3",
          "CL-OLD,A-7,2026-11-20,IT1,3",
          "CL1,A-8,2026-11-20",
          "CL1,A-9,2026-11-20,IT1,3"
        ])

      assert {:error, {:invalid, errors}} = ShippingSlips.import_csv(scope, content)

      assert Enum.map(errors, & &1.line) == [2, 3, 4, 5, 6, 7, 8, 9]

      messages = Map.new(errors, &{&1.line, &1.message})
      assert messages[2] =~ "client_slip_no は必須"
      assert messages[3] =~ "client_code「NOPE」は登録されていません"
      assert messages[4] =~ "scheduled_ship_date は YYYY-MM-DD"
      assert messages[5] =~ "order_count は 1 以上"
      assert messages[6] =~ "order_count は 1 以上"
      assert messages[7] =~ "item_code「NOPE」は登録されていません"
      assert messages[8] =~ "client_code「CL-OLD」はアーカイブ済み"
      assert messages[9] =~ "列数が正しくありません"

      # 有効な行(10 行目)も含め、1 件も保存されない
      assert slip_count() == 0
    end

    test "同じ行の複数のエラーはまとめて返す", %{scope: scope} do
      assert {:error, {:invalid, errors}} =
               ShippingSlips.import_csv(scope, csv(["NOPE,A-1,bad,NOPE,0"]))

      assert length(errors) >= 4
      assert Enum.all?(errors, &(&1.line == 2))
    end

    test "ファイル内の重複は、2 回目以降の行のエラー", %{scope: scope} do
      content =
        csv([
          "CL1,A-1,2026-11-20,IT1,3",
          "CL1,A-2,2026-11-20,IT1,3",
          "CL1,A-1,2026-11-21,IT1,5"
        ])

      assert {:error, {:invalid, [%{line: 4, message: message}]}} =
               ShippingSlips.import_csv(scope, content)

      assert message =~ "client_slip_no「A-1」は 2 行目と重複"
      assert slip_count() == 0
    end

    test "すでに登録済みの有効な伝票と重複していればエラー", %{scope: scope, client: client, item: item} do
      slip_fixture(
        %{client_id: client.id, shipping_item_id: item.id, client_slip_no: "A-1"},
        scope
      )

      assert {:error, {:invalid, [%{line: 3, message: message}]}} =
               ShippingSlips.import_csv(
                 scope,
                 csv(["CL1,A-2,2026-11-20,IT1,3", "CL1,A-1,2026-11-20,IT1,3"])
               )

      assert message =~ "client_slip_no"
      assert message =~ "すでに登録されています"
      assert slip_count() == 1
    end

    test "取消済みの伝票の発注元伝票番号は再利用できる", %{scope: scope, client: client, item: item} do
      slip =
        slip_fixture(
          %{client_id: client.id, shipping_item_id: item.id, client_slip_no: "A-1"},
          scope
        )

      Repo.update_all(from(s in ShippingSlip, where: s.id == ^slip.id),
        set: [
          status: :cancelled,
          cancelled_at: DateTime.utc_now(:second),
          cancelled_by_user_id: scope.user.id
        ]
      )

      assert {:ok, [_]} = ShippingSlips.import_csv(scope, csv(["CL1,A-1,2026-11-20,IT1,3"]))
    end
  end

  describe "import_csv/2: ファイル単位のエラー・拒否" do
    test "見出しが違う・UTF-8 でない・データ行なしは {:file, message}", %{scope: scope} do
      assert {:error, {:file, "1 行目の見出しが正しくありません" <> _}} =
               ShippingSlips.import_csv(scope, "a,b,c\n1,2,3\n")

      assert {:error, {:file, "UTF-8" <> _}} =
               ShippingSlips.import_csv(scope, @header <> "\nCL1,\xFF,2026-11-20,IT1,3\n")

      assert {:error, {:file, "データ行がありません。"}} = ShippingSlips.import_csv(scope, csv([]))

      assert slip_count() == 0
    end

    test "デフォルト倉庫が未設定なら、ファイルを読まずに拒否する", %{scope: scope} do
      InventoryStub.routes([
        {"GET", "/api/v1/warehouses", &InventoryStub.without_default_warehouse/1}
      ])

      assert {:error, :warehouse_not_configured} =
               ShippingSlips.import_csv(scope, csv(["CL1,A-1,2026-11-20,IT1,3"]))

      assert slip_count() == 0
    end

    test "在庫 API に接続できなければ拒否する", %{scope: scope} do
      InventoryStub.routes([{"GET", "/api/v1/warehouses", &InventoryStub.timeout/1}])

      assert {:error, :connection} =
               ShippingSlips.import_csv(scope, csv(["CL1,A-1,2026-11-20,IT1,3"]))

      assert slip_count() == 0
    end

    test "viewer は拒否する" do
      assert {:error, :forbidden} =
               ShippingSlips.import_csv(viewer_scope(), csv(["CL1,A-1,2026-11-20,IT1,3"]))

      assert slip_count() == 0
    end
  end
end
