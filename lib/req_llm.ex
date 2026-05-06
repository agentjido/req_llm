defmodule ReqLLM do
  @moduledoc """
  Main API facade for Req AI.

  Inspired by the Vercel AI SDK, provides a unified interface to AI providers with
  flexible model specifications, rich prompt support, configuration management,
  and structured data generation.

  ## Quick Start

      # Simple text generation using string format
      ReqLLM.generate_text("anthropic:claude-3-5-sonnet", "Hello world")
      #=> {:ok, "Hello! How can I assist you today?"}

      # Structured data generation with schema validation
      schema = [
        name: [type: :string, required: true],
        age: [type: :pos_integer, required: true]
      ]
      ReqLLM.generate_object("anthropic:claude-3-5-sonnet", "Generate a person", schema)
      #=> {:ok, %{name: "John Doe", age: 30}}

  ## Model Specifications

  Multiple formats supported for maximum flexibility:

      # String format: "provider:model"
      ReqLLM.generate_text("anthropic:claude-sonnet-4-5-20250929", messages)

      # Tuple format: {provider, options}
      ReqLLM.generate_text({:anthropic, id: "claude-3-5-sonnet"}, messages)

      # Model struct format
      model = ReqLLM.model!("anthropic:claude-3-5-sonnet")
      ReqLLM.generate_text(model, messages)

      # Inline model format for models not yet in LLMDB
      model =
        ReqLLM.model!(%{
          provider: :openai,
          id: "gpt-6-mini",
          base_url: "http://localhost:8000/v1",
          extra: %{openai_compatible_backend: :ollama}
        })

      ReqLLM.generate_text(model, messages)

  ## Configuration

  ReqLLM loads API keys from standard sources in order of precedence:

  1. Per-request `:api_key` option
  2. Application config: `config :req_llm, :anthropic_api_key, "..."`
  3. System environment: `ANTHROPIC_API_KEY` (loaded from .env via dotenvy)

  The recommended approach is to use a .env file:

      # .env
      ANTHROPIC_API_KEY=sk-ant-...
      OPENAI_API_KEY=sk-...

  Keys are automatically loaded at startup via dotenvy.

  For programmatic key management:

      # Store keys (uses Application config)
      ReqLLM.put_key(:anthropic_api_key, "sk-ant-...")

      # Retrieve keys
      ReqLLM.get_key(:anthropic_api_key)
      ReqLLM.get_key("ANTHROPIC_API_KEY")

  ## Providers

  Built-in support for major AI providers:

  - **Anthropic**: Claude 3.5 Sonnet, Claude 3 Haiku, Claude 3 Opus

      # Access provider modules directly
      provider = ReqLLM.provider(:anthropic)
      provider.generate_text(model, messages, opts)
  """

  alias ReqLLM.{
    Availability,
    Embedding,
    Generation,
    Images,
    MapAccess,
    OCR,
    Rerank,
    Schema,
    Speech,
    Tool,
    Transcription
  }

  @typedoc """
  Model input accepted by ReqLLM public APIs.

  Strings and tuples resolve through the LLMDB catalog. `%LLMDB.Model{}` values and
  plain maps are treated as inline model specs and bypass catalog lookup.
  """
  @type model_input ::
          String.t()
          | map()
          | {atom(), String.t(), keyword()}
          | {atom(), keyword()}
          | LLMDB.Model.t()

  @inline_model_example "%{provider: :openai, id: \"gpt-4o\"}"
  @inline_model_fields LLMDB.Model.__struct__(provider: :openai, id: "__inline__")
                       |> Map.from_struct()
                       |> Map.keys()
  @inline_model_field_strings Enum.map(@inline_model_fields, &Atom.to_string/1)
  @google_long_context_threshold 200_000
  @google_tiered_token_pricing %{
    "gemini-2.5-computer-use-preview-10-2025" => %{
      input: {1.25, 2.5},
      output: {10.0, 15.0}
    },
    "gemini-2.5-pro" => %{
      input: {1.25, 2.5},
      output: {10.0, 15.0},
      cache_read: {0.125, 0.25}
    },
    "gemini-3.1-pro-preview" => %{
      input: {2.0, 4.0},
      output: {12.0, 18.0},
      cache_read: {0.2, 0.4}
    },
    "gemini-3.1-pro-preview-customtools" => %{
      input: {2.0, 4.0},
      output: {12.0, 18.0},
      cache_read: {0.2, 0.4}
    }
  }

  # ===========================================================================
  # Configuration API
  # ===========================================================================

  @doc """
  Stores an API key in application configuration.

  Keys from .env files are automatically loaded via dotenvy at startup.
  This function is useful for programmatic key management in tests or at runtime.

  ## Parameters

    * `key` - The configuration key (atom)
    * `value` - The value to store

  ## Examples

      ReqLLM.put_key(:anthropic_api_key, "sk-ant-...")

  """
  @spec put_key(atom(), term()) :: :ok
  def put_key(key, value) when is_atom(key) do
    Application.put_env(:req_llm, key, value)
    :ok
  end

  def put_key(_key, _value) do
    raise ArgumentError, "put_key/2 expects an atom key like :anthropic_api_key"
  end

  @doc """
  Gets an API key from application config or system environment.

  Keys from .env files are automatically loaded via dotenvy at startup.

  ## Parameters

    * `key` - The configuration key (atom or string)

  ## Examples

      ReqLLM.get_key(:anthropic_api_key)
      ReqLLM.get_key("ANTHROPIC_API_KEY")  # Auto-loaded from .env

  """
  @spec get_key(atom() | String.t()) :: String.t() | nil
  def get_key(key) when is_atom(key), do: Application.get_env(:req_llm, key)
  def get_key(key) when is_binary(key), do: System.get_env(key)

  @doc """
  Creates a context from a list of messages, a single message struct, or a string.

  ## Parameters

    * `messages` - List of Message structs, a single Message struct, or a string

  ## Examples

      messages = [
        ReqLLM.Context.system("You are helpful"),
        ReqLLM.Context.user("Hello!")
      ]
      ctx = ReqLLM.context(messages)
      # Now you can use Enum functions on the context
      user_msgs = ctx |> Enum.filter(&(&1.role == :user))

      # Single message struct
      ctx = ReqLLM.context(ReqLLM.Context.user("Hello!"))

      # String prompt
      ctx = ReqLLM.context("Hello!")

  """
  @spec context([struct()] | struct() | String.t()) :: ReqLLM.Context.t()
  def context(message_list) when is_list(message_list) do
    ReqLLM.Context.new(message_list)
  end

  def context(%ReqLLM.Message{} = message) do
    ReqLLM.Context.new([message])
  end

  def context(prompt) when is_binary(prompt) do
    ReqLLM.Context.new([ReqLLM.Context.user(prompt)])
  end

  @doc """
  Gets a provider module from the registry.

  ## Parameters

    * `provider` - Provider identifier (atom)

  ## Examples

      ReqLLM.provider(:anthropic)
      #=> {:ok, ReqLLM.Providers.Anthropic}

      ReqLLM.provider(:unknown)
      #=> {:error, %ReqLLM.Error.Invalid.Provider{provider: :unknown}}

  """
  @spec provider(atom()) ::
          {:ok, module()}
          | {:error,
             ReqLLM.Error.Invalid.Provider.t() | ReqLLM.Error.Invalid.Provider.NotImplemented.t()}
  def provider(provider) when is_atom(provider) do
    ReqLLM.Providers.get(provider)
  end

  @doc """
  Creates a model struct from various specifications.

  ## Parameters

    * `model_spec` - Model specification in various formats:
      - String format: `"anthropic:claude-3-sonnet"` (looks up in LLMDB catalog)
      - Map format: `%{id: "my-model", provider: :my_provider}` (inline model spec)
      - Tuple format: `{:anthropic, "claude-3-sonnet", temperature: 0.7}`
      - Model struct: `%LLMDB.Model{}`

  ## Inline Models

  For models not in the LLMDB catalog yet, use an inline model spec:

      model =
        ReqLLM.model!(%{
          id: "acme-chat-mini",
          provider: :acme,
          base_url: "http://localhost:4000/v1"
        })

      ReqLLM.generate_text(model, "Hello!")

  This bypasses catalog lookup, enriches the model metadata, and returns `%LLMDB.Model{}`.
  Inline maps are accepted for backwards compatibility, but `model!/1` is the recommended
  entry point for advanced workflows because it validates the spec up front.

  ## Examples

      ReqLLM.model("anthropic:claude-3-sonnet")
      #=> {:ok, %LLMDB.Model{provider: :anthropic, model: "claude-3-sonnet"}}

      ReqLLM.model(%{id: "custom-model", provider: :my_provider})
      #=> {:ok, %LLMDB.Model{provider: :my_provider, id: "custom-model"}}

      ReqLLM.model!({:anthropic, id: "claude-3-sonnet"})
      #=> %LLMDB.Model{provider: :anthropic, model: "claude-3-sonnet"}

  """
  @spec model(model_input()) :: {:ok, LLMDB.Model.t()} | {:error, term()}
  def model(%LLMDB.Model{} = model) do
    model
    |> Map.from_struct()
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> LLMDB.Enrich.enrich_model()
    |> LLMDB.Model.new()
    |> normalize_model_result()
  end

  def model(%{} = attrs) when not is_struct(attrs) do
    case normalize_inline_model_attrs(attrs) do
      {:ok, normalized_attrs} ->
        normalized_attrs
        |> LLMDB.Enrich.enrich_model()
        |> LLMDB.Model.new()
        |> normalize_inline_model_result(normalized_attrs)

      {:error, _} = error ->
        error
    end
  end

  def model({provider, model_id, _opts}) when is_atom(provider) and is_binary(model_id) do
    provider
    |> resolve_catalog_model(model_id)
    |> normalize_model_result()
  end

  def model({provider, kw}) when is_atom(provider) and is_list(kw) do
    case kw[:id] || kw[:model] do
      id when is_binary(id) ->
        provider
        |> resolve_catalog_model(id)
        |> normalize_model_result()

      _ ->
        {:error, ReqLLM.Error.Invalid.Parameter.exception(parameter: :model, value: kw)}
    end
  end

  def model(spec) when is_binary(spec) do
    case LLMDB.model(spec) do
      {:ok, %LLMDB.Model{} = model} ->
        {:ok, model}
        |> maybe_restore_inference_prefix(spec)
        |> normalize_model_result()

      {:error, _reason} = error ->
        spec
        |> resolve_string_model_fallback(error)
        |> normalize_model_result()
    end
  end

  def model(other) do
    {:error,
     ReqLLM.Error.Validation.Error.exception(message: "Invalid model spec: #{inspect(other)}")}
  end

  @doc """
  Same as `model/1` but raises on error.

  This is the recommended entry point for advanced inline model workflows because it
  validates and normalizes the model spec up front.
  """
  @spec model!(model_input()) :: LLMDB.Model.t() | no_return()
  def model!(model_spec) do
    case model(model_spec) do
      {:ok, model} -> model
      {:error, error} -> raise error
    end
  end

  @doc """
  Returns catalog model specs for providers that are currently configured.

  This is intended for building model selectors or narrowing choices to providers
  that have usable credentials in the current environment or application config.

  The result is filtered by provider availability first, then by the supplied
  LLMDB query options.

  ## Options

    * `:scope` - Restrict results to a specific provider, or use `:all` (default)
    * `:prefer` - Preferred provider ordering, forwarded to `LLMDB.Query.candidates/1`
    * `:require` - Required capability filters, forwarded to `LLMDB.Query.candidates/1`
    * `:forbid` - Forbidden capability filters, forwarded to `LLMDB.Query.candidates/1`
    * `:provider_options` - Optional auth-related provider settings for scoped discovery

  ## Examples

      ReqLLM.available_models()
      #=> ["openai:gpt-4o", "anthropic:claude-3-5-sonnet-20240620", ...]

      ReqLLM.available_models(scope: :openai, require: [embeddings: true])
      #=> ["openai:text-embedding-3-small", "openai:text-embedding-3-large", ...]

  """
  @spec available_models(keyword()) :: [String.t()]
  defdelegate available_models(opts \\ []), to: Availability

  defp normalize_model_result({:ok, %LLMDB.Model{} = model}),
    do: {:ok, normalize_model_metadata(model)}

  defp normalize_model_result(other), do: other

  # Bedrock cross-region inference profile prefixes.
  # These are stripped by LLMDB during catalog lookup but must be preserved
  # in API URLs for models that only support inference profiles (not on-demand).
  @bedrock_inference_prefixes ~w(us eu ap apac ca au jp us-gov global)

  # When a Bedrock model is resolved from a spec like "amazon_bedrock:global.anthropic.claude-opus-4-6-v1",
  # the LLMDB catalog lookup strips the inference profile prefix for matching.
  # This function detects that specific case and restores the original prefixed
  # model ID as provider_model_id so it's used in API URL construction.
  #
  # Scoped to Bedrock inference profile prefixes only — does NOT affect alias
  # resolution for other providers (e.g., anthropic:claude-3-haiku resolving
  # to claude-3-haiku-20240307 should NOT set provider_model_id).
  defp maybe_restore_inference_prefix(
         {:ok, %LLMDB.Model{provider: :amazon_bedrock} = model},
         spec
       )
       when is_binary(spec) do
    original_model_id = extract_model_id_from_spec(spec)

    if original_model_id && has_inference_prefix?(original_model_id) do
      {:ok, %{model | provider_model_id: original_model_id}}
    else
      {:ok, model}
    end
  end

  defp maybe_restore_inference_prefix({:ok, %LLMDB.Model{}} = result, _spec), do: result

  defp has_inference_prefix?(model_id) do
    case String.split(model_id, ".", parts: 2) do
      [prefix, _rest] -> prefix in @bedrock_inference_prefixes
      _ -> false
    end
  end

  defp extract_model_id_from_spec(spec) do
    case String.split(spec, ":", parts: 2) do
      [_provider, model_id] -> model_id
      _ -> nil
    end
  end

  defp normalize_inline_model_result({:ok, %LLMDB.Model{} = model}, _attrs) do
    {:ok, normalize_model_metadata(model)}
  end

  defp normalize_inline_model_result({:error, errors}, attrs) when is_list(errors) do
    {:error, invalid_inline_model_error(attrs, errors)}
  end

  defp normalize_model_metadata(%LLMDB.Model{} = model) do
    model
    |> sync_legacy_model_field()
    |> do_normalize_model_metadata()
  end

  defp do_normalize_model_metadata(%LLMDB.Model{provider: :openai} = model) do
    protocol =
      get_in(model, [Access.key(:extra, %{}), :wire, :protocol]) ||
        get_in(model, [Access.key(:extra, %{}), "wire", "protocol"])

    model_id = model.provider_model_id || model.id || model.model

    if is_nil(protocol) and ReqLLM.Providers.OpenAI.AdapterHelpers.responses_model?(model_id) do
      extra = model.extra || %{}

      updated_extra =
        cond do
          Map.has_key?(extra, :wire) ->
            wire = if is_map(extra[:wire]), do: extra[:wire], else: %{}
            Map.put(extra, :wire, Map.put(wire, :protocol, "openai_responses"))

          Map.has_key?(extra, "wire") ->
            wire = if is_map(extra["wire"]), do: extra["wire"], else: %{}
            Map.put(extra, "wire", Map.put(wire, "protocol", "openai_responses"))

          true ->
            Map.put(extra, :wire, %{protocol: "openai_responses"})
        end

      %{model | extra: updated_extra}
    else
      model
    end
  end

  defp do_normalize_model_metadata(%LLMDB.Model{provider: :openai_codex} = model) do
    extra = model.extra || %{}
    updated_extra = put_wire_protocol(extra, "openai_codex_responses")
    %{model | extra: updated_extra}
  end

  defp do_normalize_model_metadata(%LLMDB.Model{provider: :google} = model) do
    normalize_google_pricing(model)
  end

  defp do_normalize_model_metadata(%LLMDB.Model{} = model), do: model

  defp sync_legacy_model_field(%LLMDB.Model{id: id, model: nil} = model) when is_binary(id) do
    %{model | model: id}
  end

  defp sync_legacy_model_field(%LLMDB.Model{} = model), do: model

  defp normalize_google_pricing(%LLMDB.Model{id: model_id} = model) do
    case Map.get(@google_tiered_token_pricing, model_id) do
      nil ->
        model

      tiered_rates ->
        pricing = model.pricing || %{currency: "USD"}
        components = ReqLLM.Pricing.components(model)

        updated_components =
          components
          |> Enum.reject(&google_tiered_component?/1)
          |> Kernel.++(google_tiered_components(tiered_rates))

        updated_cost = normalize_google_cost(model.cost, tiered_rates)

        %{model | pricing: Map.put(pricing, :components, updated_components), cost: updated_cost}
    end
  end

  defp google_tiered_components(tiered_rates) do
    [:input, :output, :cache_read]
    |> Enum.flat_map(fn key ->
      case Map.get(tiered_rates, key) do
        {standard_rate, long_context_rate} ->
          [
            google_tiered_component("#{token_component_id(key)}.standard_context", standard_rate,
              max_input_tokens: @google_long_context_threshold
            ),
            google_tiered_component("#{token_component_id(key)}.long_context", long_context_rate,
              min_input_tokens: @google_long_context_threshold + 1
            )
          ]

        nil ->
          []
      end
    end)
  end

  defp google_tiered_component(id, rate, opts) do
    %{
      id: id,
      kind: "token",
      unit: "token",
      per: 1_000_000,
      rate: rate
    }
    |> maybe_put_map_value(:min_input_tokens, opts[:min_input_tokens])
    |> maybe_put_map_value(:max_input_tokens, opts[:max_input_tokens])
  end

  defp normalize_google_cost(cost, tiered_rates) do
    baseline_cost =
      Map.new(tiered_rates, fn {key, {standard_rate, _}} -> {key, standard_rate} end)

    if is_map(cost), do: Map.merge(cost, baseline_cost), else: baseline_cost
  end

  defp google_tiered_component?(component) do
    case pricing_component_id(component) do
      id when is_binary(id) ->
        Enum.any?([:input, :output, :cache_read], fn key ->
          token_component_match?(id, token_component_id(key))
        end)

      _ ->
        false
    end
  end

  defp pricing_component_id(component) when is_map(component) do
    case MapAccess.get(component, :id) do
      id when is_binary(id) -> id
      id when is_atom(id) -> Atom.to_string(id)
      _ -> nil
    end
  end

  defp token_component_match?(component_id, id) when is_binary(component_id) and is_binary(id) do
    component_id == id or String.starts_with?(component_id, id <> ".")
  end

  defp token_component_match?(_, _), do: false

  defp token_component_id(:input), do: "token.input"
  defp token_component_id(:output), do: "token.output"
  defp token_component_id(:cache_read), do: "token.cache_read"

  defp maybe_put_map_value(map, _key, nil), do: map
  defp maybe_put_map_value(map, key, value), do: Map.put(map, key, value)

  defp resolve_catalog_model(provider, model_id) do
    case LLMDB.model(provider, model_id) do
      {:ok, %LLMDB.Model{} = model} ->
        {:ok, model}

      {:error, _reason} = error ->
        resolve_provider_model_fallback(provider, model_id, error)
    end
  end

  defp resolve_string_model_fallback(spec, original_error) do
    case String.split(spec, ":", parts: 2) do
      [provider_name, model_id] ->
        case provider_atom_from_string(provider_name) do
          {:ok, provider} -> resolve_provider_model_fallback(provider, model_id, original_error)
          _ -> original_error
        end

      _ ->
        original_error
    end
  end

  defp resolve_provider_model_fallback(:openai_codex, model_id, _original_error) do
    case LLMDB.model(:openai, model_id) do
      {:ok, %LLMDB.Model{} = model} ->
        provider_model_id = model.provider_model_id || model.id || model.model
        {:ok, %{model | provider: :openai_codex, provider_model_id: provider_model_id}}

      {:error, _reason} ->
        model(%{provider: :openai_codex, id: model_id})
    end
  end

  defp resolve_provider_model_fallback(:mistral, model_id, _original_error) do
    model(mistral_inline_model_attrs(model_id))
  end

  defp resolve_provider_model_fallback(:minimax, model_id, _original_error) do
    model(minimax_inline_model_attrs(model_id))
  end

  defp resolve_provider_model_fallback(provider, model_id, _original_error) do
    case ReqLLM.provider(provider) do
      {:ok, _provider_module} ->
        warn_unverified_model(provider, model_id)
        model(%{provider: provider, id: model_id})

      {:error, _} ->
        {:error,
         ReqLLM.Error.Invalid.Provider.exception(
           provider: provider,
           message:
             "Provider :#{provider} is not available. Ensure the provider is properly configured or use an inline model spec."
         )}
    end
  end

  defp warn_unverified_model(provider, model_id) do
    IO.warn("""
    Using unverified model: #{provider}:#{model_id}

    This model is not in the LLMDB catalog. While it will work if the provider \
    supports this model ID, some features like pricing, token counting, and \
    capability detection may be unavailable.

    To suppress this warning, use an inline model spec:

        ReqLLM.model(%{provider: :#{provider}, id: "#{model_id}"})
    """)
  end

  defp provider_atom_from_string(provider_name) when is_binary(provider_name) do
    provider = String.to_existing_atom(provider_name)

    case ReqLLM.provider(provider) do
      {:ok, _module} -> {:ok, provider}
      {:error, _} -> :error
    end
  rescue
    ArgumentError ->
      :error
  end

  defp put_wire_protocol(extra, protocol) do
    cond do
      Map.has_key?(extra, :wire) ->
        wire = if is_map(extra[:wire]), do: extra[:wire], else: %{}
        Map.put(extra, :wire, Map.put(wire, :protocol, protocol))

      Map.has_key?(extra, "wire") ->
        wire = if is_map(extra["wire"]), do: extra["wire"], else: %{}
        Map.put(extra, "wire", Map.put(wire, "protocol", protocol))

      true ->
        Map.put(extra, :wire, %{protocol: protocol})
    end
  end

  defp mistral_inline_model_attrs(model_id) do
    base_attrs = %{
      provider: :mistral,
      id: model_id,
      model: model_id,
      provider_model_id: model_id
    }

    if mistral_embedding_model?(model_id) do
      Map.put(base_attrs, :capabilities, %{embeddings: true})
    else
      Map.merge(base_attrs, %{
        capabilities: %{chat: true, tools: %{enabled: true}},
        extra: %{wire: %{protocol: "openai_chat"}}
      })
    end
  end

  defp mistral_embedding_model?(model_id) when is_binary(model_id) do
    String.contains?(model_id, "embed")
  end

  defp minimax_inline_model_attrs(model_id) do
    %{
      provider: :minimax,
      id: model_id,
      model: model_id,
      provider_model_id: model_id,
      capabilities: %{chat: true, tools: %{enabled: true}},
      limits: %{context: 204_800, output: 2048},
      extra: %{wire: %{protocol: "openai_chat"}}
    }
  end

  defp normalize_inline_model_attrs(attrs) do
    attrs = atomize_inline_model_keys(attrs)
    attrs = sync_inline_model_id_and_model(attrs)

    cond do
      not valid_inline_model_provider?(attrs[:provider]) ->
        {:error,
         invalid_model_spec_error(
           attrs,
           "Inline model specs require :provider to be an atom or provider string. Example: #{@inline_model_example}"
         )}

      not valid_inline_model_identifier?(attrs) ->
        {:error,
         invalid_model_spec_error(
           attrs,
           "Inline model specs require :id or :model. Example: #{@inline_model_example}"
         )}

      true ->
        coerce_inline_model_provider(attrs)
    end
  end

  defp atomize_inline_model_keys(attrs) do
    Enum.reduce(attrs, attrs, fn
      {key, value}, acc when is_binary(key) and key in @inline_model_field_strings ->
        acc
        |> Map.delete(key)
        |> Map.put(String.to_existing_atom(key), value)

      _, acc ->
        acc
    end)
  end

  defp sync_inline_model_id_and_model(attrs) do
    id = Map.get(attrs, :id)
    model = Map.get(attrs, :model)

    cond do
      is_binary(id) and is_nil(model) ->
        Map.put(attrs, :model, id)

      is_binary(model) and is_nil(id) ->
        Map.put(attrs, :id, model)

      true ->
        attrs
    end
  end

  defp valid_inline_model_provider?(provider),
    do: (is_atom(provider) and not is_nil(provider)) or is_binary(provider)

  defp valid_inline_model_identifier?(attrs) do
    is_binary(Map.get(attrs, :id)) or is_binary(Map.get(attrs, :model))
  end

  defp coerce_inline_model_provider(%{provider: provider} = attrs) when is_binary(provider) do
    {:ok, Map.put(attrs, :provider, String.to_existing_atom(provider))}
  rescue
    ArgumentError ->
      {:error,
       invalid_model_spec_error(
         attrs,
         "Inline model specs require an existing provider atom or registered provider string. Got: #{inspect(provider)}"
       )}
  end

  defp coerce_inline_model_provider(attrs), do: {:ok, attrs}

  defp invalid_inline_model_error(attrs, errors) do
    message =
      errors
      |> Enum.take(3)
      |> Enum.map_join(", ", &format_inline_model_error/1)

    invalid_model_spec_error(
      attrs,
      "Invalid inline model spec: #{message}. Example: #{@inline_model_example}"
    )
  end

  defp format_inline_model_error(%Zoi.Error{path: path, message: message}) do
    case Enum.map(path, &to_string/1) do
      [] -> message
      path_segments -> "#{Enum.join(path_segments, ".")} #{message}"
    end
  end

  defp format_inline_model_error(other), do: inspect(other)

  defp invalid_model_spec_error(attrs, reason) do
    ReqLLM.Error.validation_error(:invalid_model_spec, reason, model: inspect(attrs))
  end

  # ===========================================================================
  # Text Generation API - Delegated to ReqLLM.Generation
  # ===========================================================================

  @doc """
  Generates text using an AI model with full response metadata.

  Returns a canonical ReqLLM.Response which includes usage data, context, and metadata.
  For simple text-only results, use `generate_text!/3`.

  ## Parameters

    * `model_spec` - Model specification in various formats
    * `messages` - Text prompt or list of messages
    * `opts` - Additional options (keyword list)

  ## Options

    * `:temperature` - Control randomness in responses (0.0 to 2.0)
    * `:max_tokens` - Limit the length of the response
    * `:top_p` - Nucleus sampling parameter
    * `:presence_penalty` - Penalize new tokens based on presence
    * `:frequency_penalty` - Penalize new tokens based on frequency
    * `:tools` - List of tool definitions
    * `:tool_choice` - Tool choice strategy
    * `:system_prompt` - System prompt to prepend
    * `:provider_options` - Provider-specific options

  ## Examples

      {:ok, response} = ReqLLM.generate_text("anthropic:claude-3-sonnet", "Hello world")
      ReqLLM.Response.text(response)
      #=> "Hello! How can I assist you today?"

      # Access usage metadata
      ReqLLM.Response.usage(response)
      #=> %{input_tokens: 10, output_tokens: 8}

  """
  defdelegate generate_text(model_spec, messages, opts \\ []), to: Generation

  @doc """
  Generates text using an AI model, returning only the text content.

  This is a convenience function that extracts just the text from the response.
  For access to usage metadata and other response data, use `generate_text/3`.
  Raises on error.

  ## Parameters

  Same as `generate_text/3`.

  ## Examples

      ReqLLM.generate_text!("anthropic:claude-3-sonnet", "Hello world")
      #=> "Hello! How can I assist you today?"

  """
  defdelegate generate_text!(model_spec, messages, opts \\ []), to: Generation

  @doc """
  Streams text generation using an AI model with concurrent metadata collection.

  Returns a `ReqLLM.StreamResponse` that provides both real-time token streaming
  and asynchronous metadata collection (usage, finish_reason). This enables
  zero-latency content delivery while collecting billing/usage data concurrently.

  The streaming implementation uses Finch directly for production-grade performance
  with HTTP/2 multiplexing and automatic connection pooling.

  ## Parameters

  Same as `generate_text/3`.

  ## Returns

    * `{:ok, stream_response}` - StreamResponse with stream and metadata task
    * `{:error, reason}` - Request failed or invalid parameters

  ## Examples

      # Real-time streaming
      {:ok, response} = ReqLLM.stream_text("anthropic:claude-3-sonnet", "Tell me a story")
      response
      |> ReqLLM.StreamResponse.tokens()
      |> Stream.each(&IO.write/1)
      |> Stream.run()

      # Concurrent metadata collection
      usage = ReqLLM.StreamResponse.usage(response)
      #=> %{input_tokens: 15, output_tokens: 42, total_cost: 0.087}

      # Simple text collection
      text = ReqLLM.StreamResponse.text(response)

      # Backward compatibility
      {:ok, legacy_response} = ReqLLM.StreamResponse.to_response(response)

  ## StreamResponse Fields

    * `stream` - Lazy enumerable of `StreamChunk` structs for real-time consumption
    * `metadata_handle` - Concurrent handle collecting usage and finish_reason
    * `cancel` - Function to terminate streaming and cleanup resources
    * `model` - Model specification that generated this response
    * `context` - Updated conversation context including assistant's response

  ## Performance Notes

  The stream is lazy and supports backpressure. Metadata collection happens
  concurrently and won't block token delivery. Use cancellation for early
  termination to free resources.

  """
  defdelegate stream_text(model_spec, messages, opts \\ []), to: Generation

  @doc """
  **DEPRECATED**: This function will be removed in a future version.

  The streaming API has been redesigned to return a composite `StreamResponse` struct
  that provides both the stream and metadata. Use `stream_text/3` instead:

      {:ok, response} = ReqLLM.stream_text(model, messages)
      response.stream |> Enum.each(&IO.write/1)

  For simple text extraction, use:

      text = ReqLLM.StreamResponse.text(response)

  ## Legacy Behavior

  This function currently returns `:ok` and logs a deprecation warning.
  It will be formally removed in the next major version.
  """
  @deprecated "Use stream_text/3 with StreamResponse instead"
  def stream_text!(_model_spec, _messages, _opts \\ []) do
    IO.warn("""
    ReqLLM.stream_text!/3 is deprecated and will be removed in a future version.

    Please migrate to the new streaming API:

    Old code:
        ReqLLM.stream_text!(model, messages) |> Enum.each(&IO.write/1)

    New code:
        {:ok, response} = ReqLLM.stream_text(model, messages)
        response.stream |> Enum.each(&IO.write/1)

    Or for simple text extraction:
        text = ReqLLM.StreamResponse.text(response)
    """)

    :ok
  end

  @doc """
  Generates structured data using an AI model with schema validation.

  Equivalent to Vercel AI SDK's `generateObject()` function, this method
  generates structured data according to a provided schema and validates
  the output against that schema.

  ## Parameters

    * `model_spec` - Model specification in various formats
    * `messages` - Text prompt or list of messages
    * `schema` - Schema definition for structured output (NimbleOptions schema or JSON Schema map)
    * `opts` - Additional options (keyword list)

  ## Options

    * `:temperature` - Control randomness in responses (0.0 to 2.0)
    * `:max_tokens` - Limit the length of the response
    * `:provider_options` - Provider-specific options

  ## Examples

      # Generate a structured object
      schema = [
        name: [type: :string, required: true],
        age: [type: :pos_integer, required: true]
      ]
      {:ok, object} = ReqLLM.generate_object("anthropic:claude-3-sonnet", "Generate a person", schema)
      #=> {:ok, %{name: "John Doe", age: 30}}

      # Generate an array of objects (requires JSON Schema-capable provider like OpenAI)
      person_schema = ReqLLM.Schema.to_json([
        name: [type: :string, required: true],
        age: [type: :pos_integer, required: true]
      ])

      array_schema = %{"type" => "array", "items" => person_schema}

      {:ok, response} = ReqLLM.generate_object(
        "openai:gpt-4o",
        "Generate 3 heroes",
        array_schema
      )
      # Note: Array outputs currently require manual extraction from the response

      # Recommended: Use Zoi for cleaner array schema definition
      person = Zoi.object(%{
        name: Zoi.string(),
        age: Zoi.number()
      })

      array_schema = Zoi.array(person) |> ReqLLM.Schema.to_json()

      {:ok, response} = ReqLLM.generate_object(
        "openai:gpt-4o",
        "Generate 3 heroes",
        array_schema
      )

  > **Note**: Top-level non-object outputs (arrays, enums) require raw JSON Schema
  > and are only supported by providers with native JSON Schema capabilities (e.g., OpenAI).
  > Most providers only support object-type schemas. For cleaner array schema definitions,
  > consider using the Zoi library as shown above.

  """
  defdelegate generate_object(model_spec, messages, schema, opts \\ []), to: Generation

  @doc """
  Generates structured data using an AI model, returning only the object content.

  This is a convenience function that extracts just the object from the response.
  For access to usage metadata and other response data, use `generate_object/4`.

  ## Parameters

  Same as `generate_object/4`.

  ## Examples

      ReqLLM.generate_object!("anthropic:claude-3-sonnet", "Generate a person", schema)
      #=> %{name: "John Doe", age: 30}

  """
  defdelegate generate_object!(model_spec, messages, schema, opts \\ []), to: Generation

  # ===========================================================================
  # Image Generation API - Delegated to ReqLLM.Images
  # ===========================================================================

  @doc """
  Generates images using an AI model with full response metadata.

  Returns a canonical `ReqLLM.Response` where images are represented as message content parts.
  """
  @spec generate_image(
          String.t() | {atom(), keyword()} | struct(),
          String.t() | list() | ReqLLM.Context.t(),
          keyword()
        ) :: {:ok, ReqLLM.Response.t()} | {:error, term()}
  defdelegate generate_image(model_spec, prompt_or_messages, opts \\ []), to: Images

  @doc """
  Generates images using an AI model, raising on error.
  """
  @spec generate_image!(
          String.t() | {atom(), keyword()} | struct(),
          String.t() | list() | ReqLLM.Context.t(),
          keyword()
        ) :: ReqLLM.Response.t() | no_return()
  def generate_image!(model_spec, prompt_or_messages, opts \\ []) do
    case generate_image(model_spec, prompt_or_messages, opts) do
      {:ok, response} -> response
      {:error, error} -> raise error
    end
  end

  @doc """
  Streams structured data generation using an AI model with schema validation.

  Equivalent to Vercel AI SDK's `streamObject()` function, this method
  streams structured data generation according to a provided schema.

  ## Parameters

    * `model_spec` - Model specification in various formats
    * `messages` - Text prompt or list of messages
    * `schema` - Schema definition for structured output
    * `opts` - Additional options (keyword list)

  ## Options

    Same as `generate_object/4`.

  ## Examples

      # Stream structured object generation
      schema = [
        name: [type: :string, required: true],
        description: [type: :string, required: true]
      ]
      {:ok, stream} = ReqLLM.stream_object("anthropic:claude-3-sonnet", "Generate a character", schema)
      stream |> Enum.each(&IO.inspect/1)

  """
  defdelegate stream_object(model_spec, messages, schema, opts \\ []), to: Generation

  @doc """
  **DEPRECATED**: This function will be removed in a future version.

  The streaming API has been redesigned to return a composite `StreamResponse` struct
  that provides both the stream and metadata. Use `stream_object/4` instead:

      {:ok, response} = ReqLLM.stream_object(model, messages, schema)
      response.stream |> Enum.each(&IO.inspect/1)

  For simple object extraction, use:

      object = ReqLLM.StreamResponse.object(response)

  ## Legacy Parameters

  Same as `stream_object/4`.

  ## Legacy Examples

      ReqLLM.stream_object!("anthropic:claude-3-sonnet", "Generate a character", schema)
      |> Enum.each(&IO.inspect/1)

  """
  @deprecated "Use stream_object/4 with StreamResponse instead"
  def stream_object!(_model_spec, _messages, _schema, _opts \\ []) do
    IO.warn("""
    ReqLLM.stream_object!/4 is deprecated and will be removed in a future version.

    Please migrate to the new streaming API:

    Old code:
        ReqLLM.stream_object!(model, messages, schema) |> Enum.each(&IO.inspect/1)

    New code:
        {:ok, response} = ReqLLM.stream_object(model, messages, schema)
        response.stream |> Enum.each(&IO.inspect/1)

    Or for simple object extraction:
        object = ReqLLM.StreamResponse.object(response)
    """)

    :ok
  end

  # ===========================================================================
  # Embedding API - Delegated to ReqLLM.Embedding
  # ===========================================================================

  @doc """
  Generates embeddings for single or multiple text inputs.

  Accepts either a single string or a list of strings, automatically handling
  both cases using pattern matching.

  ## Parameters

    * `model_spec` - Model specification in various formats
    * `input` - Text string or list of text strings to generate embeddings for
    * `opts` - Additional options (keyword list)

  ## Options

    * `:dimensions` - Number of dimensions for embeddings
    * `:provider_options` - Provider-specific options
    * `:return_usage` - Return `%{embedding: vectors, usage: usage_map}` with token and cost metadata

  ## Examples

      # Single text input
      {:ok, embedding} = ReqLLM.embed("openai:text-embedding-3-small", "Hello world")
      #=> {:ok, [0.1, -0.2, 0.3, ...]}

      # Multiple text inputs
      {:ok, embeddings} = ReqLLM.embed(
        "openai:text-embedding-3-small",
        ["Hello", "World"]
      )
      #=> {:ok, [[0.1, -0.2, ...], [0.3, 0.4, ...]]}

      # With usage and cost data
      {:ok, %{embedding: embedding, usage: usage}} =
        ReqLLM.embed("openai:text-embedding-3-small", "Hello world", return_usage: true)

      Map.has_key?(usage, :total_cost)
      #=> true

  """
  defdelegate embed(model_spec, input, opts \\ []), to: Embedding

  # ===========================================================================
  # Rerank API - Delegated to ReqLLM.Rerank
  # ===========================================================================

  @doc """
  Reranks documents against a query.

  Returns a `ReqLLM.RerankResponse` with the most relevant documents first.
  """
  @spec rerank(model_input(), keyword()) :: {:ok, ReqLLM.RerankResponse.t()} | {:error, term()}
  defdelegate rerank(model_spec, opts \\ []), to: Rerank

  @doc """
  Reranks documents against a query, raising on error.
  """
  @spec rerank!(model_input(), keyword()) :: ReqLLM.RerankResponse.t() | no_return()
  defdelegate rerank!(model_spec, opts \\ []), to: Rerank

  # ===========================================================================
  # OCR API - Delegated to ReqLLM.OCR
  # ===========================================================================

  @doc """
  Extracts rich markdown from documents using OCR models.

  Processes PDFs, images, and other documents through OCR models (e.g., Mistral OCR
  on Vertex AI) and returns structured markdown with interleaved images.

  ## Parameters

    * `model_spec` - Model specification (e.g., `%{provider: :google_vertex, id: "mistral-ocr-2505"}`)
    * `document_binary` - Raw document bytes
    * `opts` - Options (`:include_images`, `:document_type`, `:provider_options`)

  ## Examples

      pdf = File.read!("report.pdf")
      model = ReqLLM.model!(%{provider: :google_vertex, id: "mistral-ocr-2505"})

      {:ok, result} = ReqLLM.ocr(model, pdf,
        provider_options: [region: "europe-west4"]
      )
      result.markdown  #=> "# Report Title\\n\\nContent..."

  """
  defdelegate ocr(model_spec, document_binary, opts \\ []), to: OCR

  @doc """
  Extracts rich markdown from documents using OCR models. Raises on error.
  """
  defdelegate ocr!(model_spec, document_binary, opts \\ []), to: OCR

  @doc """
  Process a file at the given path through an OCR model.
  Detects document type from file extension.
  """
  defdelegate ocr_file(model_spec, path, opts \\ []), to: OCR

  @doc """
  Process a file through an OCR model. Raises on error.
  """
  defdelegate ocr_file!(model_spec, path, opts \\ []), to: OCR

  # ===========================================================================
  # Transcription API - Delegated to ReqLLM.Transcription
  # ===========================================================================

  @doc """
  Transcribes audio using an AI model.

  Inspired by the Vercel AI SDK's `transcribe()` function. Returns a
  `ReqLLM.Transcription.Result` with transcribed text, timing segments,
  detected language, and duration.

  ## Parameters

    * `model_spec` - Model specification (e.g., `"openai:whisper-1"`, `"groq:whisper-large-v3"`)
    * `audio` - Audio input:
      - `String.t()` - File path to an audio file
      - `{:binary, binary(), String.t()}` - Raw audio data with media type
      - `{:base64, String.t(), String.t()}` - Base64-encoded audio with media type
    * `opts` - Additional options (keyword list)

  ## Options

    * `:language` - Language hint in ISO-639-1 format (e.g., "en")
    * `:provider_options` - Provider-specific options
    * `:receive_timeout` - HTTP timeout in milliseconds (default: 120_000)

  ## Examples

      # From file path
      {:ok, result} = ReqLLM.transcribe("openai:whisper-1", "speech.mp3")
      result.text #=> "Hello world"

      # From binary data
      data = File.read!("speech.mp3")
      {:ok, result} = ReqLLM.transcribe("openai:whisper-1", {:binary, data, "audio/mpeg"})

      # With options
      {:ok, result} = ReqLLM.transcribe("openai:whisper-1", "speech.mp3",
        language: "en",
        provider_options: [prompt: "Technical terms: ReqLLM, Elixir"]
      )

  """
  defdelegate transcribe(model_spec, audio, opts \\ []), to: Transcription

  @doc """
  Transcribes audio, raising on error.

  Same as `transcribe/3` but raises on error.
  """
  defdelegate transcribe!(model_spec, audio, opts \\ []), to: Transcription

  # ===========================================================================
  # Speech API - Delegated to ReqLLM.Speech
  # ===========================================================================

  @doc """
  Generates speech audio from text using an AI model.

  Inspired by the Vercel AI SDK's `generateSpeech()` function. Returns a
  `ReqLLM.Speech.Result` with the generated audio binary, media type, and format.

  ## Parameters

    * `model_spec` - Model specification (e.g., `"openai:tts-1"`, `"openai:gpt-4o-mini-tts"`)
    * `text` - The text to convert to speech
    * `opts` - Additional options (keyword list)

  ## Options

    * `:voice` - Voice identifier (e.g., "alloy", "echo", "nova", "shimmer")
    * `:speed` - Speech speed multiplier (0.25 to 4.0)
    * `:output_format` - Audio format: `:mp3`, `:opus`, `:aac`, `:flac`, `:wav`, `:pcm`
    * `:language` - ISO-639-1 language code
    * `:provider_options` - Provider-specific options (e.g., `[instructions: "Speak slowly"]`)
    * `:receive_timeout` - HTTP timeout in milliseconds (default: 120_000)

  ## Examples

      # Basic usage
      {:ok, result} = ReqLLM.speak("openai:tts-1", "Hello world", voice: "alloy")
      File.write!("hello.mp3", result.audio)

      # High quality with options
      {:ok, result} = ReqLLM.speak("openai:tts-1-hd", "Welcome!",
        voice: "nova",
        speed: 1.2,
        output_format: :wav
      )

      # With instructions (gpt-4o-mini-tts)
      {:ok, result} = ReqLLM.speak("openai:gpt-4o-mini-tts", "Breaking news!",
        voice: "coral",
        provider_options: [instructions: "Speak in an excited tone"]
      )

  """
  defdelegate speak(model_spec, text, opts \\ []), to: Speech

  @doc """
  Generates speech audio from text, raising on error.

  Same as `speak/3` but raises on error.
  """
  defdelegate speak!(model_spec, text, opts \\ []), to: Speech

  # ===========================================================================
  # Vercel AI SDK Utility API - Delegated to ReqLLM.Utils
  # ===========================================================================

  @doc """
  Creates a Tool struct for AI model function calling.

  Equivalent to Vercel AI SDK's `tool()` helper, providing type-safe tool
  definitions with parameter validation. This is a convenience function
  for creating ReqLLM.Tool structs.

  ## Parameters

    * `opts` - Tool definition options (keyword list)

  ## Options

    * `:name` - Tool name (required, must be valid identifier)
    * `:description` - Tool description for AI model (required)
    * `:parameters` - Parameter schema as NimbleOptions keyword list (optional)
    * `:callback` - Callback function or MFA tuple (required)

  ## Examples

      # Simple tool with no parameters
      tool = ReqLLM.tool(
        name: "get_time",
        description: "Get the current time",
        callback: fn _args -> {:ok, DateTime.utc_now()} end
      )

      # Tool with parameters
      weather_tool = ReqLLM.tool(
        name: "get_weather",
        description: "Get current weather for a location",
        parameters: [
          location: [type: :string, required: true, doc: "City name"],
          units: [type: :string, default: "metric", doc: "Temperature units"]
        ],
        callback: {WeatherAPI, :fetch_weather}
      )

  """
  @spec tool(keyword()) :: Tool.t()
  def tool(opts) when is_list(opts) do
    Tool.new!(opts)
  end

  @doc """
  Creates a JSON schema object compatible with ReqLLM.

  Equivalent to Vercel AI SDK's `jsonSchema()` helper, this function
  creates schema objects for structured data generation and validation.

  ## Parameters

    * `schema` - NimbleOptions schema definition (keyword list)
    * `opts` - Additional options (optional)

  ## Options

    * `:validate` - Custom validation function (optional)

  ## Examples

      # Basic schema
      schema = ReqLLM.json_schema([
        name: [type: :string, required: true, doc: "User name"],
        age: [type: :integer, doc: "User age"]
      ])

      # Schema with custom validation
      schema = ReqLLM.json_schema(
        [email: [type: :string, required: true]],
        validate: fn value ->
          if String.contains?(value["email"], "@") do
            {:ok, value}
          else
            {:error, "Invalid email format"}
          end
        end
      )

  """
  @spec json_schema(keyword(), keyword()) :: map()
  def json_schema(schema, opts \\ []) when is_list(schema) and is_list(opts) do
    json_schema = Schema.to_json(schema)

    case opts[:validate] do
      nil ->
        json_schema

      validator when is_function(validator, 1) ->
        Map.put(json_schema, :validate, validator)
    end
  end

  @doc """
  Calculates cosine similarity between two embedding vectors.

  Equivalent to Vercel AI SDK's `cosineSimilarity()` function.
  Returns a similarity score between -1 and 1, where:
  - 1.0 indicates identical vectors (maximum similarity)
  - 0.0 indicates orthogonal vectors (no similarity)
  - -1.0 indicates opposite vectors (maximum dissimilarity)

  ## Parameters

    * `embedding_a` - First embedding vector (list of numbers)
    * `embedding_b` - Second embedding vector (list of numbers)

  ## Examples

      # Identical vectors
      ReqLLM.cosine_similarity([1.0, 0.0, 0.0], [1.0, 0.0, 0.0])
      #=> 1.0

      # Orthogonal vectors
      ReqLLM.cosine_similarity([1.0, 0.0], [0.0, 1.0])
      #=> 0.0

      # Opposite vectors
      ReqLLM.cosine_similarity([1.0, 0.0], [-1.0, 0.0])
      #=> -1.0

      # Similar vectors
      ReqLLM.cosine_similarity([0.5, 0.8, 0.3], [0.6, 0.7, 0.4])
      #=> 0.9487...

  """
  @spec cosine_similarity([number()], [number()]) :: float()
  def cosine_similarity(embedding_a, embedding_b)
      when is_list(embedding_a) and is_list(embedding_b) do
    if length(embedding_a) != length(embedding_b) do
      raise ArgumentError, "Embedding vectors must have the same length"
    end

    if embedding_a == [] do
      0.0
    else
      dot_product =
        embedding_a
        |> Enum.zip(embedding_b)
        |> Enum.reduce(0, fn {a, b}, acc -> acc + a * b end)

      magnitude_a = :math.sqrt(Enum.reduce(embedding_a, 0, fn x, acc -> acc + x * x end))
      magnitude_b = :math.sqrt(Enum.reduce(embedding_b, 0, fn x, acc -> acc + x * x end))

      if magnitude_a == 0 or magnitude_b == 0 do
        0.0
      else
        dot_product / (magnitude_a * magnitude_b)
      end
    end
  end
end
