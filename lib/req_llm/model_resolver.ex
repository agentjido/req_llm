defmodule ReqLLM.ModelResolver do
  @moduledoc false

  alias ReqLLM.MapAccess

  @type input ::
          String.t()
          | map()
          | {atom(), String.t(), keyword()}
          | {atom(), keyword()}
          | LLMDB.Model.t()
  @type warning :: String.t()
  @type result :: {:ok, LLMDB.Model.t(), [warning()]} | {:error, term()}
  @type provider_lookup :: (atom() -> {:ok, module()} | {:error, term()})

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
    }
  }

  @spec resolve(input(), provider_lookup()) :: result()
  def resolve(%LLMDB.Model{} = model, _provider_lookup) do
    model
    |> Map.from_struct()
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> LLMDB.Enrich.enrich_model()
    |> LLMDB.Model.new()
    |> normalize_model_result()
  end

  def resolve(%{} = attrs, _provider_lookup) when not is_struct(attrs) do
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

  def resolve({provider, model_id, _opts}, provider_lookup)
      when is_atom(provider) and is_binary(model_id) do
    provider
    |> resolve_catalog_model(model_id, provider_lookup)
    |> normalize_model_result()
  end

  def resolve({provider, kw}, provider_lookup) when is_atom(provider) and is_list(kw) do
    case kw[:id] || kw[:model] do
      id when is_binary(id) ->
        provider
        |> resolve_catalog_model(id, provider_lookup)
        |> normalize_model_result()

      _ ->
        {:error, ReqLLM.Error.Invalid.Parameter.exception(parameter: :model, value: kw)}
    end
  end

  def resolve(spec, provider_lookup) when is_binary(spec) do
    case parse_string_model_spec(spec, provider_lookup) do
      {:ok, {provider, model_id}} ->
        provider
        |> resolve_catalog_model(model_id, provider_lookup)
        |> normalize_model_result()

      {:error, _reason} = error ->
        spec
        |> resolve_string_model_fallback(error, provider_lookup)
        |> normalize_model_result()
    end
  end

  def resolve(other, _provider_lookup) do
    {:error,
     ReqLLM.Error.Validation.Error.exception(message: "Invalid model spec: #{inspect(other)}")}
  end

  defp normalize_model_result({:ok, %LLMDB.Model{} = model}) do
    {:ok, normalize_model_metadata(model), []}
  end

  defp normalize_model_result({:ok, %LLMDB.Model{} = model, warnings}) do
    {:ok, normalize_model_metadata(model), warnings}
  end

  defp normalize_model_result(other), do: other

  defp apply_resolved_route(provider, resolved_id, model) do
    case LLMDB.Spec.strip_prefix(provider, resolved_id) do
      {_base_id, nil} ->
        {:ok, model}

      {_base_id, prefix} ->
        api_id = model.provider_model_id || resolved_id
        {base_api_id, _api_prefix} = LLMDB.Spec.strip_prefix(provider, api_id)
        {:ok, %{model | provider_model_id: prefix <> base_api_id}}
    end
  end

  defp normalize_inline_model_result({:ok, %LLMDB.Model{} = model}, _attrs) do
    {:ok, normalize_model_metadata(model), []}
  end

  defp normalize_inline_model_result({:error, errors}, attrs) when is_list(errors) do
    {:error, invalid_inline_model_error(attrs, errors)}
  end

  defp normalize_model_metadata(%LLMDB.Model{} = model) do
    model
    |> sync_legacy_model_field()
    |> normalize_catalog_extra()
    |> do_normalize_model_metadata()
  end

  defp normalize_catalog_extra(%LLMDB.Model{extra: extra} = model) when is_map(extra) do
    normalized_extra =
      extra
      |> copy_catalog_extra_key("family", :family)
      |> copy_catalog_extra_key("wire", :wire)
      |> normalize_catalog_wire()

    %{model | extra: normalized_extra}
  end

  defp normalize_catalog_extra(%LLMDB.Model{} = model), do: model

  defp copy_catalog_extra_key(extra, string_key, atom_key) do
    case {Map.has_key?(extra, atom_key), Map.fetch(extra, string_key)} do
      {false, {:ok, value}} -> Map.put(extra, atom_key, value)
      _ -> extra
    end
  end

  defp normalize_catalog_wire(%{wire: wire} = extra) when is_map(wire) do
    Map.put(extra, :wire, copy_catalog_extra_key(wire, "protocol", :protocol))
  end

  defp normalize_catalog_wire(extra), do: extra

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
            google_tiered_component(
              "#{token_component_id(key)}.standard_context",
              standard_rate,
              %{input_tokens: %{lte: @google_long_context_threshold}}
            ),
            google_tiered_component(
              "#{token_component_id(key)}.long_context",
              long_context_rate,
              %{input_tokens: %{gt: @google_long_context_threshold}}
            )
          ]

        nil ->
          []
      end
    end)
  end

  defp google_tiered_component(id, rate, applies_when) do
    %{
      id: id,
      kind: "token",
      unit: "token",
      per: 1_000_000,
      rate: rate,
      applies_when: applies_when,
      charge_scope: "full_request"
    }
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

  defp resolve_catalog_model(provider, model_id, provider_lookup) do
    case LLMDB.Spec.resolve({provider, model_id}) do
      {:ok, {resolved_provider, resolved_id, %LLMDB.Model{} = model}} ->
        apply_resolved_route(resolved_provider, resolved_id, model)

      {:error, _reason} = error ->
        resolve_provider_model_fallback(provider, model_id, error, provider_lookup)
    end
  end

  defp parse_string_model_spec(spec, provider_lookup) do
    format =
      case String.split(spec, "@", parts: 2) do
        [_model_id, provider_name] ->
          case provider_atom_from_string(String.trim(provider_name), provider_lookup) do
            {:ok, _provider} -> [format: :at]
            _ -> []
          end

        _ ->
          []
      end

    LLMDB.Spec.parse_spec(spec, format)
  end

  defp resolve_string_model_fallback(
         spec,
         {:error, :unknown_provider} = original_error,
         provider_lookup
       ) do
    candidates = [
      String.split(spec, "@", parts: 2),
      Enum.reverse(String.split(spec, ":", parts: 2))
    ]

    Enum.find_value(candidates, original_error, fn
      [model_id, provider_name] ->
        case provider_atom_from_string(String.trim(provider_name), provider_lookup) do
          {:ok, provider} ->
            resolve_catalog_model(provider, String.trim(model_id), provider_lookup)

          _ ->
            nil
        end

      _ ->
        nil
    end)
  end

  defp resolve_string_model_fallback(_spec, original_error, _provider_lookup), do: original_error

  defp resolve_provider_model_fallback(
         :openai_codex,
         model_id,
         _original_error,
         provider_lookup
       ) do
    case LLMDB.model(:openai, model_id) do
      {:ok, %LLMDB.Model{} = model} ->
        provider_model_id = model.provider_model_id || model.id || model.model
        {:ok, %{model | provider: :openai_codex, provider_model_id: provider_model_id}}

      {:error, _reason} ->
        resolve(%{provider: :openai_codex, id: model_id}, provider_lookup)
    end
  end

  defp resolve_provider_model_fallback(
         :github_copilot,
         model_id,
         _original_error,
         provider_lookup
       ) do
    resolve(
      %{
        provider: :github_copilot,
        id: model_id,
        extra: %{wire: %{protocol: "openai_chat"}}
      },
      provider_lookup
    )
  end

  defp resolve_provider_model_fallback(:mistral, model_id, _original_error, provider_lookup) do
    resolve(mistral_inline_model_attrs(model_id), provider_lookup)
  end

  defp resolve_provider_model_fallback(:minimax, model_id, _original_error, provider_lookup) do
    resolve(minimax_inline_model_attrs(model_id), provider_lookup)
  end

  defp resolve_provider_model_fallback(:typesafe, model_id, _original_error, provider_lookup) do
    resolve(
      %{
        provider: :typesafe,
        id: model_id,
        capabilities: %{chat: false, streaming: %{text: false, tool_calls: false}}
      },
      provider_lookup
    )
  end

  defp resolve_provider_model_fallback(provider, model_id, _original_error, provider_lookup) do
    case provider_lookup.(provider) do
      {:ok, _provider_module} ->
        with {:ok, model, warnings} <-
               resolve(%{provider: provider, id: model_id}, provider_lookup) do
          {:ok, model, [unverified_model_warning(provider, model_id) | warnings]}
        end

      {:error, _} ->
        {:error,
         ReqLLM.Error.Invalid.Provider.exception(
           provider: provider,
           message:
             "Provider :#{provider} is not available. Ensure the provider is properly configured or use an inline model spec."
         )}
    end
  end

  defp unverified_model_warning(provider, model_id) do
    """
    Using unverified model: #{provider}:#{model_id}

    This model is not in the LLMDB catalog. While it will work if the provider \
    supports this model ID, some features like pricing, token counting, and \
    capability detection may be unavailable.

    To suppress this warning, use an inline model spec:

        ReqLLM.model(%{provider: :#{provider}, id: "#{model_id}"})

    or, when model ids are dynamic (user- or database-configured), disable it \
    globally:

        config :req_llm, warn_unverified_models: false
    """
  end

  defp provider_atom_from_string(provider_name, provider_lookup) when is_binary(provider_name) do
    provider =
      provider_name
      |> String.replace("-", "_")
      |> String.to_existing_atom()

    case provider_lookup.(provider) do
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
    attrs = disable_typesafe_generation(attrs)

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

  defp disable_typesafe_generation(%{provider: provider} = attrs)
       when provider in [:typesafe, "typesafe"] do
    capabilities = Map.get(attrs, :capabilities) || %{}
    streaming = Map.get(capabilities, :streaming) || %{}

    capabilities =
      capabilities
      |> Map.put(:chat, false)
      |> Map.put(:streaming, Map.merge(streaming, %{text: false, tool_calls: false}))

    Map.put(attrs, :capabilities, capabilities)
  end

  defp disable_typesafe_generation(attrs), do: attrs

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

  defp valid_inline_model_provider?(provider) do
    (is_atom(provider) and not is_nil(provider)) or is_binary(provider)
  end

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
end
