defmodule FoodShip.ClientsTest do
  use FoodShip.DataCase, async: true

  import FoodShip.AccountsFixtures
  import FoodShip.MastersFixtures

  alias FoodShip.Clients
  alias FoodShip.Clients.Client

  describe "create_client/2" do
    test "admin は登録できる(前後の空白は除く)" do
      assert {:ok, %Client{client_code: "C01", client_name: "発注元X"}} =
               Clients.create_client(user_scope_fixture(), %{
                 "client_code" => " C01 ",
                 "client_name" => "発注元X"
               })
    end

    test "必須項目が無ければ changeset エラー" do
      assert {:error, changeset} = Clients.create_client(user_scope_fixture(), %{})

      assert %{client_code: ["can't be blank"], client_name: ["can't be blank"]} =
               errors_on(changeset)
    end

    test "コードの重複は拒否する" do
      client = client_fixture()

      assert {:error, changeset} =
               Clients.create_client(user_scope_fixture(), %{
                 client_code: client.client_code,
                 client_name: "別名"
               })

      assert %{client_code: ["has already been taken"]} = errors_on(changeset)
    end

    for role <- [:staff, :viewer] do
      test "#{role} は拒否する" do
        scope =
          user_scope_fixture(user_fixture(%{role: unquote(role), must_change_password: false}))

        assert {:error, :forbidden} =
                 Clients.create_client(scope, %{client_code: "X", client_name: "X"})

        assert Clients.list_clients(%{"include_archived" => "true"}) == []
      end
    end
  end

  describe "update_client/3" do
    test "名称を更新できる" do
      client = client_fixture()

      assert {:ok, %Client{client_name: "新名称"}} =
               Clients.update_client(user_scope_fixture(), client, %{client_name: "新名称"})
    end

    test "staff は拒否し、値は変わらない" do
      scope = user_scope_fixture(user_fixture(%{role: :staff, must_change_password: false}))
      client = client_fixture(%{client_name: "元の名称"})

      assert {:error, :forbidden} = Clients.update_client(scope, client, %{client_name: "改名"})
      assert Clients.get_client!(client.id).client_name == "元の名称"
    end
  end

  describe "archive_client/2 と restore_client/2" do
    test "アーカイブすると選択肢(all_clients)に出ず、復帰すると戻る" do
      scope = user_scope_fixture()
      client = client_fixture()

      assert {:ok, archived} = Clients.archive_client(scope, client)
      assert Client.archived?(archived)
      refute Enum.any?(Clients.all_clients(), &(&1.id == client.id))

      assert Enum.any?(
               Clients.list_clients(%{"include_archived" => "true"}),
               &(&1.id == client.id)
             )

      assert {:ok, restored} = Clients.restore_client(scope, archived)
      refute Client.archived?(restored)
      assert Enum.any?(Clients.all_clients(), &(&1.id == client.id))
    end

    test "viewer は拒否する" do
      scope = user_scope_fixture(user_fixture(%{role: :viewer, must_change_password: false}))
      client = client_fixture()

      assert {:error, :forbidden} = Clients.archive_client(scope, client)
      refute Client.archived?(Clients.get_client!(client.id))
    end
  end

  describe "list_clients/1" do
    test "コード順に返す" do
      b = client_fixture(%{client_code: "B-1"})
      a = client_fixture(%{client_code: "A-1"})

      assert [a.id, b.id] == Enum.map(Clients.list_clients(), & &1.id)
    end
  end
end
