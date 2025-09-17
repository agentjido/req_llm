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
  Normalizes various prompt formats into a standardized messages list.

  ## Parameters

  - `prompt` - Can be a string, list of messages, or any other type that can be converted to string

  ## Returns

  A list of message maps with `:role` and `:content` keys.

  ## Examples

      iex> ReqLLM.Provider.Utils.normalize_messages("What is the weather?")
      [%{role: "user", content: "What is the weather?"}]

      iex> messages = [%{role: "user", content: "Hello"}, %{role: "assistant", content: "Hi there!"}]
      iex> ReqLLM.Provider.Utils.normalize_messages(messages)
      [%{role: "user", content: "Hello"}, %{role: "assistant", content: "Hi there!"}]

      iex> ReqLLM.Provider.Utils.normalize_messages(123)
      [%{role: "user", content: "123"}]
  """
  @spec normalize_messages(binary() | list() | term()) :: [map()]
  def normalize_messages(prompt) when is_binary(prompt) do
    [%{role: "user", content: prompt}]
  end

  def normalize_messages(messages) when is_list(messages) do
    messages
  end

  def normalize_messages(prompt) do
    [%{role: "user", content: to_string(prompt)}]
  end

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
  Raises an error if unknown options are present.

  ## Parameters

  - `opts` - Options to validate
  - `allowed` - List of allowed option keys

  ## Returns

  The original options if all keys are allowed.

  ## Raises

  `ReqLLM.Error.Invalid.Parameter` if unknown options are found.

  ## Examples

      iex> ReqLLM.Provider.Utils.reject_unknown!([temperature: 0.7], [:temperature, :max_tokens])
      [temperature: 0.7]

      iex> ReqLLM.Provider.Utils.reject_unknown!([bad_key: "value"], [:temperature])
      ** (ReqLLM.Error.Invalid.Parameter) unsupported options: [:bad_key]
  """
  @spec reject_unknown!(keyword(), [atom()]) :: keyword()
  def reject_unknown!(opts, allowed) do
    case Keyword.keys(opts) -- allowed do
      [] ->
        opts

      unknown ->
        raise ReqLLM.Error.Invalid.Parameter.exception(
                parameter: "unsupported options: #{inspect(unknown)}"
              )
    end
  end

  @doc """
  Validates generation options against a subset schema, raising on error.

  ## Parameters

  - `opts` - Options to validate
  - `allowed_keys` - Keys to include in validation schema

  ## Returns

  The validated options.

  ## Raises

  `NimbleOptions.ValidationError` if validation fails.

  ## Examples

      iex> ReqLLM.Provider.Utils.validate_subset!([temperature: 0.7], [:temperature, :max_tokens])
      [temperature: 0.7]
  """
  @spec validate_subset!(keyword(), [atom()]) :: keyword()
  def validate_subset!(opts, allowed_keys) do
    schema = ReqLLM.Provider.Options.generation_subset_schema(allowed_keys)
    NimbleOptions.validate!(opts, schema)
  end

  @doc """
  Adds context to options if present in user options, with type validation.

  ## Parameters

  - `opts` - Current options keyword list
  - `user_opts` - Original user options to check for context

  ## Returns

  Options with context added if present.

  ## Raises

  `ReqLLM.Error.Invalid.Parameter` if context is not a ReqLLM.Context struct.

  ## Examples

      iex> context = %ReqLLM.Context{messages: []}
      iex> ReqLLM.Provider.Utils.maybe_put_context([model: "gpt-4"], [context: context])
      [model: "gpt-4", context: context]
  """
  @spec maybe_put_context(keyword(), keyword()) :: keyword()
  def maybe_put_context(opts, user_opts) do
    case Keyword.get(user_opts, :context) do
      %ReqLLM.Context{} = ctx ->
        Keyword.put(opts, :context, ctx)

      nil ->
        opts

      other ->
        raise ReqLLM.Error.Invalid.Parameter.exception(
                parameter: "context must be ReqLLM.Context, got: #{inspect(other)}"
              )
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
  Prepares provider options using a clean pipeline approach.

  This is the main helper that providers can use to process user options
  into a clean, validated keyword list ready for the Req request.

  ## Parameters

  - `provider_mod` - The provider module (must implement supported_provider_options/0 and default_provider_opts/0)
  - `model` - ReqLLM.Model struct
  - `user_opts` - Raw user options

  ## Returns

  Validated and processed options keyword list.

  ## Examples

      iex> model = %ReqLLM.Model{provider: :anthropic, model: "claude-3-haiku"}
      iex> user_opts = [temperature: 0.7, max_tokens: 1000]
      iex> ReqLLM.Provider.Utils.prepare_options!(MyProvider, model, user_opts)
      [temperature: 0.7, max_tokens: 1000, model: "claude-3-haiku"]
  """
  @spec prepare_options!(module(), ReqLLM.Model.t(), keyword()) :: keyword()
  def prepare_options!(provider_mod, %ReqLLM.Model{} = model, user_opts) do
    user_opts
    |> ReqLLM.Provider.Options.extract_generation_opts()
    |> reject_unknown!(provider_mod.supported_provider_options())
    |> validate_subset!(provider_mod.supported_provider_options())
    |> then(&Keyword.merge(provider_mod.default_provider_opts(), &1))
    |> Keyword.put(:model, model.model)
    |> maybe_put_context(user_opts)
  end
end
