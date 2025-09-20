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
end
