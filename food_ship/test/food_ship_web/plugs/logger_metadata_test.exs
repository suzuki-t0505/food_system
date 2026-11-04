defmodule FoodShipWeb.Plugs.LoggerMetadataTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias FoodShipWeb.Plugs.LoggerMetadata

  test "remote_ip を Logger のメタデータに設定する" do
    conn = conn(:get, "/") |> Map.put(:remote_ip, {192, 0, 2, 10})

    assert ^conn = LoggerMetadata.call(conn, LoggerMetadata.init([]))
    assert Logger.metadata()[:remote_ip] == "192.0.2.10"
  end

  test "IPv6 も文字列にする" do
    conn = conn(:get, "/") |> Map.put(:remote_ip, {0, 0, 0, 0, 0, 0, 0, 1})

    LoggerMetadata.call(conn, [])

    assert Logger.metadata()[:remote_ip] == "::1"
  end
end
