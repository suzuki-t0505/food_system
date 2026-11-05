defmodule FoodVaultWeb.Plugs.ServiceTokenAuthTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias FoodVaultWeb.Plugs.ServiceTokenAuth

  @token "test-inventory-api-token"
  @token2 "test-inventory-api-token-2"

  defp call(authorization) do
    conn = conn(:get, "/api/v1/warehouses")

    conn =
      case authorization do
        nil -> conn
        value -> put_req_header(conn, "authorization", value)
      end

    ServiceTokenAuth.call(conn, ServiceTokenAuth.init([]))
  end

  defp assert_unauthorized(conn) do
    assert conn.halted
    assert conn.status == 401
    assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
    assert %{"error" => "unauthorized", "message" => _} = Jason.decode!(conn.resp_body)
  end

  describe "call/2" do
    test "登録済みのトークンは通す(複数のうちどれでもよい)" do
      for token <- [@token, @token2] do
        conn = call("Bearer " <> token)
        refute conn.halted
        assert conn.status == nil
      end
    end

    test "スキームは大文字小文字を区別しない" do
      refute call("bearer " <> @token).halted
    end

    test "ヘッダなしは 401" do
      assert_unauthorized(call(nil))
    end

    test "不一致のトークンは 401" do
      assert_unauthorized(call("Bearer wrong-token"))
    end

    test "Bearer 以外のスキーム・トークンなし・形式不正は 401" do
      for header <- ["Basic " <> @token, "Bearer", "Bearer ", "Bearer   ", @token] do
        assert_unauthorized(call(header))
      end
    end

    test "失敗をログに残すが、トークンとヘッダは出さない" do
      log = capture_log(fn -> call("Bearer secret-wrong-token") end)

      assert log =~ "サービストークン認証に失敗しました。"
      assert log =~ "/api/v1/warehouses"
      refute log =~ "secret-wrong-token"
      refute log =~ "Bearer"
    end
  end

  describe "valid_token?/1" do
    test "登録済みなら true" do
      assert ServiceTokenAuth.valid_token?(@token)
      assert ServiceTokenAuth.valid_token?(@token2)
    end

    test "未登録・空・文字列以外は false" do
      refute ServiceTokenAuth.valid_token?("nope")
      refute ServiceTokenAuth.valid_token?(@token <> "x")
      refute ServiceTokenAuth.valid_token?("")
      refute ServiceTokenAuth.valid_token?(nil)
    end
  end
end
