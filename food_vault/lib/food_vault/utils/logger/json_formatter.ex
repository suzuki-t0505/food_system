defmodule FoodVault.Utils.Logger.JSONFormatter do
  @moduledoc """
  本番用の JSON ログフォーマッタ (Erlang `:logger` のフォーマッタ)。1 行 1 JSON で出力する。

      config :logger, :default_handler,
        formatter:
          {FoodVault.Utils.Logger.JSONFormatter,
           metadata: [:request_id, :remote_ip, :mfa, :file, :line]}
  """

  @default_metadata [:request_id, :remote_ip, :mfa, :file, :line]

  @spec check_config(term()) :: :ok | {:error, term()}
  def check_config(config) when is_map(config) or is_list(config), do: :ok
  def check_config(config), do: {:error, {:invalid_formatter_config, config}}

  @spec format(:logger.log_event(), term()) :: iodata()
  def format(%{level: level, msg: msg, meta: meta}, config) do
    keys = metadata_keys(config)

    %{time: format_time(meta[:time]), level: level}
    |> Map.merge(message_fields(msg))
    |> Map.merge(metadata_fields(meta, keys))
    |> encode()
  rescue
    exception ->
      [
        ~s({"level":"error","message":"ログの整形に失敗しました。","reason":),
        inspect(Exception.message(exception)) |> Jason.encode!(),
        "}\n"
      ]
  end

  defp metadata_keys(config) when is_map(config),
    do: Map.get(config, :metadata, @default_metadata)

  defp metadata_keys(config) when is_list(config),
    do: Keyword.get(config, :metadata, @default_metadata)

  defp format_time(nil), do: nil

  defp format_time(microseconds) do
    microseconds |> DateTime.from_unix!(:microsecond) |> DateTime.to_iso8601()
  end

  defp message_fields({:report, %{message: _} = report}) do
    Map.take(report, [:message, :category, :variable])
  end

  defp message_fields({:report, report}), do: %{message: inspect(report)}
  defp message_fields({:string, chardata}), do: %{message: IO.chardata_to_string(chardata)}

  defp message_fields({format, args}) do
    %{message: format |> :io_lib.format(args) |> IO.chardata_to_string()}
  end

  defp metadata_fields(meta, keys) do
    for key <- keys, value = Map.get(meta, key), into: %{} do
      {key, metadata_value(key, value)}
    end
  end

  defp metadata_value(:mfa, {module, function, arity}),
    do: Exception.format_mfa(module, function, arity)

  defp metadata_value(:file, file) when is_list(file), do: List.to_string(file)
  defp metadata_value(_key, value), do: value

  defp encode(map), do: [map |> sanitize() |> Jason.encode_to_iodata!(), ?\n]

  defp sanitize(value) when is_binary(value) do
    if String.valid?(value), do: value, else: inspect(value)
  end

  defp sanitize(value) when is_atom(value) or is_number(value), do: value

  defp sanitize(%{__struct__: _} = struct) do
    if Jason.Encoder.impl_for(struct) in [nil, Jason.Encoder.Any],
      do: inspect(struct),
      else: struct
  end

  defp sanitize(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {sanitize_key(key), sanitize(value)} end)
  end

  defp sanitize(list) when is_list(list), do: Enum.map(list, &sanitize/1)
  defp sanitize(other), do: inspect(other)

  defp sanitize_key(key) when is_binary(key) or is_atom(key), do: key
  defp sanitize_key(key), do: inspect(key)
end
