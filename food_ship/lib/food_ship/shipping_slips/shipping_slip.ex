defmodule FoodShip.ShippingSlips.ShippingSlip do
  @moduledoc """
  出荷伝票。「発注元 × 発送商品 × 出荷予定日」の 1 件分の出荷依頼。

  在庫側の引当・確定は発送側の API 呼び出しで行い、結果をこの伝票に反映する。
  先に `pending` で保存してから在庫 API を呼ぶ(通信失敗でも入力が消えない)。

  数量・期限は Context(`FoodShip.ShippingSlips`)がマスタから計算して渡す。
  `slip_no` は DB シーケンスで採番する読み取り専用の列(`cast` に含めない)。
  `total_pick_id`(トータルピック)は段階 5 で追加する。

    * `create_changeset/2` - 登録(`pending`)
    * `update_changeset/2` - 件数・出荷予定日の変更(`pending` に戻す)
    * `box_count_changeset/2` - 箱数の修正
  """

  use FoodShip.Schema
  import Ecto.Changeset

  alias FoodShip.Accounts.User
  alias FoodShip.Clients.Client
  alias FoodShip.ShippingItems.ShippingItem
  alias FoodShip.ShippingSlips.SlipAllocatedLot

  @statuses [:pending, :allocated, :shortage, :packed, :cancelled, :reversed]
  @allocation_errors [
    :connection,
    :unauthorized,
    :not_found,
    :validation_failed,
    :idempotency_conflict
  ]
  @input_sources [:manual, :csv]

  @status_labels %{
    pending: "引当待ち",
    allocated: "引当済・未梱包",
    shortage: "在庫不足",
    packed: "梱包完了",
    cancelled: "取消",
    reversed: "出庫取消済"
  }

  @transient_errors [:connection]
  # 一括再引当の対象にする `pending` の引当エラー。一時エラーに加え、再引当が旧オーダーの解除から
  # 行うため直る `idempotency_conflict`。恒久エラー(`unauthorized`・`not_found`・`validation_failed`)は
  # 設定・マスタ・内容を直してから個別に再引当する
  @retryable_errors [:connection, :idempotency_conflict]

  schema "shipping_slips" do
    field :slip_no, :integer, read_after_writes: true
    field :client_slip_no, :string
    field :scheduled_ship_date, :date
    field :order_count, :integer
    field :box_count, :integer
    field :total_piece_qty, :integer
    field :min_expiration_date, :date
    field :inventory_order_id, Ecto.ULID
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :shortage_pieces, :integer
    field :allocation_error, Ecto.Enum, values: @allocation_errors
    field :allocation_attempted_at, :utc_datetime_usec
    field :input_source, Ecto.Enum, values: @input_sources
    field :packed_at, :utc_datetime
    field :cancelled_at, :utc_datetime
    field :reversed_at, :utc_datetime
    field :reverse_reason, :string

    belongs_to :client, Client
    belongs_to :shipping_item, ShippingItem
    belongs_to :created_by_user, User
    belongs_to :packed_by_user, User
    belongs_to :cancelled_by_user, User
    belongs_to :reversed_by_user, User

    has_many :allocated_lots, SlipAllocatedLot

    timestamps(type: :utc_datetime)
  end

  @doc "ステータスの一覧。"
  def statuses, do: @statuses

  @doc "ステータスの表示名。"
  def status_label(status), do: Map.fetch!(@status_labels, status)

  @doc "伝票番号の表示(`S-000123`)。"
  def slip_no_label(%__MODULE__{slip_no: nil}), do: ""

  def slip_no_label(%__MODULE__{slip_no: slip_no}),
    do: "S-" <> String.pad_leading(Integer.to_string(slip_no), 6, "0")

  @doc "一時エラー(再試行で直る)か。恒久エラーは設定・マスタ・内容の修正が必要。"
  def transient_error?(error), do: error in @transient_errors

  @doc "一括再引当の対象になる引当エラー(`nil` = エラーなしを含む)か。"
  def retryable_error?(nil), do: true
  def retryable_error?(error), do: error in @retryable_errors

  @doc "一括再引当の対象になる引当エラーの一覧(クエリ用)。"
  def retryable_errors, do: @retryable_errors

  @doc "梱包前(`pending` / `allocated` / `shortage`)か。残件数・数量変更・取消の対象。"
  def unpacked?(%__MODULE__{status: status}), do: status in [:pending, :allocated, :shortage]

  @doc """
  登録用。`attrs` は Context がマスタから計算した値(`total_piece_qty`・`min_expiration_date`・
  `box_count` の初期値など)を含む。状態は `pending`、`created_by_user_id` は呼び出し側が渡す。
  """
  def create_changeset(slip, attrs) do
    slip
    |> cast(attrs, [
      :client_id,
      :shipping_item_id,
      :client_slip_no,
      :scheduled_ship_date,
      :order_count,
      :box_count,
      :total_piece_qty,
      :min_expiration_date,
      :input_source,
      :created_by_user_id
    ])
    |> update_change(:client_slip_no, &blank_to_nil/1)
    |> validate_required([
      :client_id,
      :shipping_item_id,
      :scheduled_ship_date,
      :order_count,
      :box_count,
      :total_piece_qty,
      :input_source,
      :created_by_user_id
    ])
    |> put_change(:status, :pending)
    |> validate_quantities()
    |> validate_length(:client_slip_no, max: 100)
    |> unsafe_validate_unique([:client_id, :client_slip_no, :shipping_item_id], FoodShip.Repo,
      query: active_slip_query(),
      error_key: :client_slip_no,
      message: "はすでに登録されています。"
    )
    |> unique_constraint(:client_slip_no,
      name: :shipping_slips_client_slip_no_active_index,
      message: "はすでに登録されています。"
    )
    |> assoc_constraint(:client)
    |> assoc_constraint(:shipping_item)
  end

  @doc """
  件数・出荷予定日の変更用。`pending` に戻し、引当の結果(不足数・エラー)を消す。
  `inventory_order_id` は旧引当の解除まで残す。
  """
  def update_changeset(slip, attrs) do
    slip
    |> cast(attrs, [
      :scheduled_ship_date,
      :order_count,
      :box_count,
      :total_piece_qty,
      :min_expiration_date
    ])
    |> validate_required([:scheduled_ship_date, :order_count, :box_count, :total_piece_qty])
    |> validate_quantities()
    |> put_change(:status, :pending)
    |> put_change(:shortage_pieces, nil)
    |> put_change(:allocation_error, nil)
  end

  @doc "箱数の修正用(在庫には影響しない)。"
  def box_count_changeset(slip, attrs) do
    slip
    |> cast(attrs, [:box_count])
    |> validate_required([:box_count])
    |> validate_number(:box_count, greater_than_or_equal_to: 1)
    |> check_constraint(:box_count, name: :box_count_positive)
  end

  # 部分ユニークと同じ条件(取消・出庫取消済みを除く)で、既存の有効な伝票を探す
  defp active_slip_query do
    import Ecto.Query

    closed = [:cancelled, :reversed]
    from(s in __MODULE__, where: not is_nil(s.client_slip_no) and s.status not in ^closed)
  end

  defp validate_quantities(changeset) do
    changeset
    |> validate_number(:order_count, greater_than: 0)
    |> validate_number(:box_count, greater_than_or_equal_to: 1)
    |> validate_number(:total_piece_qty, greater_than: 0)
    |> check_constraint(:order_count, name: :order_count_positive)
    |> check_constraint(:box_count, name: :box_count_positive)
    |> check_constraint(:total_piece_qty, name: :total_piece_qty_positive)
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value
end
