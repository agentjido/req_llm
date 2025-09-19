defmodule ReqLLM.Providers.Google do
  @moduledoc """
  Google Gemini provider – fully compatible with the OpenAI baseline pattern.

  ## Protocol Usage

  Uses custom `ReqLLM.Providers.Google.Context` and `ReqLLM.Providers.Google.Response` codecs
  to handle Gemini's specific API format while maintaining OpenAI-compatible interfaces.

  ## Google-Specific Extensions

  Beyond standard OpenAI parameters, Google supports:
  - `safety_settings` - List of safety filter configurations
  - `candidate_count` - Number of response candidates to generate (default: 1)

  See `provider_schema/0` for the complete Google-specific schema and
  `ReqLLM.Provider.Options` for inherited OpenAI parameters.

  ## Configuration

      # Add to .env file (automatically loaded)
      GOOGLE_API_KEY=AIza...
  """

  @behaviour ReqLLM.Provider

  use ReqLLM.Provider.DSL,
    id: :google,
    base_url: "https://generativelanguage.googleapis.com/v1beta",
    metadata: "priv/models_dev/google.json",
    default_env_key: "GOOGLE_API_KEY",
    provider_schema: [
      google_safety_settings: [
        type: {:list, :map},
        doc: "Safety filter settings for content generation"
      ],
      google_candidate_count: [
        type: :pos_integer,
        default: 1,
        doc: "Number of response candidates to generate"
      ],
      dimensions: [
        type: :pos_integer,
        doc: "Number of dimensions for the embedding vector (128-3072, recommended: 768, 1536, or 3072)"
      ]
    ]

  import ReqLLM.Provider.Utils,
    only: [maybe_put: 3, ensure_parsed_body: 1]

  require Logger

  # Helper for validation and translation (copied from Groq)
  defp validate_and_translate!(provider_mod, model, raw_opts) do
    # Separate context and special test/internal options from user options
    {context, remaining_opts} = Keyword.pop(raw_opts, :context)

    # Extract internal/test options that shouldn't be validated
    internal_keys = [:req_options, :on_unsupported, :fixture, :req_http_options, :compiled_schema, :operation, :text]
    {internal_opts, user_opts} = Keyword.split(remaining_opts, internal_keys)

    schema = provider_mod.provider_extended_generation_schema()
    {:ok, valid_opts} = NimbleOptions.validate(user_opts, schema)

    # Apply provider-specific translations
    translated_opts =
      case provider_mod.translate_options(:chat, model, valid_opts) do
        {translated_opts, warnings} when is_list(warnings) ->
          # Emit warnings to the logger
          Enum.each(warnings, &Logger.warning/1)
          translated_opts

        translated_opts ->
          translated_opts
      end

    # Merge back all the options
    final_opts = Keyword.merge(translated_opts, internal_opts)

    if context do
      Keyword.put(final_opts, :context, context)
    else
      final_opts
    end
  end

  @doc """
  Attaches the Google plugin to a Req request.

  ## Parameters

    * `request` - The Req request to attach to
    * `model_input` - The model (ReqLLM.Model struct, string, or tuple) that triggers this provider
    * `opts` - Options keyword list (validated against comprehensive schema)

  ## Request Options

    * `:temperature` - Controls randomness (0.0-2.0). Defaults to 0.7
    * `:max_tokens` - Maximum tokens to generate. Defaults to 1024
    * `:stream?` - Enable streaming responses. Defaults to false
    * `:base_url` - Override base URL. Defaults to provider default
    * `:messages` - Chat messages to send
    * `:system` - System message
    * `:google_safety_settings` - List of safety filter configurations
    * `:google_candidate_count` - Number of response candidates to generate
    * All options from ReqLLM.Provider.Options schemas are supported

  """
  @impl ReqLLM.Provider
  def prepare_request(:chat, model_input, %ReqLLM.Context{} = context, opts) do
    with {:ok, model} <- ReqLLM.Model.from(model_input) do
      http_opts = Keyword.get(opts, :req_http_options, [])

      # Determine endpoint based on streaming
      endpoint = if opts[:stream], do: ":streamGenerateContent", else: ":generateContent"

      request =
        Req.new(
          [url: "/models/#{model.model}#{endpoint}", method: :post, receive_timeout: 30_000] ++
            http_opts
        )
        |> attach(model, Keyword.put(opts, :context, context))

      {:ok, request}
    end
  end

  def prepare_request(:object, model_input, %ReqLLM.Context{} = context, opts) do
    compiled_schema = Keyword.fetch!(opts, :compiled_schema)

    structured_output_tool =
      ReqLLM.Tool.new!(
        name: "structured_output",
        description: "Generate structured output matching the provided schema",
        parameter_schema: compiled_schema.schema,
        callback: fn _args -> {:ok, "structured output generated"} end
      )

    opts_with_tool =
      Keyword.update(opts, :tools, [structured_output_tool], fn tools ->
        [structured_output_tool | tools]
      end)

    opts_with_choice =
      Keyword.put(opts_with_tool, :tool_choice, %{
        type: "function",
        function: %{name: "structured_output"}
      })

    opts_with_max_tokens =
      case Keyword.get(opts_with_choice, :max_tokens) do
        nil -> Keyword.put(opts_with_choice, :max_tokens, 4096)
        tokens when tokens < 200 -> Keyword.put(opts_with_choice, :max_tokens, 200)
        _value -> opts_with_choice
      end

    prepare_request(:chat, model_input, context, opts_with_max_tokens)
  end

  def prepare_request(:embedding, model_input, text, opts) do
    with {:ok, model} <- ReqLLM.Model.from(model_input) do
      http_opts = Keyword.get(opts, :req_http_options, [])

      request =
        Req.new([url: "/models/#{model.model}:embedContent", method: :post, receive_timeout: 30_000] ++ http_opts)
        |> attach(model, Keyword.merge(opts, text: text, operation: :embedding))

      {:ok, request}
    end
  end

  def prepare_request(operation, _model, _input, _opts) do
    {:error,
     ReqLLM.Error.Invalid.Parameter.exception(
       parameter:
         "operation: #{inspect(operation)} not supported by Google provider. Supported operations: [:chat, :object, :embedding]"
     )}
  end

  @spec attach(Req.Request.t(), ReqLLM.Model.t() | String.t() | {atom(), keyword()}, keyword()) ::
          Req.Request.t()
  @impl ReqLLM.Provider
  def attach(%Req.Request{} = request, model_input, user_opts \\ []) do
    %ReqLLM.Model{} = model = ReqLLM.Model.from!(model_input)

    if model.provider != provider_id() do
      raise ReqLLM.Error.Invalid.Provider.exception(provider: model.provider)
    end

    api_key = ReqLLM.Keys.get!(model, user_opts)
    {tools, other_opts} = Keyword.pop(user_opts, :tools, [])
    provider_opts = Keyword.get(other_opts, :provider_options, [])
    {_provider_options, core_opts} = Keyword.pop(other_opts, :provider_options, [])

    # Use new validation approach
    opts = validate_and_translate!(__MODULE__, model, core_opts)
    opts = Keyword.put(opts, :tools, tools)
    opts = Keyword.merge(opts, provider_opts)

    base_url = Keyword.get(user_opts, :base_url, default_base_url())
    req_keys = __MODULE__.supported_provider_options() ++ [:context, :operation, :text]
    model_name = model.model

    request
    |> Req.Request.register_options(req_keys ++ [:model])
    # Google uses query parameter for API key, not Authorization header
    |> Req.Request.merge_options(
      Keyword.take(opts, req_keys) ++
        [model: model_name, base_url: base_url, params: [key: api_key]]
    )
    |> ReqLLM.Step.Error.attach()
    |> Req.Request.append_request_steps(llm_encode_body: &__MODULE__.encode_body/1)
    |> ReqLLM.Step.Stream.maybe_attach(opts[:stream])
    |> Req.Request.append_response_steps(llm_decode_response: &__MODULE__.decode_response/1)
    |> ReqLLM.Step.Usage.attach(model)
  end

  @impl ReqLLM.Provider
  def extract_usage(body, _model) when is_map(body) do
    case body do
      %{"usageMetadata" => usage} -> {:ok, usage}
      _ -> {:error, :no_usage_found}
    end
  end

  def extract_usage(_, _), do: {:error, :invalid_body}

  @impl ReqLLM.Provider
  def translate_options(_operation, _model, opts) do
    # Handle stream? -> stream alias for backward compatibility
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
    context_data =
      case request.options[:context] do
        %ReqLLM.Context{} = ctx ->
          model = request.options[:model]
          # Convert OpenAI-style context to Gemini format
          encoded = ReqLLM.Context.Codec.encode_request(ctx, model)
          messages = encoded[:messages] || encoded["messages"] || []
          %{contents: convert_messages_to_gemini(messages)}

        _ ->
          %{contents: convert_messages_to_gemini(request.options[:messages] || [])}
      end

    tools_data =
      case request.options[:tools] do
        tools when is_list(tools) and tools != [] ->
          %{
            tools: [%{functionDeclarations: Enum.map(tools, &ReqLLM.Tool.to_schema(&1, :google))}]
          }

        _ ->
          %{}
      end

    # Build generationConfig with Gemini-specific parameter names
    generation_config =
      %{}
      |> maybe_put(:temperature, request.options[:temperature])
      |> maybe_put(:maxOutputTokens, request.options[:max_tokens])
      |> maybe_put(:topP, request.options[:top_p])
      |> maybe_put(:topK, request.options[:top_k])
      |> maybe_put(:candidateCount, request.options[:google_candidate_count] || 1)

    %{}
    |> Map.merge(context_data)
    |> Map.merge(tools_data)
    |> maybe_put(:generationConfig, generation_config)
    |> maybe_put(:safetySettings, request.options[:google_safety_settings])
  end

  defp encode_embedding_body(request) do
    %{
      model: "models/#{request.options[:model]}",
      content: %{
        parts: [%{text: request.options[:text]}]
      }
    }
    |> maybe_put(:outputDimensionality, request.options[:dimensions])
  end

  @impl ReqLLM.Provider
  def decode_response({req, resp}) do
    case resp.status do
      200 ->
        operation = req.options[:operation]

        case operation do
          :embedding ->
            # Handle embedding response - return raw parsed data
            body = ensure_parsed_body(resp.body)
            {req, %{resp | body: body}}

          _ ->
            # Handle chat completion response
            model_name = req.options[:model]
            model = %ReqLLM.Model{provider: :google, model: model_name}
            is_streaming = req.options[:stream] == true

            if is_streaming do
              chunk_stream =
                resp.body
                |> Stream.flat_map(&ReqLLM.Response.Codec.decode_sse_event(&1, model))
                |> Stream.reject(&is_nil/1)

              response = %ReqLLM.Response{
                id: "stream-#{System.unique_integer([:positive])}",
                model: model_name,
                context: req.options[:context] || %ReqLLM.Context{messages: []},
                message: nil,
                stream?: true,
                stream: chunk_stream,
                usage: %{input_tokens: 0, output_tokens: 0, total_tokens: 0},
                finish_reason: nil,
                provider_meta: %{}
              }

              {req, %{resp | body: response}}
            else
              body = ensure_parsed_body(resp.body)

              # Convert Google format to OpenAI format, then decode
              openai_format = convert_google_to_openai_format(body)
              {:ok, response} = ReqLLM.Response.Codec.decode_response(openai_format, model)

              # Merge original context with the assistant response
              merged_response =
                ReqLLM.Context.merge_response(
                  req.options[:context] || %ReqLLM.Context{messages: []},
                  response
                )

              {req, %{resp | body: merged_response}}
            end
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

  # Helper to convert Google response to OpenAI format
  defp convert_google_to_openai_format(%{"candidates" => candidates} = body) do
    choice =
      case List.first(candidates) do
        %{"content" => %{"parts" => parts}} = candidate ->
          message_content =
            parts
            |> Enum.filter(&Map.has_key?(&1, "text"))
            |> Enum.map_join("", &Map.get(&1, "text"))

          %{
            "message" => %{
              "role" => "assistant",
              "content" => message_content
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

  defp convert_google_to_openai_format(body), do: body

  defp normalize_google_finish_reason("STOP"), do: "stop"
  defp normalize_google_finish_reason("MAX_TOKENS"), do: "length"
  defp normalize_google_finish_reason("SAFETY"), do: "content_filter"
  defp normalize_google_finish_reason("RECITATION"), do: "content_filter"
  defp normalize_google_finish_reason(_), do: "stop"

  defp convert_google_usage(%{
         "promptTokenCount" => prompt,
         "candidatesTokenCount" => completion,
         "totalTokenCount" => total
       }) do
    %{
      "prompt_tokens" => prompt,
      "completion_tokens" => completion,
      "total_tokens" => total
    }
  end

  defp convert_google_usage(_),
    do: %{"prompt_tokens" => 0, "completion_tokens" => 0, "total_tokens" => 0}

  # Helper to convert OpenAI-style messages to Gemini format
  defp convert_messages_to_gemini(messages) do
    Enum.map(messages, fn message ->
      role =
        case message.role do
          :system -> "system"
          :user -> "user"
          :assistant -> "model"
          role when is_binary(role) -> role
          role -> to_string(role)
        end

      parts =
        case message.content do
          content when is_binary(content) -> [%{text: content}]
          parts when is_list(parts) -> Enum.map(parts, &convert_content_part/1)
        end

      %{role: role, parts: parts}
    end)
  end

  defp convert_content_part(%{type: :text, content: text}), do: %{text: text}
  defp convert_content_part(%{text: text}), do: %{text: text}
  defp convert_content_part(text) when is_binary(text), do: %{text: text}
  # TODO: Add support for images, audio, video when multimodal support is added
  defp convert_content_part(part), do: %{text: to_string(part)}
end
