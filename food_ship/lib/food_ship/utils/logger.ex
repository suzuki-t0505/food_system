defmodule FoodShip.Utils.Logger do
  @moduledoc """
  カテゴリ付きの Logger ラッパー。

  `require Logger` で Elixir 純正の Logger を直接使わず、このモジュールを使う。

      use FoodShip.Utils.Logger

      Logger.info("在庫 API を呼び出しました。", :api, %{path: path})

  - カテゴリは `@categories` に定義したものだけを使う。増やすときはここに足す
  - 未定義カテゴリは `raise_on_unknown_category: true` (dev / test) のとき `ArgumentError`
  - 変数は `normalize/1` を通すため、`redact: true` のフィールドや `password` / `token` は出力されない
  """

  alias Ecto.Association.NotLoaded

  @categories %{
    log_in: "ログイン",
    create: "作成",
    update: "更新",
    delete: "削除",
    batch: "定期実行",
    api: "API",
    other: "その他"
  }

  # redact: true を付けていない機微フィールドを新設したら、ここに足す
  @redact_keys [:token, :password, :hashed_password, :current_password, :encode_password]
  @redact_key_strings Enum.map(@redact_keys, &Atom.to_string/1)

  defmacro __using__(_opts) do
    quote do
      require FoodShip.Utils.Logger, as: Logger
    end
  end

  for level <- [:info, :warning, :error] do
    @doc "`#{level}` レベルでカテゴリ付きのログを出す。"
    defmacro unquote(level)(message, category, variables) do
      level = unquote(level)
      mod = __MODULE__

      quote do
        require Elixir.Logger

        Elixir.Logger.unquote(level)(%{
          message: unquote(message),
          category: unquote(mod).category_name!(unquote(category)),
          variable: unquote(mod).normalize(unquote(variables))
        })
      end
    end
  end

  @doc """
  カテゴリの表示名を返す。

  未定義のカテゴリは、`raise_on_unknown_category: true` なら `ArgumentError`、
  そうでなければカテゴリ名の文字列をそのまま返す。
  """
  @spec category_name!(atom()) :: String.t()
  def category_name!(category) do
    case Map.fetch(@categories, category) do
      {:ok, name} ->
        name

      :error ->
        if raise_on_unknown_category?() do
          raise ArgumentError, "ログのカテゴリ #{inspect(category)} は定義されていません。"
        else
          inspect(category)
        end
    end
  end

  @doc """
  ログに出せない値を取り除く。

  - Ecto スキーマ: `__meta__`、`redact: true`、仮想フィールド、未ロードのアソシエーション
  - Ecto.Changeset: 上と同じ規則で `changes` と `data` を整形
  - マップ・キーワード: `@redact_keys` のキー (atom・文字列)
  """
  @spec normalize(term()) :: term()
  def normalize(%NotLoaded{}), do: nil

  def normalize(%Ecto.Changeset{} = changeset) do
    %{
      valid?: changeset.valid?,
      changes: changeset.changes |> drop_schema_fields(changeset.data) |> normalize(),
      data: normalize(changeset.data),
      error_fields: Keyword.keys(changeset.errors)
    }
  end

  def normalize(%{__struct__: module, __meta__: %Ecto.Schema.Metadata{}} = struct) do
    struct
    |> Map.from_struct()
    |> Map.delete(:__meta__)
    |> drop_schema_fields(struct)
    |> normalize()
    |> Map.put(:__schema__, inspect(module))
  end

  def normalize(%{__struct__: _} = struct), do: struct

  def normalize(map) when is_map(map) do
    map
    |> Enum.reject(fn {key, value} -> redact_key?(key) or match?(%NotLoaded{}, value) end)
    |> Map.new(fn {key, value} -> {key, normalize(value)} end)
  end

  def normalize(list) when is_list(list) do
    list
    |> Enum.reject(&redact_pair?/1)
    |> Enum.map(&normalize/1)
  end

  def normalize(tuple) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.map(&normalize/1) |> List.to_tuple()
  end

  def normalize(other), do: other

  defp redact_pair?({key, _value}), do: redact_key?(key)
  defp redact_pair?(_other), do: false

  defp redact_key?(key) when is_atom(key), do: key in @redact_keys
  defp redact_key?(key) when is_binary(key), do: key in @redact_key_strings
  defp redact_key?(_key), do: false

  defp drop_schema_fields(map, %{__struct__: module}) do
    if function_exported?(module, :__schema__, 1) do
      Map.drop(map, module.__schema__(:redact_fields) ++ module.__schema__(:virtual_fields))
    else
      map
    end
  end

  defp raise_on_unknown_category? do
    Application.get_env(:food_ship, __MODULE__, [])[:raise_on_unknown_category] == true
  end
end
