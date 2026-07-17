defmodule ReqLLM.ProviderFileReference do
  @moduledoc """
  Metadata and validation for explicitly provider-owned file references.

  Provider ownership is opt-in. Legacy `ReqLLM.Message.ContentPart.file_id/1`
  values do not contain this metadata and are never inferred to belong to a
  provider.

  Owned references store a versioned record below the reserved
  `"req_llm" -> "provider_file"` metadata namespace. Use
  `ReqLLM.Message.ContentPart.owned_file_id/3` to create one.
  """

  alias ReqLLM.Message.ContentPart

  @namespace "req_llm"
  @metadata_key "provider_file"
  @redacted "[REDACTED]"
  @allowed_options [:purpose, :status, :expires_at, :size, :sha256, :provider_metadata]
  @known_key_atoms %{
    "schema_version" => :schema_version,
    "provider" => :provider,
    "reference_id" => :reference_id,
    "purpose" => :purpose,
    "status" => :status,
    "expires_at" => :expires_at,
    "size" => :size,
    "sha256" => :sha256,
    "metadata" => :metadata
  }
  @sensitive_keys ~w(
    access_token api_key api_token authorization credential credentials data file_id password
    reference_id secret token url
  )

  @type t :: %{
          required(String.t()) => term()
        }

  @doc "Returns the reserved metadata path used for provider-owned files."
  @spec metadata_path() :: [String.t()]
  def metadata_path, do: [@namespace, @metadata_key]

  @doc false
  @spec new!(atom() | String.t(), String.t(), keyword()) :: t()
  def new!(provider, reference_id, opts \\ [])

  def new!(provider, reference_id, opts)
      when (is_atom(provider) or is_binary(provider)) and is_binary(reference_id) and
             is_list(opts) do
    validate_options!(opts)

    normalized_provider = normalize_provider!(provider)
    normalized_reference_id = non_empty_string!(reference_id, :reference_id)

    %{
      "schema_version" => 1,
      "provider" => normalized_provider,
      "reference_id" => normalized_reference_id
    }
    |> put_optional("purpose", normalize_label!(opts[:purpose], :purpose))
    |> put_optional("status", normalize_label!(opts[:status], :status))
    |> put_optional("expires_at", normalize_expiry!(opts[:expires_at]))
    |> put_optional("size", normalize_size!(opts[:size]))
    |> put_optional("sha256", normalize_sha256!(opts[:sha256]))
    |> put_optional("metadata", normalize_metadata!(opts[:provider_metadata]))
  end

  def new!(_provider, _reference_id, _opts) do
    raise ArgumentError,
          "provider-owned file references require a provider, non-empty reference ID, and keyword options"
  end

  @doc false
  @spec put(map(), t()) :: map()
  def put(metadata, reference) when is_map(metadata) and is_map(reference) do
    namespace = Map.get(metadata, @namespace, %{})

    unless is_map(namespace) do
      raise ArgumentError, "reserved #{@namespace} content metadata must be a map"
    end

    Map.put(metadata, @namespace, Map.put(namespace, @metadata_key, reference))
  end

  @doc "Returns the full ownership record for an explicitly owned file."
  @spec fetch(ContentPart.t() | map()) :: {:ok, t()} | :error
  def fetch(%ContentPart{type: :file, metadata: metadata}), do: fetch_metadata(metadata)

  def fetch(%{type: type} = part) when type in [:file, "file"] do
    fetch_metadata(Map.get(part, :metadata) || Map.get(part, "metadata") || %{})
  end

  def fetch(%{"type" => "file"} = part) do
    fetch_metadata(Map.get(part, "metadata") || Map.get(part, :metadata) || %{})
  end

  def fetch(_part), do: :error

  @doc "Returns whether a content part was explicitly marked as provider-owned."
  @spec owned?(ContentPart.t() | map()) :: boolean()
  def owned?(part), do: match?({:ok, _reference}, fetch(part))

  @doc "Returns a redacted ownership record suitable for logs and diagnostics."
  @spec redacted(ContentPart.t() | map()) :: {:ok, t()} | :error
  def redacted(part) do
    case fetch(part) do
      {:ok, reference} -> {:ok, redact(reference)}
      :error -> :error
    end
  end

  @doc false
  @spec reference_id(ContentPart.t() | map(), atom() | String.t() | nil) ::
          {:ok, String.t()} | :error
  def reference_id(part, provider \\ nil) do
    with {:ok, reference} <- fetch(part),
         true <- provider_matches?(reference, provider),
         reference_id when is_binary(reference_id) and reference_id != "" <-
           get_value(reference, "reference_id") do
      {:ok, reference_id}
    else
      _other -> :error
    end
  end

  @doc false
  @spec validate_context(ReqLLM.Context.t(), atom() | String.t(), keyword()) ::
          :ok | {:error, ReqLLM.Error.Invalid.ProviderFileReference.t()}
  def validate_context(context, provider, opts \\ [])

  def validate_context(%ReqLLM.Context{messages: messages}, provider, opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    messages
    |> Enum.flat_map(fn message -> List.wrap(Map.get(message, :content, [])) end)
    |> Enum.reduce_while(:ok, fn part, :ok ->
      case validate_part(part, provider, now) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  def validate_context(_context, _provider, _opts), do: :ok

  @doc false
  @spec sanitize_content_part(ContentPart.t()) :: map()
  def sanitize_content_part(%ContentPart{} = part) do
    case redacted(part) do
      {:ok, reference} ->
        %{
          type: :file,
          file_id: @redacted,
          filename: part.filename,
          media_type: part.media_type,
          bytes: binary_size_or_nil(part.data),
          metadata: %{@namespace => %{@metadata_key => reference}}
        }

      :error ->
        %{
          type: :file,
          file_id: part.file_id,
          filename: part.filename,
          media_type: part.media_type,
          bytes: binary_size_or_nil(part.data),
          metadata: part.metadata
        }
    end
  end

  defp fetch_metadata(metadata) when is_map(metadata) do
    with namespace when is_map(namespace) <-
           Map.get(metadata, @namespace) || Map.get(metadata, :req_llm),
         reference when is_map(reference) <-
           Map.get(namespace, @metadata_key) || Map.get(namespace, :provider_file),
         provider when is_binary(provider) and provider != "" <- get_value(reference, "provider"),
         reference_id when is_binary(reference_id) and reference_id != "" <-
           get_value(reference, "reference_id") do
      {:ok,
       reference
       |> stringify_known_keys()
       |> Map.put("provider", provider)
       |> Map.put("reference_id", reference_id)}
    else
      _other -> :error
    end
  end

  defp fetch_metadata(_metadata), do: :error

  defp stringify_known_keys(reference) do
    Enum.reduce(@known_key_atoms, reference, fn {key, atom_key}, acc ->
      case Map.fetch(acc, atom_key) do
        {:ok, value} -> acc |> Map.delete(atom_key) |> Map.put(key, value)
        :error -> acc
      end
    end)
  end

  defp validate_part(part, provider, now) do
    case fetch(part) do
      {:ok, reference} -> validate_reference(reference, provider, now)
      :error -> :ok
    end
  end

  defp validate_reference(reference, provider, now) do
    owner = get_value(reference, "provider")
    expected_provider = normalize_provider!(provider)

    cond do
      owner != expected_provider ->
        {:error,
         ReqLLM.Error.Invalid.ProviderFileReference.exception(
           reason: :provider_mismatch,
           owner: owner,
           provider: expected_provider,
           expires_at: get_value(reference, "expires_at"),
           status: get_value(reference, "status")
         )}

      expired?(get_value(reference, "expires_at"), now) ->
        {:error,
         ReqLLM.Error.Invalid.ProviderFileReference.exception(
           reason: :expired,
           owner: owner,
           provider: expected_provider,
           expires_at: get_value(reference, "expires_at"),
           status: get_value(reference, "status")
         )}

      true ->
        :ok
    end
  end

  defp provider_matches?(_reference, nil), do: true

  defp provider_matches?(reference, provider) do
    get_value(reference, "provider") == normalize_provider!(provider)
  end

  defp expired?(nil, _now), do: false

  defp expired?(expires_at, %DateTime{} = now) when is_binary(expires_at) do
    case DateTime.from_iso8601(expires_at) do
      {:ok, expiry, _offset} -> DateTime.compare(expiry, now) != :gt
      _invalid -> false
    end
  end

  defp expired?(_expires_at, _now), do: false

  defp redact(reference) do
    reference
    |> Map.put("reference_id", @redacted)
    |> Map.update("metadata", nil, &sanitize_value/1)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp sanitize_value(value) when is_map(value) do
    Map.new(value, fn {key, entry} ->
      if sensitive_key?(key), do: {key, @redacted}, else: {key, sanitize_value(entry)}
    end)
  end

  defp sanitize_value(value) when is_list(value), do: Enum.map(value, &sanitize_value/1)

  defp sanitize_value(value) when is_binary(value) do
    if String.starts_with?(value, ["http://", "https://", "gs://"]), do: @redacted, else: value
  end

  defp sanitize_value(value), do: value

  defp sensitive_key?(key) when is_atom(key) or is_binary(key) do
    key
    |> to_string()
    |> String.downcase()
    |> then(fn name ->
      name in @sensitive_keys or String.contains?(name, "credential") or
        String.contains?(name, "secret") or String.ends_with?(name, "_token")
    end)
  end

  defp sensitive_key?(_key), do: false

  defp validate_options!(opts) do
    unless Keyword.keyword?(opts) do
      raise ArgumentError, "provider-owned file options must be a keyword list"
    end

    case Keyword.keys(opts) -- @allowed_options do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown provider-owned file options: #{inspect(unknown)}"
    end
  end

  defp normalize_provider!(provider) do
    provider
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> non_empty_string!(:provider)
  end

  defp non_empty_string!(value, _field) when is_binary(value) and value != "", do: value

  defp non_empty_string!(_value, field) do
    raise ArgumentError, "#{field} must be a non-empty string"
  end

  defp normalize_label!(nil, _field), do: nil
  defp normalize_label!(value, _field) when is_atom(value), do: Atom.to_string(value)

  defp normalize_label!(value, field) when is_binary(value) do
    value |> String.trim() |> non_empty_string!(field)
  end

  defp normalize_label!(_value, field) do
    raise ArgumentError, "#{field} must be an atom or non-empty string"
  end

  defp normalize_expiry!(nil), do: nil
  defp normalize_expiry!(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp normalize_expiry!(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, date_time, _offset} -> DateTime.to_iso8601(date_time)
      _invalid -> raise ArgumentError, "expires_at must be an ISO 8601 UTC timestamp"
    end
  end

  defp normalize_expiry!(_value) do
    raise ArgumentError, "expires_at must be a DateTime or ISO 8601 timestamp"
  end

  defp normalize_size!(nil), do: nil
  defp normalize_size!(value) when is_integer(value) and value >= 0, do: value
  defp normalize_size!(_value), do: raise(ArgumentError, "size must be a non-negative integer")

  defp normalize_sha256!(nil), do: nil

  defp normalize_sha256!(value) when is_binary(value) do
    value |> String.trim() |> non_empty_string!(:sha256)
  end

  defp normalize_sha256!(_value), do: raise(ArgumentError, "sha256 must be a non-empty string")

  defp normalize_metadata!(nil), do: nil
  defp normalize_metadata!(value) when is_map(value), do: normalize_metadata_value!(value)
  defp normalize_metadata!(_value), do: raise(ArgumentError, "provider_metadata must be a map")

  defp normalize_metadata_value!(value) when is_map(value) do
    Map.new(value, fn {key, entry} ->
      {normalize_metadata_key!(key), normalize_metadata_value!(entry)}
    end)
  end

  defp normalize_metadata_value!(value) when is_list(value) do
    Enum.map(value, &normalize_metadata_value!/1)
  end

  defp normalize_metadata_value!(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: value

  defp normalize_metadata_value!(value) when is_atom(value), do: Atom.to_string(value)

  defp normalize_metadata_value!(_value) do
    raise ArgumentError, "provider_metadata values must be JSON-safe"
  end

  defp normalize_metadata_key!(key) when is_binary(key), do: key
  defp normalize_metadata_key!(key) when is_atom(key), do: Atom.to_string(key)

  defp normalize_metadata_key!(_key) do
    raise ArgumentError, "provider_metadata keys must be atoms or strings"
  end

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp get_value(map, key) do
    Map.get(map, key) || Map.get(map, Map.fetch!(@known_key_atoms, key))
  end

  defp binary_size_or_nil(nil), do: nil
  defp binary_size_or_nil(data) when is_binary(data), do: byte_size(data)
  defp binary_size_or_nil(data) when is_list(data), do: IO.iodata_length(data)
  defp binary_size_or_nil(_data), do: nil
end
