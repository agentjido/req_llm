defmodule ReqLLM.Provider.Utils do
  @moduledoc """
  Shared utilities for provider implementations.

  Contains common functions used across multiple providers to eliminate
  duplication and ensure consistency.

  ## Examples

      iex> ReqLLM.Provider.Utils.normalize_messages("Hello world")
      [%{role: "user", content: "Hello world"}]

      iex> messages = [%{role: "user", content: "Hi"}]
      iex> ReqLLM.Provider.Utils.normalize_messages(messages)
      [%{role: "user", content: "Hi"}]
  """

  @doc """
  Conditionally puts a value into a keyword list or map if the value is not nil.

  ## Parameters

  - `opts` - Keyword list or map to potentially modify
  - `key` - Key to add
  - `value` - Value to add (if not nil)

  ## Returns

  The keyword list or map, with key-value pair added if value is not nil.

  ## Examples

      iex> ReqLLM.Provider.Utils.maybe_put([], :name, "John")
      [name: "John"]

      iex> ReqLLM.Provider.Utils.maybe_put(%{}, :name, "John")
      %{name: "John"}

      iex> ReqLLM.Provider.Utils.maybe_put([], :name, nil)
      []

      iex> ReqLLM.Provider.Utils.maybe_put(%{}, :name, nil)
      %{}
  """
  @spec maybe_put(keyword() | map(), atom(), term()) :: keyword() | map()
  def maybe_put(opts, _key, nil), do: opts
  def maybe_put(opts, key, value) when is_list(opts), do: Keyword.put(opts, key, value)
  def maybe_put(opts, key, value) when is_map(opts), do: Map.put(opts, key, value)

  @doc """
  Conditionally adds a key-value pair to opts, skipping if value is nil or in skip_values list.

  This is useful for providers that need to omit certain default values from API requests.

  ## Parameters

  - `opts` - Options map or keyword list to update
  - `key` - Key to add
  - `value` - Value to add (will be skipped if nil or in skip_values)
  - `skip_values` - List of values to skip (defaults to [])

  ## Examples

      iex> ReqLLM.Provider.Utils.maybe_put_skip(%{}, :service_tier, "auto", ["auto"])
      %{}

      iex> ReqLLM.Provider.Utils.maybe_put_skip(%{}, :service_tier, "performance", ["auto"])
      %{service_tier: "performance"}

      iex> ReqLLM.Provider.Utils.maybe_put_skip(%{}, :key, nil, [])
      %{}
  """
  @spec maybe_put_skip(keyword() | map(), atom(), term(), list()) :: keyword() | map()
  def maybe_put_skip(opts, key, value, skip_values) do
    if is_nil(value) or value in skip_values do
      opts
    else
      maybe_put(opts, key, value)
    end
  end

  @doc """
  Ensures the response body is parsed from JSON if it's binary.

  Common utility for providers to ensure they have parsed JSON data
  instead of raw binary response bodies.

  ## Parameters

  - `body` - Response body that may be binary JSON or already parsed

  ## Returns

  Parsed body (map/list) or original body if parsing fails.

  ## Examples

      iex> ReqLLM.Provider.Utils.ensure_parsed_body(~s({"message": "hello"}))
      %{"message" => "hello"}

      iex> ReqLLM.Provider.Utils.ensure_parsed_body(%{"already" => "parsed"})
      %{"already" => "parsed"}

      iex> ReqLLM.Provider.Utils.ensure_parsed_body("invalid json")
      "invalid json"
  """
  @spec ensure_parsed_body(term()) :: term()
  def ensure_parsed_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, parsed} -> parsed
      {:error, _} -> body
    end
  end

  def ensure_parsed_body(body), do: body

  @doc """
  Converts atom keys in a map to string keys.

  Useful for normalizing maps that may have atom or string keys to ensure
  consistent access patterns. Only converts top-level keys.

  ## Parameters

  - `map` - Map with atom and/or string keys

  ## Returns

  Map with all keys as strings.

  ## Examples

      iex> ReqLLM.Provider.Utils.stringify_keys(%{foo: "bar", "baz" => "qux"})
      %{"foo" => "bar", "baz" => "qux"}

      iex> ReqLLM.Provider.Utils.stringify_keys(%{"already" => "strings"})
      %{"already" => "strings"}
  """
  @spec stringify_keys(map()) :: map()
  def stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  @doc """
  Recursively converts map keys to strings.
  """
  @spec stringify_keys_deep(term()) :: term()
  def stringify_keys_deep(%_{} = struct), do: struct

  def stringify_keys_deep(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      key = if is_atom(k), do: Atom.to_string(k), else: k
      {key, stringify_keys_deep(v)}
    end)
  end

  def stringify_keys_deep(list) when is_list(list) do
    Enum.map(list, &stringify_keys_deep/1)
  end

  def stringify_keys_deep(value), do: value

  @sensitive_query_params ~w(key api_key apikey access_token token)

  @doc """
  Sanitizes a URL by redacting sensitive query parameters.

  This prevents API keys and tokens from being leaked in logs or error messages.
  Redacts common sensitive parameter names: key, api_key, apikey, access_token, token.

  ## Parameters

  - `url` - URL string that may contain sensitive query parameters

  ## Returns

  URL string with sensitive parameters redacted as `[REDACTED]`.

  ## Examples

      iex> ReqLLM.Provider.Utils.sanitize_url("https://api.example.com/v1?key=secret123&alt=sse")
      "https://api.example.com/v1?key=[REDACTED]&alt=sse"

      iex> ReqLLM.Provider.Utils.sanitize_url("https://api.example.com/v1")
      "https://api.example.com/v1"

      iex> ReqLLM.Provider.Utils.sanitize_url("https://api.example.com/v1?api_key=abc&format=json")
      "https://api.example.com/v1?api_key=[REDACTED]&format=json"
  """
  @spec sanitize_url(binary()) :: binary()
  def sanitize_url(url) when is_binary(url) do
    uri = URI.parse(url)

    if uri.query do
      sanitized_query =
        URI.decode_query(uri.query)
        |> Enum.map_join("&", fn {k, v} ->
          if String.downcase(k) in @sensitive_query_params do
            "#{URI.encode_www_form(k)}=[REDACTED]"
          else
            "#{URI.encode_www_form(k)}=#{URI.encode_www_form(v)}"
          end
        end)

      %{uri | query: sanitized_query} |> URI.to_string()
    else
      url
    end
  end

  def sanitize_url(url), do: url

  @doc """
  Extracts custom headers from req_http_options for use in streaming requests.

  The req_http_options keyword list may contain a :headers key with a list of
  header tuples. This function extracts those headers for use when building
  Finch requests for streaming.

  ## Parameters

  - `req_http_options` - Keyword list of HTTP options (may contain :headers)

  ## Returns

  List of header tuples {name, value} to be added to the request.

  ## Examples

      iex> ReqLLM.Provider.Utils.extract_custom_headers([])
      []

      iex> ReqLLM.Provider.Utils.extract_custom_headers(headers: [{"X-Custom", "value"}])
      [{"X-Custom", "value"}]

      iex> ReqLLM.Provider.Utils.extract_custom_headers(headers: [{"X-Custom", "value"}], timeout: 5000)
      [{"X-Custom", "value"}]
  """
  @spec extract_custom_headers(keyword() | map() | nil) :: [{binary(), binary()}]
  def extract_custom_headers(nil), do: []

  def extract_custom_headers(req_http_options) when is_list(req_http_options) do
    case Keyword.get(req_http_options, :headers) do
      headers when is_list(headers) -> headers
      _ -> []
    end
  end

  def extract_custom_headers(req_http_options) when is_map(req_http_options) do
    case Map.get(req_http_options, :headers) do
      headers when is_list(headers) -> headers
      _ -> []
    end
  end

  def extract_custom_headers(_), do: []
end
