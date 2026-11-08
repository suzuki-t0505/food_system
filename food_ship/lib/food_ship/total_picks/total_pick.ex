defmodule FoodShip.TotalPicks.TotalPick do
  @moduledoc """
  トータルピック。同じ「出荷予定日 × 発注元 × メーカー」の引当済み伝票を束ねた作業単位。

  明細(商品 × 期限日の合算)は持たず、紐づく伝票の引当ロット明細から都度集計する
  (`FoodShip.TotalPicks.summarize/1`)。同じ組み合わせに複数のピックがあってよい(追加ピック)。
  `pick_no` は DB シーケンスで採番する読み取り専用の列(`cast` に含めない)。

    * `issued` - 発行済(PDF を出力できる)
    * `outdated` - 要再発行(紐づく伝票が外れた。再発行するまで PDF を出力できない)
    * `cancelled` - 取消
  """

  use FoodShip.Schema
  import Ecto.Changeset

  alias FoodShip.Accounts.User
  alias FoodShip.Clients.Client
  alias FoodShip.ShippingSlips.ShippingSlip

  @statuses [:issued, :outdated, :cancelled]

  @status_labels %{issued: "発行済", outdated: "要再発行", cancelled: "取消"}

  schema "total_picks" do
    field :pick_no, :integer, read_after_writes: true
    field :scheduled_ship_date, :date
    field :inventory_maker_id, Ecto.ULID
    field :maker_name, :string
    field :status, Ecto.Enum, values: @statuses, default: :issued
    field :revision, :integer, default: 1
    field :issued_at, :utc_datetime

    # 一覧用。`FoodShip.TotalPicks.list_total_picks/2` が紐づく伝票数を入れる
    field :slip_count, :integer, virtual: true

    belongs_to :client, Client
    belongs_to :issued_by_user, User

    has_many :shipping_slips, ShippingSlip

    timestamps(type: :utc_datetime)
  end

  @doc "ステータスの一覧。"
  def statuses, do: @statuses

  @doc "ステータスの表示名。"
  def status_label(status), do: Map.fetch!(@status_labels, status)

  @doc "ピック番号の表示(`TP-000045`)。"
  def pick_no_label(%__MODULE__{pick_no: nil}), do: ""

  def pick_no_label(%__MODULE__{pick_no: pick_no}),
    do: "TP-" <> String.pad_leading(Integer.to_string(pick_no), 6, "0")

  @doc "PDF を出力できるか(`issued` のみ)。"
  def printable?(%__MODULE__{status: status}), do: status == :issued

  @doc "作成用。発行者・発行日時は呼び出し側が渡す。"
  def create_changeset(pick, attrs) do
    pick
    |> cast(attrs, [
      :scheduled_ship_date,
      :client_id,
      :inventory_maker_id,
      :maker_name,
      :issued_at,
      :issued_by_user_id
    ])
    |> validate_required([
      :scheduled_ship_date,
      :client_id,
      :inventory_maker_id,
      :maker_name,
      :issued_at,
      :issued_by_user_id
    ])
    |> put_change(:status, :issued)
    |> put_change(:revision, 1)
    |> assoc_constraint(:client)
    |> assoc_constraint(:issued_by_user)
  end
end
