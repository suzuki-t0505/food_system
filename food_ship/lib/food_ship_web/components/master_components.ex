defmodule FoodShipWeb.MasterComponents do
  @moduledoc "マスタ画面で共通に使う業務用コンポーネント。`core_components.ex` は改変しない。"

  use Phoenix.Component

  @doc "アーカイブ済みの表示。"
  attr :archived_at, :any, required: true

  def archived_badge(assigns) do
    ~H"""
    <span :if={@archived_at} class="badge badge-neutral">アーカイブ済み</span>
    """
  end
end
