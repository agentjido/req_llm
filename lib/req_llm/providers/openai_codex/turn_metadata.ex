defmodule ReqLLM.Providers.OpenAICodex.TurnMetadata do
  @moduledoc false

  @required ~w(turn_id window_id request_kind turn_started_at_unix_ms)
  @optional ~w(installation_id)
  @keys @required ++ @optional

  @doc false
  def validate(value) when is_map(value) do
    entries = Enum.map(value, fn {key, value} -> {normalize_key(key), value} end)
    metadata = Map.new(entries)

    valid? =
      map_size(metadata) == map_size(value) and
        Enum.all?(Map.keys(metadata), &(&1 in @keys)) and
        Enum.all?(@required, &Map.has_key?(metadata, &1)) and
        Enum.all?(metadata, &valid_field?/1)

    if valid?, do: {:ok, metadata}, else: {:error, "invalid Codex turn metadata"}
  end

  def validate(_value), do: {:error, "Codex turn metadata must be a map"}

  @doc false
  def telemetry(options) do
    with {:ok, metadata} <- validate(options[:codex_turn_metadata]),
         true <- valid_identity?(options[:session_id]),
         true <- valid_identity?(options[:thread_id]) do
      %{
        codex_session_id: options[:session_id],
        codex_thread_id: options[:thread_id],
        codex_turn_id: metadata["turn_id"],
        codex_window_id: metadata["window_id"],
        codex_request_kind: metadata["request_kind"],
        codex_turn_started_at_unix_ms: metadata["turn_started_at_unix_ms"],
        codex_installation_id: metadata["installation_id"]
      }
      |> Map.reject(fn {_key, value} -> is_nil(value) end)
    else
      _ -> %{}
    end
  end

  @doc false
  def headers(options) do
    case client_metadata(options) do
      nil ->
        []

      metadata ->
        Map.take(metadata, [
          "x-codex-turn-metadata",
          "x-codex-window-id",
          "x-codex-installation-id"
        ])
        |> Map.to_list()
    end
  end

  @doc false
  def put_body(body, options) do
    case client_metadata(options) do
      nil -> body
      metadata -> Map.put(body, "client_metadata", metadata)
    end
  end

  defp client_metadata(options) do
    case Keyword.fetch(options, :codex_turn_metadata) do
      :error -> nil
      {:ok, value} -> project!(value, options)
    end
  end

  defp project!(value, options) do
    with {:ok, metadata} <- validate(value),
         true <- valid_identity?(options[:session_id]),
         true <- valid_identity?(options[:thread_id]) do
      turn =
        Map.merge(metadata, %{
          "session_id" => options[:session_id],
          "thread_id" => options[:thread_id]
        })

      %{
        "session_id" => options[:session_id],
        "thread_id" => options[:thread_id],
        "turn_id" => turn["turn_id"],
        "x-codex-window-id" => turn["window_id"],
        "x-codex-turn-metadata" => Jason.encode!(turn, escape: :unicode_safe)
      }
      |> maybe_put_installation(turn["installation_id"])
    else
      _ ->
        raise ReqLLM.Error.Invalid.Parameter,
          parameter:
            "codex_turn_metadata requires valid metadata and nonempty ASCII session_id/thread_id"
    end
  end

  defp maybe_put_installation(metadata, nil), do: metadata
  defp maybe_put_installation(metadata, id), do: Map.put(metadata, "x-codex-installation-id", id)

  defp valid_field?({"turn_started_at_unix_ms", value}), do: is_integer(value) and value >= 0
  defp valid_field?({_key, value}), do: valid_identity?(value)

  defp valid_identity?(value) when is_binary(value) and byte_size(value) in 1..256,
    do: Regex.match?(~r/\A[\x21-\x7e]+\z/, value)

  defp valid_identity?(_value), do: false
  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: key
end
