defmodule ReqLLM.Providers.Google do
  @moduledoc """
  Google Gemini provider – built on the OpenAI baseline defaults with Gemini-specific customizations.

  ## Implementation

  Uses built-in defaults with custom encoding/decoding to translate between OpenAI format and Gemini API format.

  ## Google-Specific Extensions

  Beyond standard OpenAI parameters, Google supports:
  - `google_api_version` - Select API version ("v1" or "v1beta"). Defaults to "v1" for production stability.
    Set to "v1beta" to enable beta features like Google Search grounding.
  - `google_safety_settings` - List of safety filter configurations
  - `google_candidate_count` - Number of response candidates to generate (default: 1)
  - `google_grounding` - Enable Google Search grounding (built-in web search). Requires `google_api_version: "v1beta"`
  - `google_thinking_budget` - Thinking token budget for Gemini 2.5 models
  - `dimensions` - Number of dimensions for embedding vectors
  - `task_type` - Task type for embeddings (e.g., RETRIEVAL_QUERY)

  See `provider_schema/0` for the complete Google-specific schema and
  `ReqLLM.Provider.Options` for inherited OpenAI parameters.

  ## API Version Selection

  The provider defaults to Google's stable v1 API for production reliability. To use beta features like
  Google Search grounding, explicitly set `google_api_version: "v1beta"`:

      ReqLLM.generate_text(
        "google:gemini-2.5-flash",
        "What are today's tech headlines?",
        provider_options: [
          google_api_version: "v1beta",
          google_grounding: %{enable: true}
        ]
      )

  **Note**: When `google_grounding` is used without specifying an API version, v1beta is automatically
  selected with a warning. Setting v1 explicitly with grounding enabled will return an error.

  ## Configuration

      # Add to .env file (automatically loaded)
      GOOGLE_API_KEY=AIza...
  """

  @behaviour ReqLLM.Provider

  use ReqLLM.Provider.DSL,
    id: :google,
    base_url: "https://generativelanguage.googleapis.com/v1",
    metadata: "priv/models_dev/google.json",
    default_env_key: "GOOGLE_API_KEY",
    provider_schema: [
      google_api_version: [
        type: {:in, ["v1", "v1beta"]},
        doc:
          "Google API version. Default is 'v1' for production stability. Set to 'v1beta' to enable beta features like Google Search grounding. When google_grounding is used without specifying a version, v1beta is automatically selected."
      ],
      google_safety_settings: [
        type: {:list, :map},
        doc: "Safety filter settings for content generation"
      ],
      google_candidate_count: [
        type: :pos_integer,
        default: 1,
        doc: "Number of response candidates to generate"
      ],
      google_thinking_budget: [
        type: :non_neg_integer,
        doc: "Thinking token budget for Gemini 2.5 models (0 disables thinking, omit for dynamic)"
      ],
      google_grounding: [
        type: :map,
        doc:
          "Enable Google Search grounding - allows model to search the web. Set to %{enable: true} for modern models, or %{dynamic_retrieval: %{mode: \"MODE_DYNAMIC\", dynamic_threshold: 0.7}} for Gemini 1.5 legacy support. Requires google_api_version: 'v1beta'"
      ],
      dimensions: [
        type: :pos_integer,
        doc:
          "Number of dimensions for the embedding vector (128-3072, recommended: 768, 1536, or 3072)"
      ],
      task_type: [
        type: :string,
        doc:
          "Task type for embedding (e.g., RETRIEVAL_QUERY, RETRIEVAL_DOCUMENT, SEMANTIC_SIMILARITY)"
      ]
    ]

  import ReqLLM.Provider.Utils,
    only: [maybe_put: 3, ensure_parsed_body: 1]

  require Logger

  defp has_grounding?(opts) do
    provider = Keyword.get(opts, :provider_options, [])

    case Keyword.get(provider, :google_grounding) do
      m when is_map(m) and map_size(m) > 0 -> true
      _ -> false
    end
  end

  defp resolve_api_version(opts) do
    provider = Keyword.get(opts, :provider_options, [])

    case Keyword.get(provider, :google_api_version) do
      "v1" -> "v1"
      "v1beta" -> "v1beta"
      _ -> nil
    end
  end

  defp effective_base_url(processed_opts) do
    case resolve_api_version(processed_opts) do
      "v1" ->
        "https://generativelanguage.googleapis.com/v1"

      "v1beta" ->
        "https://generativelanguage.googleapis.com/v1beta"

      nil ->
        if has_grounding?(processed_opts) do
          Logger.warning(
            "google_grounding requires v1beta; defaulting this request to v1beta. " <>
              "Set provider option google_api_version: \"v1beta\" to silence this message."
          )

          "https://generativelanguage.googleapis.com/v1beta"
        else
          Keyword.get(processed_opts, :base_url, default_base_url())
        end
    end
  end

  defp validate_version_feature_compat(processed_opts) do
    case {resolve_api_version(processed_opts), has_grounding?(processed_opts)} do
      {"v1", true} ->
        {:error,
         ReqLLM.Error.Invalid.Parameter.exception(
           parameter: ~s/google_grounding requires google_api_version: "v1beta"/
         )}

      _ ->
        :ok
    end
  end

  @doc """
  Custom prepare_request for chat operations to use Google's specific endpoints.

  Uses Google's :generateContent and :streamGenerateContent endpoints instead
  of the standard OpenAI /chat/completions endpoint.
  """
  @impl ReqLLM.Provider
  def prepare_request(:chat, model_spec, prompt, opts) do
    with {:ok, model} <- ReqLLM.Model.from(model_spec),
         {:ok, context} <- ReqLLM.Context.normalize(prompt, opts),
         opts_with_context = Keyword.put(opts, :context, context),
         {:ok, processed_opts0} <-
           ReqLLM.Provider.Options.process(__MODULE__, :chat, model, opts_with_context),
         :ok <- validate_version_feature_compat(processed_opts0) do
      processed_opts =
        Keyword.put(processed_opts0, :base_url, effective_base_url(processed_opts0))

      http_opts = Keyword.get(processed_opts, :req_http_options, [])

      # Determine endpoint based on streaming
      endpoint =
        if processed_opts[:stream], do: ":streamGenerateContent", else: ":generateContent"

      req_keys =
        __MODULE__.supported_provider_options() ++
          [:context, :operation, :text, :stream, :model, :provider_options]

      # Add alt=sse parameter for streaming requests
      base_params = if processed_opts[:stream], do: [alt: "sse"], else: []

      timeout =
        Keyword.get(
          processed_opts,
          :receive_timeout,
          Application.get_env(:req_llm, :receive_timeout, 30_000)
        )

      request =
        Req.new(
          [
            url: "/models/#{model.model}#{endpoint}",
            method: :post,
            params: base_params,
            receive_timeout: timeout
          ] ++ http_opts
        )
        |> Req.Request.register_options(req_keys)
        |> Req.Request.merge_options(
          Keyword.take(processed_opts, req_keys) ++
            [
              model: model.model,
              base_url: processed_opts[:base_url]
            ]
        )
        |> attach(model, processed_opts)

      {:ok, request}
    end
  end

  def prepare_request(:object, model_spec, prompt, opts) do
    if Keyword.has_key?(opts, :tools) and Keyword.get(opts, :tools) != [] do
      {:error,
       ReqLLM.Error.Invalid.Parameter.exception(
         parameter:
           "tools are not supported with :object operation on Google (JSON mode and tool calling are mutually exclusive on Gemini 2.5)"
       )}
    else
      with {:ok, model} <- ReqLLM.Model.from(model_spec),
           {:ok, context} <- ReqLLM.Context.normalize(prompt, opts) do
        opts_with_tokens =
          case Keyword.get(opts, :max_tokens) do
            nil -> Keyword.put(opts, :max_tokens, 4096)
            tokens when tokens < 200 -> Keyword.put(opts, :max_tokens, 200)
            _tokens -> opts
          end

        opts_with_context =
          opts_with_tokens
          |> Keyword.put(:context, context)
          |> Keyword.put(:operation, :object)

        case ReqLLM.Provider.Options.process(__MODULE__, :object, model, opts_with_context) do
          {:ok, processed_opts0} ->
            with :ok <- validate_version_feature_compat(processed_opts0) do
              processed_opts =
                Keyword.put(processed_opts0, :base_url, effective_base_url(processed_opts0))

              http_opts = Keyword.get(processed_opts, :req_http_options, [])

              endpoint =
                if processed_opts[:stream], do: ":streamGenerateContent", else: ":generateContent"

              req_keys =
                __MODULE__.supported_provider_options() ++
                  [
                    :context,
                    :operation,
                    :compiled_schema,
                    :text,
                    :stream,
                    :model,
                    :provider_options
                  ]

              base_params = if processed_opts[:stream], do: [alt: "sse"], else: []

              timeout =
                Keyword.get(
                  processed_opts,
                  :receive_timeout,
                  Application.get_env(:req_llm, :receive_timeout, 30_000)
                )

              request =
                Req.new(
                  [
                    url: "/models/#{model.model}#{endpoint}",
                    method: :post,
                    params: base_params,
                    receive_timeout: timeout
                  ] ++ http_opts
                )
                |> Req.Request.register_options(req_keys)
                |> Req.Request.merge_options(
                  Keyword.take(processed_opts, req_keys) ++
                    [
                      model: model.model,
                      base_url: processed_opts[:base_url]
                    ]
                )
                |> attach(model, processed_opts)

              {:ok, request}
            end

          {:error, reason} ->
            {:error, reason}
        end
      end
    end
  end

  def prepare_request(:embedding, model_spec, text, opts) do
    opts_normalized =
      case Keyword.pop(opts, :dimensions) do
        {nil, rest} ->
          rest

        {dimensions_value, rest} ->
          provider_options = Keyword.get(rest, :provider_options, [])
          updated_provider_options = Keyword.put(provider_options, :dimensions, dimensions_value)
          Keyword.put(rest, :provider_options, updated_provider_options)
      end

    with {:ok, model} <- ReqLLM.Model.from(model_spec),
         opts_with_text = Keyword.merge(opts_normalized, text: text, operation: :embedding),
         {:ok, processed_opts0} <-
           ReqLLM.Provider.Options.process(__MODULE__, :embedding, model, opts_with_text),
         :ok <- validate_version_feature_compat(processed_opts0) do
      processed_opts =
        Keyword.put(processed_opts0, :base_url, effective_base_url(processed_opts0))

      http_opts = Keyword.get(processed_opts, :req_http_options, [])

      endpoint =
        if is_list(text),
          do: ":batchEmbedContents",
          else: ":embedContent"

      req_keys =
        __MODULE__.supported_provider_options() ++
          [:context, :operation, :text, :stream, :model, :provider_options]

      timeout =
        Keyword.get(
          processed_opts,
          :receive_timeout,
          Application.get_env(:req_llm, :receive_timeout, 30_000)
        )

      request =
        Req.new(
          [
            url: "/models/#{model.model}#{endpoint}",
            method: :post,
            receive_timeout: timeout
          ] ++ http_opts
        )
        |> Req.Request.register_options(req_keys)
        |> Req.Request.merge_options(
          Keyword.take(processed_opts, req_keys) ++
            [
              model: model.model,
              base_url: processed_opts[:base_url]
            ]
        )
        |> attach(model, processed_opts)

      {:ok, request}
    end
  end

  # Delegate all other operations to defaults (which will return appropriate errors)
  def prepare_request(operation, model_spec, input, opts) do
    ReqLLM.Provider.Defaults.prepare_request(__MODULE__, operation, model_spec, input, opts)
  end

  @impl ReqLLM.Provider
  def attach(%Req.Request{} = request, model_input, user_opts) do
    %ReqLLM.Model{} = model = ReqLLM.Model.from!(model_input)

    if model.provider != provider_id() do
      raise ReqLLM.Error.Invalid.Provider.exception(provider: model.provider)
    end

    api_key = ReqLLM.Keys.get!(model, user_opts)

    # Register extra options that might be passed but aren't standard Req options
    extra_option_keys =
      [:model, :compiled_schema, :temperature, :max_tokens, :app_referer, :app_title, :fixture] ++
        __MODULE__.supported_provider_options()

    request
    # Google uses query parameter for API key, not Authorization header
    |> Req.Request.register_options(extra_option_keys)
    |> Req.Request.merge_options([model: model.model, params: [key: api_key]] ++ user_opts)
    |> ReqLLM.Step.Error.attach()
    |> ReqLLM.Step.Retry.attach()
    |> Req.Request.append_request_steps(llm_encode_body: &__MODULE__.encode_body/1)
    |> Req.Request.append_response_steps(llm_decode_response: &__MODULE__.decode_response/1)
    |> ReqLLM.Step.Usage.attach(model)
    |> ReqLLM.Step.Fixture.maybe_attach(model, user_opts)
  end

  @impl ReqLLM.Provider
  def extract_usage(body, _model) when is_map(body) do
    case body do
      %{"usageMetadata" => usage_metadata} ->
        usage = normalize_google_usage(usage_metadata)
        {:ok, usage}

      _ ->
        {:error, :no_usage_found}
    end
  end

  def extract_usage(_, _), do: {:error, :invalid_body}

  defp normalize_google_usage(usage_metadata) do
    input = Map.get(usage_metadata, "promptTokenCount", 0)
    total = Map.get(usage_metadata, "totalTokenCount", 0)
    cached = Map.get(usage_metadata, "cachedContentTokenCount", 0)
    reasoning = Map.get(usage_metadata, "thoughtsTokenCount", 0)

    output =
      case Map.get(usage_metadata, "candidatesTokenCount") do
        nil -> max(0, total - input - reasoning)
        count -> count
      end

    %{
      input_tokens: input,
      output_tokens: output,
      total_tokens: total,
      cached_tokens: cached,
      reasoning_tokens: reasoning
    }
  end

  def pre_validate_options(_operation, model, opts) do
    {provider_opts, rest} = Keyword.pop(opts, :provider_options, [])

    {effort, provider_opts} = Keyword.pop(provider_opts, :reasoning_effort)

    provider_opts =
      case effort do
        nil ->
          provider_opts

        effort_value ->
          budget = translate_reasoning_effort_to_budget(effort_value, model)

          case Keyword.fetch(provider_opts, :google_thinking_budget) do
            {:ok, existing} when is_integer(existing) and existing > 0 ->
              provider_opts

            {:ok, 0} ->
              Keyword.put(provider_opts, :google_thinking_budget, budget)

            :error ->
              Keyword.put(provider_opts, :google_thinking_budget, budget)
          end
      end

    {Keyword.put(rest, :provider_options, provider_opts), []}
  end

  defp translate_reasoning_effort_to_budget(:low, _model), do: 4096
  defp translate_reasoning_effort_to_budget(:medium, _model), do: 8192
  defp translate_reasoning_effort_to_budget(:high, _model), do: 16384

  defp translate_reasoning_effort_to_budget("low", model),
    do: translate_reasoning_effort_to_budget(:low, model)

  defp translate_reasoning_effort_to_budget("medium", model),
    do: translate_reasoning_effort_to_budget(:medium, model)

  defp translate_reasoning_effort_to_budget("high", model),
    do: translate_reasoning_effort_to_budget(:high, model)

  defp translate_reasoning_effort_to_budget(budget, _model) when is_integer(budget), do: budget
  defp translate_reasoning_effort_to_budget(_unknown, _model), do: 8192

  @impl ReqLLM.Provider
  def translate_options(_operation, _model, opts) do
    {reasoning_budget, opts} = Keyword.pop(opts, :reasoning_token_budget)
    {reasoning_effort, opts} = Keyword.pop(opts, :reasoning_effort)

    opts =
      cond do
        reasoning_budget ->
          provider_opts = Keyword.get(opts, :provider_options, [])
          provider_opts = Keyword.put(provider_opts, :google_thinking_budget, reasoning_budget)
          Keyword.put(opts, :provider_options, provider_opts)

        reasoning_effort ->
          budget = translate_reasoning_effort_to_budget(reasoning_effort, nil)
          provider_opts = Keyword.get(opts, :provider_options, [])
          provider_opts = Keyword.put(provider_opts, :google_thinking_budget, budget)
          Keyword.put(opts, :provider_options, provider_opts)

        true ->
          opts
      end

    case Keyword.pop(opts, :stream?) do
      {nil, rest} ->
        {rest, []}

      {stream_value, rest} ->
        {Keyword.put(rest, :stream, stream_value), []}
    end
  end

  # Req pipeline steps
  @impl ReqLLM.Provider
  def encode_body(request) do
    body =
      case request.options[:operation] do
        :embedding ->
          encode_embedding_body(request)

        :object ->
          encode_object_body(request)

        _ ->
          encode_chat_body(request)
      end

    try do
      encoded_body = Jason.encode!(body)

      request
      |> Req.Request.put_header("content-type", "application/json")
      |> Map.put(:body, encoded_body)
    rescue
      error ->
        reraise error, __STACKTRACE__
    end
  end

  defp encode_chat_body(request) do
    {system_instruction, contents} =
      case request.options[:context] do
        %ReqLLM.Context{} = ctx ->
          model_name = request.options[:model]
          # Convert OpenAI-style context to Gemini format
          encoded = ReqLLM.Provider.Defaults.encode_context_to_openai_format(ctx, model_name)
          messages = encoded[:messages] || encoded["messages"] || []
          split_messages_for_gemini(messages)

        _ ->
          split_messages_for_gemini(request.options[:messages] || [])
      end

    tools_data =
      case request.options[:tools] do
        tools when is_list(tools) and tools != [] ->
          tool_config = build_google_tool_config(request.options[:tool_choice])
          grounding_tools = build_grounding_tools(request.options[:google_grounding])

          user_tools = [
            %{functionDeclarations: Enum.map(tools, &ReqLLM.Tool.to_schema(&1, :google))}
          ]

          all_tools = grounding_tools ++ user_tools

          %{tools: all_tools}
          |> maybe_put(:toolConfig, tool_config)

        _ ->
          case build_grounding_tools(request.options[:google_grounding]) do
            [] -> %{}
            grounding_tools -> %{tools: grounding_tools}
          end
      end

    # Build generationConfig with Gemini-specific parameter names
    generation_config =
      %{}
      |> maybe_put(:temperature, request.options[:temperature])
      |> maybe_put(:maxOutputTokens, request.options[:max_tokens])
      |> maybe_put(:topP, request.options[:top_p])
      |> maybe_put(:topK, request.options[:top_k])
      |> maybe_put(:candidateCount, request.options[:google_candidate_count] || 1)
      |> maybe_add_thinking_config(request.options[:google_thinking_budget])

    %{}
    |> maybe_put(:systemInstruction, system_instruction)
    |> Map.put(:contents, contents)
    |> Map.merge(tools_data)
    |> maybe_put(:generationConfig, generation_config)
    |> maybe_put(:safetySettings, request.options[:google_safety_settings])
  end

  defp encode_embedding_body(request) do
    text = request.options[:text]

    build_embedding_body = fn t ->
      %{
        model: "models/#{request.options[:model]}",
        content: %{parts: [%{text: t}]}
      }
      |> maybe_put(:outputDimensionality, request.options[:dimensions])
      |> maybe_put(:taskType, request.options[:task_type])
    end

    case text do
      texts when is_list(texts) ->
        requests = Enum.map(texts, build_embedding_body)
        %{requests: requests}

      single_text when is_binary(single_text) ->
        build_embedding_body.(single_text)
    end
  end

  defp encode_object_body(request) do
    {system_instruction, contents} =
      case request.options[:context] do
        %ReqLLM.Context{} = ctx ->
          model_name = request.options[:model]
          encoded = ReqLLM.Provider.Defaults.encode_context_to_openai_format(ctx, model_name)
          messages = encoded[:messages] || encoded["messages"] || []
          split_messages_for_gemini(messages)

        _ ->
          split_messages_for_gemini(request.options[:messages] || [])
      end

    compiled_schema =
      case request.options do
        opts when is_map(opts) -> Map.get(opts, :compiled_schema)
        opts when is_list(opts) -> Keyword.get(opts, :compiled_schema)
      end

    if !compiled_schema do
      raise ArgumentError, "Missing :compiled_schema in request options for :object operation"
    end

    model_name = request.options[:model]

    generation_config =
      %{
        responseMimeType: "application/json",
        candidateCount: 1
      }
      |> maybe_put(:temperature, request.options[:temperature])
      |> maybe_put(:maxOutputTokens, request.options[:max_tokens])
      |> maybe_put(:topP, request.options[:top_p])
      |> maybe_put(:topK, request.options[:top_k])
      |> maybe_add_thinking_config(request.options[:google_thinking_budget])
      |> put_schema_for_model(model_name, compiled_schema)

    %{}
    |> maybe_put(:systemInstruction, system_instruction)
    |> Map.put(:contents, contents)
    |> maybe_put(:generationConfig, generation_config)
    |> maybe_put(:safetySettings, request.options[:google_safety_settings])
  end

  defp gemini_2_5?(model_name) when is_binary(model_name) do
    String.starts_with?(model_name, "gemini-2.5-") or model_name == "gemini-2.5"
  end

  defp gemini_2_5?(_), do: false

  defp put_schema_for_model(generation_config, model_name, compiled_schema) do
    json_schema = ReqLLM.Schema.to_json(compiled_schema.schema)

    if gemini_2_5?(model_name) and is_json_schema?(json_schema) do
      Map.put(generation_config, :responseJsonSchema, json_schema)
    else
      google_schema = convert_to_google_schema(json_schema)
      Map.put(generation_config, :responseSchema, google_schema)
    end
  end

  defp is_json_schema?(%{"type" => type}) when is_binary(type) do
    type in ["object", "array", "string", "number", "integer", "boolean", "null"]
  end

  defp is_json_schema?(_), do: false

  defp convert_to_google_schema(schema) when is_map(schema) do
    schema
    |> Map.delete("additionalProperties")
    |> Map.new(fn {key, value} ->
      case key do
        "type" -> {"type", to_google_type(value)}
        "properties" -> {"properties", convert_properties_to_google(value)}
        "items" when is_map(value) -> {"items", convert_to_google_schema(value)}
        "items" when is_list(value) -> raise_unsupported_schema("tuple arrays not supported")
        other -> {other, value}
      end
    end)
    |> maybe_add_property_ordering()
  end

  defp convert_to_google_schema(value), do: value

  defp to_google_type("object"), do: "OBJECT"
  defp to_google_type("array"), do: "ARRAY"
  defp to_google_type("string"), do: "STRING"
  defp to_google_type("integer"), do: "INTEGER"
  defp to_google_type("number"), do: "NUMBER"
  defp to_google_type("boolean"), do: "BOOLEAN"
  defp to_google_type("null"), do: "NULL"
  defp to_google_type(type), do: type

  defp convert_properties_to_google(properties) when is_map(properties) do
    Map.new(properties, fn {key, value} ->
      {key, convert_to_google_schema(value)}
    end)
  end

  defp maybe_add_property_ordering(schema) when is_map(schema) do
    case Map.get(schema, "properties") do
      properties when is_map(properties) and map_size(properties) > 0 ->
        if Map.has_key?(schema, "propertyOrdering") do
          schema
        else
          ordering = Map.keys(properties)
          Map.put(schema, "propertyOrdering", ordering)
        end

      _ ->
        schema
    end
  end

  defp raise_unsupported_schema(message) do
    raise ReqLLM.Error.Invalid.Parameter, parameter: "schema: #{message}"
  end

  defp normalize_embedding_response(%{"embedding" => %{"values" => values}})
       when is_list(values) do
    %{"data" => [%{"index" => 0, "embedding" => values}]}
  end

  defp normalize_embedding_response(%{"embeddings" => embeddings}) when is_list(embeddings) do
    data =
      embeddings
      |> Enum.with_index()
      |> Enum.map(fn
        {%{"values" => values}, idx} ->
          %{"index" => idx, "embedding" => values}

        {other, idx} ->
          vals = get_in(other, ["embedding", "values"]) || other["values"] || []
          %{"index" => idx, "embedding" => vals}
      end)

    %{"data" => data}
  end

  defp normalize_embedding_response(other), do: other

  @impl ReqLLM.Provider
  def decode_response({req, resp}) do
    case resp.status do
      200 ->
        operation = req.options[:operation]
        is_streaming = req.options[:stream] == true

        case operation do
          :embedding ->
            body = ensure_parsed_body(resp.body)
            normalized = normalize_embedding_response(body)
            {req, %{resp | body: normalized}}

          :object when not is_streaming ->
            model_name = req.options[:model]
            model = %ReqLLM.Model{provider: :google, model: model_name}

            body = ensure_parsed_body(resp.body)

            openai_format = convert_google_json_mode_to_openai_format(body)

            {:ok, response} =
              ReqLLM.Provider.Defaults.decode_response_body_openai_format(openai_format, model)

            # Extract and set object from JSON text content (like OpenAI json_schema mode)
            response_with_object =
              case ReqLLM.Response.unwrap_object(response) do
                {:ok, object} -> %{response | object: object}
                {:error, _} -> response
              end

            merged_response =
              ReqLLM.Context.merge_response(
                req.options[:context] || %ReqLLM.Context{messages: []},
                response_with_object
              )

            {req, %{resp | body: merged_response}}

          _ when is_streaming ->
            ReqLLM.Provider.Defaults.default_decode_response({req, resp})

          _ ->
            model_name = req.options[:model]
            model = %ReqLLM.Model{provider: :google, model: model_name}

            body = ensure_parsed_body(resp.body)

            openai_format = convert_google_to_openai_format(body)

            {:ok, response} =
              ReqLLM.Provider.Defaults.decode_response_body_openai_format(openai_format, model)

            response_with_grounding =
              case openai_format["grounding_metadata"] do
                nil ->
                  response

                grounding_data ->
                  %{
                    response
                    | provider_meta: Map.put(response.provider_meta, "google", grounding_data)
                  }
              end

            merged_response =
              ReqLLM.Context.merge_response(
                req.options[:context] || %ReqLLM.Context{messages: []},
                response_with_grounding
              )

            {req, %{resp | body: merged_response}}
        end

      status ->
        err =
          ReqLLM.Error.API.Response.exception(
            reason: "Google API error",
            status: status,
            response_body: resp.body
          )

        {req, err}
    end
  end

  # Helper to build Google toolConfig from OpenAI-style tool_choice
  defp build_google_tool_config(nil), do: nil

  defp build_google_tool_config(%{type: "function", function: %{name: name}}) do
    %{
      functionCallingConfig: %{
        mode: "ANY",
        allowedFunctionNames: [name]
      }
    }
  end

  defp build_google_tool_config(:required), do: build_google_tool_config("required")
  defp build_google_tool_config(:auto), do: build_google_tool_config("auto")
  defp build_google_tool_config(:none), do: build_google_tool_config("none")

  defp build_google_tool_config("required") do
    %{functionCallingConfig: %{mode: "ANY"}}
  end

  defp build_google_tool_config("auto"), do: %{functionCallingConfig: %{mode: "AUTO"}}
  defp build_google_tool_config("none"), do: %{functionCallingConfig: %{mode: "NONE"}}
  defp build_google_tool_config(_), do: nil

  defp build_grounding_tools(nil), do: []
  defp build_grounding_tools(%{enable: true}), do: [%{google_search: %{}}]

  defp build_grounding_tools(%{dynamic_retrieval: config}) when is_map(config) do
    [%{google_search_retrieval: %{dynamic_retrieval_config: config}}]
  end

  defp build_grounding_tools(_), do: []

  defp extract_grounding_metadata(%{"candidates" => [candidate | _]}) do
    case candidate do
      %{"groundingMetadata" => metadata} when is_map(metadata) ->
        sources =
          case metadata["groundingChunks"] do
            chunks when is_list(chunks) ->
              Enum.map(chunks, fn chunk ->
                case chunk do
                  %{"web" => %{"uri" => uri, "title" => title}} ->
                    %{"uri" => uri, "title" => title}

                  %{"web" => %{"uri" => uri}} ->
                    %{"uri" => uri}

                  _ ->
                    nil
                end
              end)
              |> Enum.reject(&is_nil/1)

            _ ->
              []
          end

        %{
          "grounding_metadata" => metadata,
          "sources" => sources
        }

      _ ->
        nil
    end
  end

  defp extract_grounding_metadata(_), do: nil

  # Helper to add thinking configuration if specified
  defp maybe_add_thinking_config(config, nil), do: config

  defp maybe_add_thinking_config(config, budget) when is_integer(budget) and budget > 0 do
    Map.put(config, :thinkingConfig, %{thinkingBudget: budget, includeThoughts: true})
  end

  defp maybe_add_thinking_config(config, 0) do
    config
  end

  defp convert_google_to_openai_format(%{"candidates" => candidates} = body) do
    choice =
      case List.first(candidates) do
        %{"content" => %{"parts" => parts}} = candidate ->
          {content_parts, has_thinking?} = convert_google_parts_to_content(parts)
          tool_calls = extract_tool_calls(parts)

          message =
            if has_thinking? or tool_calls != [] do
              %{
                "role" => "assistant",
                "content" => content_parts
              }
            else
              text_content =
                content_parts
                |> Enum.filter(&(&1["type"] == "text"))
                |> Enum.map_join("", & &1["text"])

              %{
                "role" => "assistant",
                "content" => text_content
              }
            end

          message =
            case tool_calls do
              [] -> message
              _ -> Map.put(message, "tool_calls", tool_calls)
            end

          %{
            "message" => message,
            "finish_reason" => normalize_google_finish_reason(candidate["finishReason"])
          }

        %{"content" => content, "finishReason" => finish_reason} when is_map(content) ->
          %{
            "message" => %{"role" => "assistant", "content" => ""},
            "finish_reason" => normalize_google_finish_reason(finish_reason)
          }

        _ ->
          %{
            "message" => %{"role" => "assistant", "content" => ""},
            "finish_reason" => "stop"
          }
      end

    grounding_metadata = extract_grounding_metadata(body)

    base_response = %{
      "id" => body["id"] || "google-#{System.unique_integer([:positive])}",
      "choices" => [choice],
      "usage" => convert_google_usage(body["usageMetadata"])
    }

    if grounding_metadata do
      Map.put(base_response, "grounding_metadata", grounding_metadata)
    else
      base_response
    end
  end

  defp convert_google_to_openai_format(body), do: body

  defp convert_google_json_mode_to_openai_format(%{"candidates" => candidates} = body) do
    choice =
      case List.first(candidates) do
        %{"content" => %{"parts" => parts}} = candidate ->
          json_text =
            parts
            |> Enum.filter(&Map.has_key?(&1, "text"))
            |> Enum.map_join("", & &1["text"])

          # Return as text content (like OpenAI json_schema mode)
          # ReqLLM.Response.unwrap_object will parse the JSON
          %{
            "message" => %{
              "role" => "assistant",
              "content" => json_text
            },
            "finish_reason" => normalize_google_finish_reason(candidate["finishReason"])
          }

        _ ->
          %{
            "message" => %{"role" => "assistant", "content" => ""},
            "finish_reason" => "stop"
          }
      end

    %{
      "id" => body["id"] || "google-#{System.unique_integer([:positive])}",
      "choices" => [choice],
      "usage" => convert_google_usage(body["usageMetadata"])
    }
  end

  defp convert_google_json_mode_to_openai_format(body), do: body

  defp convert_google_parts_to_content(parts) do
    content_parts =
      parts
      |> Enum.filter(&Map.has_key?(&1, "text"))
      |> Enum.map(fn part ->
        if Map.get(part, "thought", false) do
          %{"type" => "thinking", "thinking" => part["text"]}
        else
          %{"type" => "text", "text" => part["text"]}
        end
      end)

    has_thinking? = Enum.any?(content_parts, &(&1["type"] == "thinking"))
    {content_parts, has_thinking?}
  end

  defp extract_tool_calls(parts) do
    for %{"functionCall" => %{} = call} <- parts do
      call_id = Map.get(call, "id", "tool_call_#{System.unique_integer([:positive])}")

      encoded_args =
        call
        |> Map.get("args", %{})
        |> Jason.encode!()

      %{
        "id" => call_id,
        "type" => "function",
        "function" => %{
          "name" => call["name"],
          "arguments" => encoded_args
        }
      }
    end
  end

  defp normalize_google_finish_reason("STOP"), do: "stop"
  defp normalize_google_finish_reason("MAX_TOKENS"), do: "length"
  defp normalize_google_finish_reason("SAFETY"), do: "content_filter"
  defp normalize_google_finish_reason("RECITATION"), do: "content_filter"
  defp normalize_google_finish_reason("OTHER"), do: "error"
  defp normalize_google_finish_reason(_), do: "error"

  defp convert_google_usage(%{"promptTokenCount" => prompt, "totalTokenCount" => total} = usage) do
    thoughts = usage["thoughtsTokenCount"] || 0

    completion =
      usage["candidatesTokenCount"] ||
        max(0, total - prompt - thoughts)

    base = %{
      "prompt_tokens" => prompt,
      "completion_tokens" => completion,
      "total_tokens" => total
    }

    if thoughts > 0 do
      Map.put(base, "completion_tokens_details", %{"reasoning_tokens" => thoughts})
    else
      base
    end
  end

  defp convert_google_usage(_),
    do: %{"prompt_tokens" => 0, "completion_tokens" => 0, "total_tokens" => 0}

  defp build_request_headers(_model, _opts), do: [{"Content-Type", "application/json"}]

  defp build_request_url(model_name, opts) do
    api_key = ReqLLM.Keys.get!(opts[:model_struct] || opts[:model], opts)
    base_url = Keyword.get(opts, :base_url, default_base_url())

    "#{base_url}/models/#{model_name}:streamGenerateContent?key=#{api_key}&alt=sse"
  end

  defp build_request_body(model, context, opts) do
    operation = Keyword.get(opts, :operation, :chat)
    compiled_schema = Keyword.get(opts, :compiled_schema)

    base_options =
      [
        model: model.model,
        context: context,
        stream: true,
        operation: operation
      ]
      |> then(fn opts ->
        if compiled_schema, do: Keyword.put(opts, :compiled_schema, compiled_schema), else: opts
      end)

    all_options = Keyword.merge(base_options, Keyword.delete(opts, :finch_name))

    temp_request =
      Req.new(method: :post, url: URI.parse("https://example.com/temp"))
      |> Map.put(:body, {:json, %{}})
      |> Map.put(:options, Map.new(all_options))

    encoded_request = encode_body(temp_request)
    encoded_request.body
  end

  @impl ReqLLM.Provider
  def attach_stream(model, context, opts, _finch_name) do
    req_only_keys = [:params, :model, :base_url, :finch_name, :fixture]
    {req_opts, user_opts} = Keyword.split(opts, req_only_keys)

    operation = Keyword.get(user_opts, :operation, :chat)
    opts_to_process = Keyword.merge(user_opts, context: context, stream: true)

    with {:ok, processed_opts} <-
           ReqLLM.Provider.Options.process(__MODULE__, operation, model, opts_to_process) do
      base_url = Keyword.get(req_opts, :base_url, default_base_url())

      opts_with_base = Keyword.merge(processed_opts, base_url: base_url, model_struct: model)

      headers = build_request_headers(model, opts_with_base) ++ [{"Accept", "text/event-stream"}]
      url = build_request_url(model.model, opts_with_base)
      body = build_request_body(model, context, processed_opts)

      finch_request = Finch.build(:post, url, headers, body)
      {:ok, finch_request}
    end
  rescue
    error ->
      {:error,
       ReqLLM.Error.API.Request.exception(
         reason: "Failed to build Google stream request: #{inspect(error)}"
       )}
  end

  @impl ReqLLM.Provider
  def decode_sse_event(event, model) do
    case event do
      %{data: data} when is_map(data) -> decode_google_event(data, model)
      data when is_map(data) -> decode_google_event(data, model)
      _ -> []
    end
  end

  # Split messages into system instruction and contents for Google Gemini
  defp split_messages_for_gemini(messages) do
    {system_msgs, chat_msgs} =
      Enum.split_with(messages, fn message ->
        case message do
          %{role: :system} -> true
          %{"role" => "system"} -> true
          %{"role" => :system} -> true
          %{role: "system"} -> true
          _ -> false
        end
      end)

    system_instruction =
      case system_msgs do
        [] ->
          nil

        system_messages ->
          combined_text =
            system_messages
            |> Enum.map_join("\n\n", &extract_text_content/1)

          %{parts: [%{text: combined_text}]}
      end

    contents = convert_messages_to_gemini(chat_msgs)

    {system_instruction, contents}
  end

  defp convert_messages_to_gemini(messages) do
    Enum.map(messages, fn message ->
      raw_role =
        case message do
          %{role: role} -> role
          %{"role" => role} -> role
          _ -> "user"
        end

      role =
        case raw_role do
          :user -> "user"
          "user" -> "user"
          :assistant -> "model"
          "assistant" -> "model"
          :tool -> "user"
          "tool" -> "user"
          :system -> "user"
          "system" -> "user"
          other when is_binary(other) -> other
          other -> to_string(other)
        end

      raw_content =
        case message do
          %{content: content} -> content
          %{"content" => content} -> content
          _ -> ""
        end

      content_parts =
        case raw_content do
          content when is_binary(content) -> [%{text: content}]
          parts when is_list(parts) -> Enum.map(parts, &convert_content_part/1)
        end

      tool_call_parts =
        case message do
          %{"tool_calls" => tool_calls} when is_list(tool_calls) ->
            Enum.map(tool_calls, &convert_tool_call_to_function_call/1)

          %{tool_calls: tool_calls} when is_list(tool_calls) ->
            Enum.map(tool_calls, &convert_tool_call_to_function_call/1)

          _ ->
            []
        end

      tool_result_parts =
        case message do
          %{"tool_call_id" => _call_id, "role" => "tool"} ->
            [
              %{
                functionResponse: %{
                  name: "unknown",
                  response: %{content: extract_content_text(raw_content)}
                }
              }
            ]

          %{tool_call_id: _call_id, role: :tool} ->
            [
              %{
                functionResponse: %{
                  name: "unknown",
                  response: %{content: extract_content_text(raw_content)}
                }
              }
            ]

          _ ->
            []
        end

      parts = content_parts ++ tool_call_parts ++ tool_result_parts

      %{role: role, parts: parts}
    end)
  end

  defp convert_tool_call_to_function_call(%ReqLLM.ToolCall{
         type: "function",
         function: %{name: name, arguments: args},
         id: id
       }) do
    %{functionCall: %{name: name, args: Jason.decode!(args), id: id}}
  end

  defp convert_tool_call_to_function_call(%{
         "type" => "function",
         "function" => %{"name" => name, "arguments" => args},
         "id" => id
       }) do
    %{functionCall: %{name: name, args: Jason.decode!(args), id: id}}
  end

  defp convert_tool_call_to_function_call(%{
         type: "function",
         function: %{name: name, arguments: args},
         id: id
       }) do
    %{functionCall: %{name: name, args: Jason.decode!(args), id: id}}
  end

  defp convert_tool_call_to_function_call(_), do: nil

  defp extract_content_text(content) when is_binary(content), do: content

  defp extract_content_text(parts) when is_list(parts) do
    parts
    |> Enum.map_join("", fn
      %{"type" => "text", "text" => text} -> text
      %{type: :text, text: text} -> text
      text when is_binary(text) -> text
      _ -> ""
    end)
  end

  defp extract_content_text(_), do: ""

  # Extract text content from a message for system instruction
  defp extract_text_content(%{content: content}) when is_binary(content), do: content
  defp extract_text_content(%{"content" => content}) when is_binary(content), do: content

  defp extract_text_content(%{content: parts}) when is_list(parts) do
    extract_parts_text(parts)
  end

  defp extract_text_content(%{"content" => parts}) when is_list(parts) do
    extract_parts_text(parts)
  end

  defp extract_text_content(content) when is_binary(content), do: content
  defp extract_text_content(_), do: ""

  defp extract_parts_text(parts) do
    parts
    |> Enum.map_join("", fn
      %{type: :text, content: text} -> text
      %{"type" => "text", "text" => text} -> text
      %{text: text} -> text
      %{"text" => text} -> text
      text when is_binary(text) -> text
      part -> to_string(part)
    end)
  end

  # Handle OpenAI-format image_url (from Provider.Defaults.encode_openai_content_part)
  defp convert_content_part(%{type: "image_url", image_url: %{url: url}}) when is_binary(url) do
    # Parse data URI format: data:mime/type;base64,<data>
    case String.split(url, ",", parts: 2) do
      [header, base64_data] ->
        mime_type =
          case Regex.run(~r/data:([^;]+)/, header) do
            [_, type] -> type
            _ -> "image/jpeg"
          end

        %{
          inline_data: %{
            mime_type: mime_type,
            data: base64_data
          }
        }

      _ ->
        # Not a data URI, might be a URL
        %{text: "[Unsupported image URL]"}
    end
  end

  # Most specific patterns first (file, image, etc.) - for ContentPart structs
  defp convert_content_part(%{type: :file, data: data, media_type: media_type})
       when is_binary(data) do
    encoded_data = Base.encode64(data)

    %{
      inline_data: %{
        mime_type: media_type,
        data: encoded_data
      }
    }
  end

  # Specific text patterns
  defp convert_content_part(%{type: :text, content: text}), do: %{text: text}
  defp convert_content_part(%{"type" => "text", "text" => text}), do: %{text: text}

  # Generic catch-all patterns (must come after specific patterns)
  defp convert_content_part(%{text: text}) when is_binary(text), do: %{text: text}
  defp convert_content_part(%{"text" => text}) when is_binary(text), do: %{text: text}
  defp convert_content_part(text) when is_binary(text), do: %{text: text}

  defp convert_content_part(part), do: %{text: to_string(part)}

  # Decode Google streaming events.
  #
  # Google's :streamGenerateContent endpoint returns JSON array format (not SSE) for 2.5 models.
  # This function handles both formats:
  # - SSE format: %{data: {...}}
  # - JSON array element: raw map from parsed JSON array
  defp decode_google_event(data, model) when is_map(data) do
    case data do
      %{
        "candidates" => [%{"content" => %{"parts" => parts}, "finishReason" => finish_reason} | _],
        "usageMetadata" => usage
      }
      when finish_reason != nil ->
        chunks = extract_chunks_from_parts(parts)

        usage_chunk =
          ReqLLM.StreamChunk.meta(%{
            usage: convert_google_usage_for_streaming(usage),
            finish_reason: normalize_google_finish_reason(finish_reason),
            model: model.model,
            terminal?: true
          })

        chunks ++ [usage_chunk]

      %{
        "candidates" => [%{"content" => %{"parts" => parts}, "finishReason" => finish_reason} | _]
      }
      when finish_reason != nil ->
        chunks = extract_chunks_from_parts(parts)

        meta_chunk =
          ReqLLM.StreamChunk.meta(%{
            finish_reason: normalize_google_finish_reason(finish_reason),
            terminal?: true
          })

        chunks ++ [meta_chunk]

      %{"candidates" => [%{"content" => %{"parts" => parts}} | _], "usageMetadata" => usage} ->
        chunks = extract_chunks_from_parts(parts)

        usage_chunk =
          ReqLLM.StreamChunk.meta(%{
            usage: convert_google_usage_for_streaming(usage),
            model: model.model
          })

        chunks ++ [usage_chunk]

      %{"candidates" => [%{"content" => %{"parts" => parts}} | _]} ->
        extract_chunks_from_parts(parts)

      %{"usageMetadata" => usage} ->
        [
          ReqLLM.StreamChunk.meta(%{
            usage: convert_google_usage_for_streaming(usage),
            model: model.model,
            terminal?: true
          })
        ]

      _ ->
        []
    end
  end

  defp extract_chunks_from_parts(parts) do
    parts
    |> Enum.flat_map(fn part ->
      cond do
        Map.has_key?(part, "text") ->
          text = Map.get(part, "text")

          if text == "" do
            []
          else
            if Map.get(part, "thought", false) do
              [ReqLLM.StreamChunk.thinking(text)]
            else
              [ReqLLM.StreamChunk.text(text)]
            end
          end

        Map.has_key?(part, "functionCall") ->
          call = part["functionCall"]
          name = call["name"]
          args = call["args"] || %{}
          call_id = Map.get(call, "id", "call_#{System.unique_integer([:positive])}")
          [ReqLLM.StreamChunk.tool_call(name, args, %{id: call_id})]

        true ->
          []
      end
    end)
  end

  defp convert_google_usage_for_streaming(nil),
    do: %{
      input_tokens: 0,
      output_tokens: 0,
      total_tokens: 0,
      cached_tokens: 0,
      reasoning_tokens: 0
    }

  defp convert_google_usage_for_streaming(usage_metadata) do
    normalize_google_usage(usage_metadata)
  end
end
