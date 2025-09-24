defmodule ReqLLM.Providers.Google do
  @moduledoc """
  Google Gemini provider – built on the OpenAI baseline defaults with Gemini-specific customizations.

  ## Protocol Usage

  Uses the generic `ReqLLM.Context.Codec` and `ReqLLM.Response.Codec` protocols
  with custom encoding/decoding to translate between OpenAI format and Gemini API format.

  ## Google-Specific Extensions

  Beyond standard OpenAI parameters, Google supports:
  - `google_safety_settings` - List of safety filter configurations
  - `google_candidate_count` - Number of response candidates to generate (default: 1)
  - `dimensions` - Number of dimensions for embedding vectors

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
        doc:
          "Number of dimensions for the embedding vector (128-3072, recommended: 768, 1536, or 3072)"
      ]
    ]

  import ReqLLM.Provider.Utils,
    only: [maybe_put: 3, ensure_parsed_body: 1]

  require Logger

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
         {:ok, processed_opts} <-
           ReqLLM.Provider.Options.process(__MODULE__, :chat, model, opts_with_context) do
      http_opts = Keyword.get(processed_opts, :req_http_options, [])

      # Determine endpoint based on streaming
      endpoint =
        if processed_opts[:stream], do: ":streamGenerateContent", else: ":generateContent"

      req_keys =
        __MODULE__.supported_provider_options() ++
          [:context, :operation, :text, :stream, :model, :provider_options]

      request =
        Req.new(
          [
            url: "/models/#{model.model}#{endpoint}",
            method: :post,
            receive_timeout: Keyword.get(processed_opts, :receive_timeout, 30_000)
          ] ++ http_opts
        )
        |> Req.Request.register_options(req_keys)
        |> Req.Request.merge_options(
          Keyword.take(processed_opts, req_keys) ++
            [
              model: model.model,
              base_url: Keyword.get(processed_opts, :base_url, default_base_url())
            ]
        )
        |> attach(model, processed_opts)

      {:ok, request}
    end
  end

  def prepare_request(:object, model_spec, prompt, opts) do
    compiled_schema = Keyword.fetch!(opts, :compiled_schema)

    structured_output_tool =
      ReqLLM.Tool.new!(
        name: "structured_output",
        description: "Generate structured output matching the provided schema",
        parameter_schema: compiled_schema.schema,
        callback: fn _args -> {:ok, "structured output generated"} end
      )

    # Adjust max_tokens for structured output with Google-specific minimums
    opts_with_tokens =
      case Keyword.get(opts, :max_tokens) do
        nil -> Keyword.put(opts, :max_tokens, 4096)
        tokens when tokens < 200 -> Keyword.put(opts, :max_tokens, 200)
        _tokens -> opts
      end

    opts_with_tool =
      opts_with_tokens
      |> Keyword.update(:tools, [structured_output_tool], &[structured_output_tool | &1])
      |> Keyword.put(:tool_choice, %{type: "function", function: %{name: "structured_output"}})
      |> Keyword.put(:operation, :object)

    prepare_request(:chat, model_spec, prompt, opts_with_tool)
  end

  def prepare_request(:embedding, model_spec, text, opts) do
    # Handle dimensions as a provider-specific option if passed at top level
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
         {:ok, processed_opts} <-
           ReqLLM.Provider.Options.process(__MODULE__, :embedding, model, opts_with_text) do
      http_opts = Keyword.get(processed_opts, :req_http_options, [])

      req_keys =
        __MODULE__.supported_provider_options() ++
          [:context, :operation, :text, :stream, :model, :provider_options]

      request =
        Req.new(
          [
            url: "/models/#{model.model}:embedContent",
            method: :post,
            receive_timeout: Keyword.get(processed_opts, :receive_timeout, 30_000)
          ] ++ http_opts
        )
        |> Req.Request.register_options(req_keys)
        |> Req.Request.merge_options(
          Keyword.take(processed_opts, req_keys) ++
            [
              model: model.model,
              base_url: Keyword.get(processed_opts, :base_url, default_base_url())
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
    |> Req.Request.append_request_steps(llm_encode_body: &__MODULE__.encode_body/1)
    |> ReqLLM.Step.Stream.maybe_attach(user_opts[:stream] == true, model)
    |> Req.Request.append_response_steps(llm_decode_response: &__MODULE__.decode_response/1)
    |> ReqLLM.Step.Usage.attach(model)
    |> ReqLLM.Step.Fixture.maybe_attach(model, user_opts)
  end

  @impl ReqLLM.Provider
  def extract_usage(body, _model) when is_map(body) do
    case body do
      %{"usageMetadata" => usage} ->
        usage_with_cached = add_cached_tokens(usage)
        {:ok, usage_with_cached}

      _ ->
        {:error, :no_usage_found}
    end
  end

  def extract_usage(_, _), do: {:error, :invalid_body}

  defp add_cached_tokens(usage) do
    cached_tokens = get_in(usage, ["promptFeedback", "cachedContentTokenCount"]) || 0

    if cached_tokens > 0 do
      Map.put(usage, "cached_input", cached_tokens)
    else
      usage
    end
  end

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
    {system_instruction, contents} =
      case request.options[:context] do
        %ReqLLM.Context{} = ctx ->
          model = request.options[:model]
          # Convert OpenAI-style context to Gemini format
          encoded = ReqLLM.Context.Codec.encode_request(ctx, model)
          messages = encoded[:messages] || encoded["messages"] || []
          split_messages_for_gemini(messages)

        _ ->
          split_messages_for_gemini(request.options[:messages] || [])
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
    |> maybe_put(:systemInstruction, system_instruction)
    |> Map.put(:contents, contents)
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

  # Helper to convert OpenAI-style messages to Gemini format (non-system messages only)
  defp convert_messages_to_gemini(messages) do
    Enum.map(messages, fn message ->
      role =
        case message.role do
          :user -> "user"
          :assistant -> "model"
          role when is_binary(role) and role != "system" -> role
          role when role != :system -> to_string(role)
        end

      parts =
        case message.content do
          content when is_binary(content) -> [%{text: content}]
          parts when is_list(parts) -> Enum.map(parts, &convert_content_part/1)
        end

      %{role: role, parts: parts}
    end)
  end

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

  defp convert_content_part(%{type: :text, content: text}), do: %{text: text}
  defp convert_content_part(%{text: text}), do: %{text: text}
  defp convert_content_part(text) when is_binary(text), do: %{text: text}

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

  # TODO: Add support for images, audio, video when multimodal support is added
  defp convert_content_part(part), do: %{text: to_string(part)}
end
