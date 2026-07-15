defmodule ReqLLM.Providers.OpenRouter do
  @moduledoc """
  OpenRouter provider – OpenAI Chat Completions compatible with OpenRouter's unified API.

  ## Implementation

  Uses built-in OpenAI-style encoding/decoding defaults.
  No custom wrapper modules – leverages the standard OpenAI-compatible implementations.

  ## OpenRouter-Specific Extensions

  Beyond standard OpenAI parameters, OpenRouter supports:
  - `openrouter_models` - Array of model IDs for routing/fallback preferences
  - `openrouter_route` - Routing strategy (e.g., "fallback")
  - `openrouter_provider` - Provider preferences object for routing decisions
  - `openrouter_transforms` - Array of prompt transforms to apply
  - `openrouter_top_k` - Top-k sampling (not available for OpenAI models)
  - `openrouter_repetition_penalty` - Repetition penalty for reducing repetitive text
  - `openrouter_min_p` - Minimum probability threshold for sampling
  - `openrouter_top_a` - Top-a sampling parameter
  - `openrouter_structured_output_mode` - Enables `:json_schema` structured output (when tool calls are not supported)
  - `openrouter_usage` - Usage options (e.g., `%{include: true}`)
  - `openrouter_plugins` - Array of plugins (e.g., `[%{id: "web"}]`)
  - `openrouter_session_id` - Session ID for grouping related requests in OpenRouter
  - `app_referer` - HTTP-Referer header for app identification
  - `app_title` - X-Title header for app title in rankings

  ## App Attribution Headers

  OpenRouter supports optional headers for app discoverability:
  - Set `HTTP-Referer` header for app identification
  - Set `X-Title` header for app title in rankings

  See `provider_schema/0` for the complete OpenRouter-specific schema and
  `ReqLLM.Provider.Options` for inherited OpenAI parameters.

  ## Configuration

      # Add to .env file (automatically loaded)
      OPENROUTER_API_KEY=sk-or-...
  """

  use ReqLLM.Provider,
    id: :openrouter,
    default_base_url: "https://openrouter.ai/api/v1",
    default_env_key: "OPENROUTER_API_KEY"

  import ReqLLM.Provider.Utils, only: [maybe_put: 3]

  alias ReqLLM.Message.ContentPart

  require Logger

  @provider_schema [
    openrouter_models: [
      type: {:list, :string},
      doc: "Array of model IDs for routing/fallback preferences"
    ],
    openrouter_route: [
      type: :string,
      doc: "Routing strategy (e.g., 'fallback')"
    ],
    openrouter_provider: [
      type: :map,
      doc: "Provider preferences object for routing decisions"
    ],
    openrouter_transforms: [
      type: {:list, :string},
      doc: "Array of prompt transforms to apply"
    ],
    openrouter_top_k: [
      type: :integer,
      doc: "Top-k sampling (not available for OpenAI models)"
    ],
    openrouter_repetition_penalty: [
      type: :float,
      doc: "Repetition penalty for reducing repetitive text"
    ],
    openrouter_min_p: [
      type: :float,
      doc: "Minimum probability threshold for sampling"
    ],
    openrouter_top_a: [
      type: :float,
      doc: "Top-a sampling parameter"
    ],
    openrouter_top_logprobs: [
      type: :integer,
      doc: "Number of top log probabilities to return"
    ],
    app_referer: [
      type: :string,
      doc: "HTTP-Referer header for app identification on OpenRouter"
    ],
    app_title: [
      type: :string,
      doc: "X-Title header for app title in OpenRouter rankings"
    ],
    response_format: [
      type: {:or, [:map, :keyword_list]},
      doc: "Response format (e.g. %{type: \"json_schema\"})"
    ],
    openrouter_structured_output_mode: [
      type: {:in, [:json_schema]},
      doc:
        "Structured output mode. Only :json_schema is supported, which enables JSON schema support instead of using tools. Useful when tool calls are not supported by the endpoint."
    ],
    openrouter_usage: [
      type: :map,
      doc: "OpenRouter usage options. Example: %{include: true}"
    ],
    openrouter_plugins: [
      type: {:list, :map},
      doc: "OpenRouter plugins. Example: [%{id: \"web\"}]"
    ],
    openrouter_session_id: [
      type: :string,
      doc: "OpenRouter session ID for grouping related LLM calls"
    ],
    dimensions: [
      type: :pos_integer,
      doc: "Number of dimensions for embedding models"
    ],
    encoding_format: [
      type: {:in, ["float", "base64"]},
      doc: "Format for embedding output"
    ],
    input_type: [
      type: :string,
      doc: "Embedding input type, such as search_query or search_document"
    ]
  ]

  # Override attach to add app attribution headers
  @impl ReqLLM.Provider
  def attach(request, model_input, user_opts) do
    # Call the default attach implementation first
    request = ReqLLM.Provider.Defaults.default_attach(__MODULE__, request, model_input, user_opts)

    # Add OpenRouter app attribution headers during attach so they're available in tests
    maybe_add_attribution_headers(request, user_opts)
  end

  @doc """
  Custom prepare_request for :object operations to maintain OpenRouter-specific max_tokens handling.

  Ensures that structured output requests have adequate token limits while delegating
  other operations to the default implementation.
  """
  @impl ReqLLM.Provider
  def prepare_request(:object, model_spec, prompt, opts) do
    provider_opts = Keyword.get(opts, :provider_options, [])
    compiled_schema = Keyword.fetch!(opts, :compiled_schema)

    opts =
      if Keyword.get(provider_opts, :openrouter_structured_output_mode) == :json_schema do
        json_schema_map = ReqLLM.Schema.to_json(compiled_schema.schema)

        json_schema_payload = %{
          type: "json_schema",
          json_schema: %{
            name: "structured_output",
            strict: true,
            schema: json_schema_map
          }
        }

        updated_provider_opts =
          provider_opts
          |> Keyword.put(:response_format, json_schema_payload)
          |> Keyword.delete(:openrouter_structured_output_mode)

        opts
        |> Keyword.put(:provider_options, updated_provider_opts)
        |> Keyword.delete(:tools)
        |> Keyword.delete(:tool_choice)
      else
        structured_output_tool =
          ReqLLM.Tool.new!(
            name: "structured_output",
            description: "Generate structured output matching the provided schema",
            parameter_schema: compiled_schema.schema,
            callback: fn _args -> {:ok, "structured output generated"} end
          )

        opts
        |> Keyword.update(:tools, [structured_output_tool], &[structured_output_tool | &1])
        |> Keyword.put(:tool_choice, %{type: "function", function: %{name: "structured_output"}})
        |> Keyword.delete(:response_format)
      end

    opts =
      opts
      |> ReqLLM.Provider.Options.put_model_max_tokens_default(model_spec, fallback: 4096)
      |> then(fn opts ->
        case Keyword.get(opts, :max_tokens) do
          tokens when is_integer(tokens) and tokens < 200 -> Keyword.put(opts, :max_tokens, 200)
          _tokens -> opts
        end
      end)

    opts = Keyword.put(opts, :operation, :object)

    ReqLLM.Provider.Defaults.prepare_request(
      __MODULE__,
      :chat,
      model_spec,
      prompt,
      opts
    )
  end

  def prepare_request(:transcription, model_spec, audio_data, opts) do
    with {:ok, model} <- ReqLLM.model(model_spec) do
      http_opts = Keyword.get(opts, :req_http_options, [])
      media_type = Keyword.get(opts, :media_type, "audio/mpeg")
      language = Keyword.get(opts, :language)
      provider_options = Keyword.get(opts, :provider_options, [])
      timeout = Keyword.get(opts, :receive_timeout, 120_000)

      body =
        %{
          model: model.provider_model_id || model.id,
          input_audio: %{
            data: Base.encode64(audio_data),
            format: ReqLLM.Provider.Defaults.media_type_to_extension(media_type)
          }
        }
        |> maybe_put(:language, language)
        |> add_transcription_provider_options(provider_options)

      api_key = ReqLLM.Keys.get!(model, opts)

      request =
        Req.new(
          [
            url: "/audio/transcriptions",
            method: :post,
            base_url: Keyword.get(opts, :base_url, base_url()),
            receive_timeout: timeout,
            pool_timeout: timeout,
            json: body,
            auth: {:bearer, api_key}
          ] ++ http_opts
        )
        |> Req.Request.put_header("content-type", "application/json")
        |> Req.Request.put_header("authorization", "Bearer #{api_key}")
        |> maybe_add_attribution_headers(opts)
        |> ReqLLM.Step.Retry.attach(opts)
        |> ReqLLM.Step.Error.attach()
        |> ReqLLM.Step.Telemetry.attach(
          model,
          opts
          |> Keyword.put(:operation, :transcription)
          |> Keyword.put(:audio_bytes, byte_size(audio_data))
          |> Keyword.put(:media_type, media_type)
        )
        |> ReqLLM.Step.Fixture.maybe_attach(model, opts)

      {:ok, request}
    end
  end

  def prepare_request(operation, model_spec, input, opts) do
    ReqLLM.Provider.Defaults.prepare_request(__MODULE__, operation, model_spec, input, opts)
  end

  @impl ReqLLM.Provider
  def attach_stream(model, context, opts, finch_name) do
    processed_opts =
      ReqLLM.Provider.Options.process_stream!(
        __MODULE__,
        opts[:operation] || :chat,
        model,
        context,
        opts
      )

    case validate_openrouter_stream_content(context) do
      :ok ->
        ReqLLM.Provider.Defaults.default_attach_stream(
          __MODULE__,
          model,
          context,
          processed_opts,
          finch_name
        )

      {:error, error} ->
        {:error, error}
    end
  end

  @impl ReqLLM.Provider
  def translate_options(_operation, model, opts) do
    warnings = []

    {reasoning_effort, opts} = Keyword.pop(opts, :reasoning_effort)

    opts =
      case reasoning_effort do
        :none -> Keyword.put(opts, :reasoning_effort, "none")
        :minimal -> Keyword.put(opts, :reasoning_effort, "minimal")
        :low -> Keyword.put(opts, :reasoning_effort, "low")
        :medium -> Keyword.put(opts, :reasoning_effort, "medium")
        :high -> Keyword.put(opts, :reasoning_effort, "high")
        :xhigh -> Keyword.put(opts, :reasoning_effort, "xhigh")
        :default -> opts
        nil -> opts
        other -> Keyword.put(opts, :reasoning_effort, other)
      end

    opts = Keyword.delete(opts, :reasoning_token_budget)

    # Handle legacy parameter names -> OpenRouter prefixed names
    legacy_mappings = [
      {:models, :openrouter_models},
      {:route, :openrouter_route},
      {:provider, :openrouter_provider},
      {:transforms, :openrouter_transforms},
      {:top_k, :openrouter_top_k},
      {:repetition_penalty, :openrouter_repetition_penalty},
      {:min_p, :openrouter_min_p},
      {:top_a, :openrouter_top_a},
      {:top_logprobs, :openrouter_top_logprobs}
    ]

    {opts, warnings} =
      Enum.reduce(legacy_mappings, {opts, warnings}, fn {legacy_key, new_key},
                                                        {acc_opts, acc_warnings} ->
        case Keyword.pop(acc_opts, legacy_key) do
          {nil, remaining_opts} ->
            {remaining_opts, acc_warnings}

          {value, remaining_opts} ->
            warning = "#{legacy_key} is deprecated, use #{new_key} instead"
            {Keyword.put(remaining_opts, new_key, value), [warning | acc_warnings]}
        end
      end)

    # Validate top_k with OpenAI models warning
    {top_k, opts} = Keyword.pop(opts, :openrouter_top_k)

    {opts, warnings} =
      if top_k && String.starts_with?(model.id, "openai/") do
        warning =
          "openrouter_top_k is not available for OpenAI models on OpenRouter and will be ignored"

        {opts, [warning | warnings]}
      else
        opts = if top_k, do: Keyword.put(opts, :openrouter_top_k, top_k), else: opts
        {opts, warnings}
      end

    {opts, Enum.reverse(warnings)}
  end

  @doc """
  Custom body encoding that adds OpenRouter-specific extensions to the default OpenAI-compatible format.

  Adds support for OpenRouter routing and sampling parameters:
  - models (routing preferences)
  - route (routing strategy)
  - provider (provider preferences)
  - transforms (prompt transforms)
  - top_k, repetition_penalty, min_p, top_a (sampling parameters)
  - top_logprobs (log probabilities)

  Also handles OpenRouter-specific app attribution headers:
  - HTTP-Referer header for app identification
  - X-Title header for app title in rankings
  """
  @impl ReqLLM.Provider
  def encode_body(request) do
    body = build_body(request)
    request = ReqLLM.Provider.Defaults.encode_body_from_map(request, body)
    maybe_add_attribution_headers(request, request.options)
  end

  @impl ReqLLM.Provider
  def build_body(request) do
    original_context = request.options[:context]

    request
    |> strip_reasoning_details_from_context()
    |> ReqLLM.Provider.Defaults.default_build_body()
    |> encode_openrouter_content_parts(request.options)
    |> add_embedding_options(request.options)
    |> translate_tool_choice_format()
    |> encode_reasoning_details_in_messages(original_context)
    |> maybe_put(:models, request.options[:openrouter_models])
    |> maybe_put(:route, request.options[:openrouter_route])
    |> maybe_put(:provider, request.options[:openrouter_provider])
    |> maybe_put(:transforms, request.options[:openrouter_transforms])
    |> maybe_put(:top_k, request.options[:openrouter_top_k])
    |> maybe_put(:repetition_penalty, request.options[:openrouter_repetition_penalty])
    |> maybe_put(:min_p, request.options[:openrouter_min_p])
    |> maybe_put(:top_a, request.options[:openrouter_top_a])
    |> maybe_put(:top_logprobs, request.options[:openrouter_top_logprobs])
    |> maybe_put(:reasoning_effort, request.options[:reasoning_effort])
    |> maybe_put(:usage, request.options[:openrouter_usage])
    |> maybe_put(:plugins, request.options[:openrouter_plugins])
    |> maybe_put(:session_id, request.options[:openrouter_session_id])
    |> add_openrouter_specific_options(request.options)
    |> add_stream_options(request.options)
  end

  defp encode_openrouter_content_parts(body, request_options) do
    context = request_options[:context]
    plugins = request_options[:openrouter_plugins]

    if match?(%ReqLLM.Context{}, context) do
      replace_openrouter_content_messages(body, context, file_parser_plugin?(plugins))
    else
      body
    end
  end

  defp file_parser_plugin?(plugins) when is_list(plugins) do
    Enum.any?(plugins, fn
      %{id: "file-parser"} -> true
      %{"id" => "file-parser"} -> true
      _ -> false
    end)
  end

  defp file_parser_plugin?(_plugins), do: false

  defp replace_openrouter_content_messages(
         %{messages: encoded_messages} = body,
         context,
         pdf_files?
       )
       when is_list(encoded_messages) do
    Map.put(
      body,
      :messages,
      encode_openrouter_content_messages(encoded_messages, context.messages, pdf_files?)
    )
  end

  defp replace_openrouter_content_messages(
         %{"messages" => encoded_messages} = body,
         context,
         pdf_files?
       )
       when is_list(encoded_messages) do
    Map.put(
      body,
      "messages",
      encode_openrouter_content_messages(encoded_messages, context.messages, pdf_files?)
    )
  end

  defp replace_openrouter_content_messages(body, _context, _pdf_files?), do: body

  defp encode_openrouter_content_messages(encoded_messages, context_messages, pdf_files?)
       when length(encoded_messages) == length(context_messages) do
    encoded_messages
    |> Enum.zip(context_messages)
    |> Enum.map(fn {encoded_message, context_message} ->
      encode_openrouter_content_message(encoded_message, context_message, pdf_files?)
    end)
  end

  defp encode_openrouter_content_messages(encoded_messages, _context_messages, _pdf_files?),
    do: encoded_messages

  defp encode_openrouter_content_message(
         encoded_message,
         %ReqLLM.Message{content: content},
         pdf_files?
       )
       when is_list(content) do
    if Enum.any?(content, &openrouter_reencoded_content_part?(&1, pdf_files?)) do
      put_message_content(encoded_message, encode_openrouter_content(content, pdf_files?))
    else
      encoded_message
    end
  end

  defp encode_openrouter_content_message(encoded_message, _message, _pdf_files?),
    do: encoded_message

  defp put_message_content(%{content: _} = message, content),
    do: Map.put(message, :content, content)

  defp put_message_content(%{"content" => _} = message, content),
    do: Map.put(message, "content", content)

  defp put_message_content(message, content), do: Map.put(message, :content, content)

  defp encode_openrouter_content(content, pdf_files?) do
    content
    |> Enum.map(&encode_openrouter_content_part(&1, pdf_files?))
    |> Enum.reject(&is_nil/1)
    |> normalize_openrouter_content()
  end

  defp normalize_openrouter_content([]), do: ""

  defp normalize_openrouter_content([%{type: "text", text: text} = block]) do
    if map_size(block) == 2, do: text, else: [block]
  end

  defp normalize_openrouter_content(content), do: content

  defp encode_openrouter_content_part(
         %ContentPart{type: :text, text: text, metadata: metadata},
         _pdf_files?
       ) do
    %{type: "text", text: text}
    |> merge_content_metadata(metadata)
  end

  defp encode_openrouter_content_part(
         %ContentPart{
           type: :image,
           data: data,
           media_type: media_type,
           metadata: metadata
         },
         _pdf_files?
       )
       when is_binary(data) do
    data
    |> image_url_content_part(media_type)
    |> merge_content_metadata(metadata)
  end

  defp encode_openrouter_content_part(
         %ContentPart{
           type: :image_url,
           url: url,
           media_type: media_type,
           metadata: metadata
         },
         _pdf_files?
       ) do
    image_url_map = %{url: url}

    image_url_map =
      if is_binary(media_type) and media_type != "" do
        Map.put(image_url_map, :media_type, media_type)
      else
        image_url_map
      end

    %{type: "image_url", image_url: image_url_map}
    |> merge_content_metadata(metadata)
  end

  defp encode_openrouter_content_part(%ContentPart{type: :file, data: data} = part, pdf_files?)
       when is_binary(data) do
    cond do
      openrouter_input_audio_part?(part) ->
        data
        |> input_audio_content_part(openrouter_input_audio_format(part))
        |> merge_content_metadata(part.metadata)

      openrouter_audio_file_part?(part) ->
        raise ReqLLM.Error.Invalid.Message.exception(
                reason:
                  "OpenRouter chat audio input supports only mp3 and wav file parts; got #{inspect(part.media_type)}."
              )

      pdf_files? and openrouter_pdf_file_part?(part) ->
        %{
          type: "file",
          file: %{
            filename: openrouter_file_filename(part),
            file_data: "data:#{openrouter_file_media_type(part)};base64,#{Base.encode64(data)}"
          }
        }

      true ->
        image_url_content_part(data, part.media_type)
    end
  end

  defp encode_openrouter_content_part(%ContentPart{type: :thinking}, _pdf_files?), do: nil
  defp encode_openrouter_content_part(_part, _pdf_files?), do: nil

  defp openrouter_reencoded_content_part?(part, true) do
    openrouter_input_audio_part?(part) or openrouter_audio_file_part?(part) or
      openrouter_pdf_file_part?(part)
  end

  defp openrouter_reencoded_content_part?(part, _pdf_files?) do
    openrouter_input_audio_part?(part) or openrouter_audio_file_part?(part)
  end

  defp input_audio_content_part(data, format) do
    %{
      type: "input_audio",
      input_audio: %{
        data: Base.encode64(data),
        format: format
      }
    }
  end

  defp image_url_content_part(data, media_type) do
    %{
      type: "image_url",
      image_url: %{
        url: "data:#{media_type};base64,#{Base.encode64(data)}"
      }
    }
  end

  defp openrouter_pdf_file_part?(%ContentPart{type: :file, data: data} = part)
       when is_binary(data) do
    part.media_type == "application/pdf" or openrouter_pdf_filename?(part.filename)
  end

  defp openrouter_pdf_file_part?(_part), do: false

  defp openrouter_audio_file_part?(%ContentPart{type: :file, data: data, media_type: media_type})
       when is_binary(data) and is_binary(media_type) do
    media_type
    |> normalize_openrouter_media_type()
    |> String.starts_with?("audio/")
  end

  defp openrouter_audio_file_part?(_part), do: false

  defp openrouter_input_audio_part?(%ContentPart{type: :file, data: data} = part)
       when is_binary(data) do
    is_binary(openrouter_input_audio_format(part))
  end

  defp openrouter_input_audio_part?(_part), do: false

  defp openrouter_input_audio_format(%ContentPart{media_type: media_type, filename: filename}) do
    case openrouter_audio_format_from_media_type(media_type) do
      format when is_binary(format) -> format
      nil -> openrouter_audio_format_from_non_audio_media_type(media_type, filename)
    end
  end

  defp openrouter_audio_format_from_media_type(media_type) when is_binary(media_type) do
    case normalize_openrouter_media_type(media_type) do
      "audio/mpeg" -> "mp3"
      "audio/mp3" -> "mp3"
      "audio/wav" -> "wav"
      "audio/wave" -> "wav"
      "audio/x-wav" -> "wav"
      _ -> nil
    end
  end

  defp openrouter_audio_format_from_media_type(_media_type), do: nil

  defp openrouter_audio_format_from_non_audio_media_type(media_type, filename)
       when is_binary(media_type) do
    if String.starts_with?(normalize_openrouter_media_type(media_type), "audio/") do
      nil
    else
      openrouter_audio_format_from_filename(filename)
    end
  end

  defp openrouter_audio_format_from_non_audio_media_type(_media_type, filename) do
    openrouter_audio_format_from_filename(filename)
  end

  defp normalize_openrouter_media_type(media_type) do
    media_type
    |> String.downcase()
    |> String.split(";", parts: 2)
    |> List.first()
    |> String.trim()
  end

  defp openrouter_audio_format_from_filename(filename) when is_binary(filename) do
    case filename |> String.downcase() |> Path.extname() do
      ".mp3" -> "mp3"
      ".wav" -> "wav"
      _ -> nil
    end
  end

  defp openrouter_audio_format_from_filename(_filename), do: nil

  defp openrouter_pdf_filename?(filename) when is_binary(filename) do
    filename
    |> String.downcase()
    |> String.ends_with?(".pdf")
  end

  defp openrouter_pdf_filename?(_filename), do: false

  defp openrouter_file_filename(%ContentPart{filename: filename})
       when is_binary(filename) and filename != "" do
    filename
  end

  defp openrouter_file_filename(_part), do: "document.pdf"

  defp openrouter_file_media_type(%ContentPart{media_type: media_type, filename: filename}) do
    cond do
      openrouter_pdf_filename?(filename) -> "application/pdf"
      is_binary(media_type) and media_type != "" -> media_type
      true -> "application/pdf"
    end
  end

  @passthrough_content_metadata_keys [:cache_control, "cache_control"]

  defp merge_content_metadata(base, metadata) when is_map(metadata) and map_size(metadata) > 0 do
    passthrough =
      metadata
      |> Map.take(@passthrough_content_metadata_keys)
      |> Map.new(fn
        {"cache_control", value} -> {:cache_control, value}
        {key, value} -> {key, value}
      end)

    Map.merge(base, passthrough)
  end

  defp merge_content_metadata(base, _metadata), do: base

  defp validate_openrouter_stream_content(%ReqLLM.Context{messages: messages}) do
    messages
    |> Stream.flat_map(&openrouter_message_content/1)
    |> Enum.find_value(:ok, &unsupported_openrouter_audio_error/1)
  end

  defp openrouter_message_content(%ReqLLM.Message{content: content}) when is_list(content),
    do: content

  defp openrouter_message_content(_message), do: []

  defp unsupported_openrouter_audio_error(part) do
    if openrouter_audio_file_part?(part) and not openrouter_input_audio_part?(part) do
      {:error,
       ReqLLM.Error.Invalid.Message.exception(
         reason:
           "OpenRouter chat audio input supports only mp3 and wav file parts; got #{inspect(part.media_type)}."
       )}
    end
  end

  defp add_embedding_options(body, request_options) do
    if request_options[:operation] == :embedding do
      put_embedding_options(body, request_options)
    else
      body
    end
  end

  defp put_embedding_options(body, request_options) do
    body
    |> maybe_put(:dimensions, embedding_option(request_options, :dimensions))
    |> maybe_put(:encoding_format, embedding_option(request_options, :encoding_format))
    |> maybe_put(:input_type, embedding_option(request_options, :input_type))
  end

  defp embedding_option(request_options, key) do
    request_options[key] || get_in(request_options, [:provider_options, key])
  end

  defp add_transcription_provider_options(body, opts) do
    body
    |> maybe_put(:provider, option_value(opts, :openrouter_provider))
    |> maybe_put(:temperature, option_value(opts, :temperature))
  end

  defp option_value(opts, key) when is_list(opts) do
    if Keyword.keyword?(opts), do: Keyword.get(opts, key), else: nil
  end

  defp option_value(opts, key) when is_map(opts) do
    Map.get(opts, key) || Map.get(opts, Atom.to_string(key))
  end

  defp option_value(_opts, _key), do: nil

  # Helper function for adding OpenRouter-specific body options not covered by defaults
  defp add_openrouter_specific_options(body, request_options) do
    # Add OpenRouter-specific options that aren't handled by the default encoding
    openrouter_options = [
      # OpenRouter supports this but defaults might not include it
      :logit_bias,
      # OpenRouter supports multiple completions
      :n
    ]

    Enum.reduce(openrouter_options, body, fn key, acc ->
      maybe_put(acc, key, request_options[key])
    end)
  end

  # Helper function for adding stream options (mirrors OpenAI implementation)
  defp add_stream_options(body, request_options) do
    # Automatically include usage data when streaming for better user experience
    if request_options[:stream] do
      maybe_put(body, :stream_options, %{include_usage: true})
    else
      body
    end
  end

  defp translate_tool_choice_format(body) do
    {tool_choice, body_key} =
      cond do
        Map.has_key?(body, :tool_choice) -> {Map.get(body, :tool_choice), :tool_choice}
        Map.has_key?(body, "tool_choice") -> {Map.get(body, "tool_choice"), "tool_choice"}
        true -> {nil, nil}
      end

    case normalize_tool_choice(tool_choice) do
      nil -> if body_key, do: Map.delete(body, body_key), else: body
      normalized -> if body_key, do: Map.put(body, body_key, normalized), else: body
    end
  end

  # Normalize tool_choice to OpenAI-compatible format for OpenRouter
  # OpenRouter expects: "none", "required", or %{type: "function", function: %{name: "..."}}
  defp normalize_tool_choice(nil), do: nil
  defp normalize_tool_choice(:auto), do: nil
  defp normalize_tool_choice("auto"), do: nil
  defp normalize_tool_choice(:none), do: "none"
  defp normalize_tool_choice(:required), do: "required"

  defp normalize_tool_choice({:tool, name}) when is_binary(name),
    do: %{type: "function", function: %{name: name}}

  defp normalize_tool_choice(%{type: "tool", name: name}) when is_binary(name),
    do: %{type: "function", function: %{name: name}}

  defp normalize_tool_choice(%{"type" => "tool", "name" => name}) when is_binary(name),
    do: %{"type" => "function", "function" => %{"name" => name}}

  defp normalize_tool_choice(choice), do: choice

  # Helper function for adding OpenRouter app attribution headers
  defp maybe_add_attribution_headers(request, opts) do
    # Get referer from either request options or passed opts
    referer = opts[:app_referer] || request.options[:app_referer]
    title = opts[:app_title] || request.options[:app_title]

    request =
      case referer do
        referer when is_binary(referer) ->
          Req.Request.put_header(request, "HTTP-Referer", referer)

        _ ->
          request
      end

    case title do
      title when is_binary(title) ->
        Req.Request.put_header(request, "X-Title", title)

      _ ->
        request
    end
  end

  @impl ReqLLM.Provider
  def decode_response({req, resp} = args) do
    case resp.status do
      200 ->
        body = ensure_parsed_body(resp.body)

        # Extract reasoning_details BEFORE any transformations
        reasoning_details = extract_reasoning_details(body)

        # Handle Deepseek tool calls extraction (may modify body)
        body_with_tool_calls =
          case extract_deepseek_tool_calls(body) do
            {:ok, updated_body} -> updated_body
            :no_tool_calls -> body
          end

        # Decode using default decoder
        {req, resp_with_decoded} =
          ReqLLM.Provider.Defaults.default_decode_response(
            {req, %{resp | body: body_with_tool_calls}}
          )

        # Attach reasoning_details to the message if present
        updated_resp = attach_reasoning_details_to_response(resp_with_decoded, reasoning_details)

        {req, updated_resp}

      _ ->
        ReqLLM.Provider.Defaults.default_decode_response(args)
    end
  end

  defp extract_deepseek_tool_calls(body) when is_map(body) do
    with %{"choices" => [first_choice | _]} <- body,
         %{"message" => %{"reasoning" => reasoning}} when is_binary(reasoning) <- first_choice do
      case parse_deepseek_tool_calls(reasoning) do
        [] ->
          :no_tool_calls

        tool_calls ->
          updated_message =
            first_choice["message"]
            |> Map.put("tool_calls", tool_calls)
            |> Map.update("content", "", fn content ->
              if content == "", do: clean_reasoning_text(reasoning), else: content
            end)

          updated_choice = Map.put(first_choice, "message", updated_message)
          updated_choices = [updated_choice | tl(body["choices"])]
          updated_body = Map.put(body, "choices", updated_choices)

          {:ok, updated_body}
      end
    else
      _ -> :no_tool_calls
    end
  end

  defp extract_deepseek_tool_calls(_), do: :no_tool_calls

  defp parse_deepseek_tool_calls(reasoning) do
    ~r/<｜tool▁call▁begin｜>([^<]+)<｜tool▁sep｜>({[^}]+})<｜tool▁call▁end｜>/
    |> Regex.scan(reasoning, capture: :all_but_first)
    |> Enum.with_index()
    |> Enum.map(fn {[name, args_json], index} ->
      %{
        "id" => "call_#{index}",
        "type" => "function",
        "function" => %{
          "name" => name,
          "arguments" => args_json
        }
      }
    end)
  end

  defp clean_reasoning_text(reasoning) do
    reasoning
    |> String.replace(~r/<｜tool▁calls▁begin｜>.*<｜tool▁calls▁end｜>/s, "")
    |> String.trim()
  end

  defp extract_reasoning_details(body) when is_map(body) do
    with %{"choices" => [first_choice | _]} <- body,
         %{"message" => %{"reasoning_details" => details}} when is_list(details) <- first_choice do
      if Enum.all?(details, &is_map/1) do
        details
        |> Enum.with_index()
        |> Enum.map(&normalize_reasoning_detail/1)
      end
    else
      _ -> nil
    end
  end

  defp extract_reasoning_details(_), do: nil

  defp normalize_reasoning_detail({raw, fallback_index}) do
    ReqLLM.Message.ReasoningDetails.from_openai_compatible(
      raw,
      :openrouter,
      fallback_index,
      "openrouter-v1"
    )
  end

  defp strip_reasoning_details_from_context(%Req.Request{options: options} = request) do
    case options[:context] do
      %ReqLLM.Context{messages: messages} = context ->
        stripped_messages =
          Enum.map(messages, fn
            %ReqLLM.Message{} = message -> %{message | reasoning_details: nil}
            message -> message
          end)

        put_in(request.options[:context], %{context | messages: stripped_messages})

      _ ->
        request
    end
  end

  defp encode_reasoning_details_in_messages(body, %ReqLLM.Context{messages: context_messages}) do
    cond do
      is_list(Map.get(body, :messages)) ->
        updated_messages = encode_messages_reasoning_details(body.messages, context_messages)
        Map.put(body, :messages, updated_messages)

      is_list(Map.get(body, "messages")) ->
        updated_messages = encode_messages_reasoning_details(body["messages"], context_messages)
        Map.put(body, "messages", updated_messages)

      true ->
        body
    end
  end

  defp encode_reasoning_details_in_messages(body, _context), do: body

  defp encode_messages_reasoning_details(encoded_messages, context_messages)
       when length(encoded_messages) == length(context_messages) do
    encoded_messages
    |> Enum.zip(context_messages)
    |> Enum.map(fn {encoded_message, context_message} ->
      encode_message_reasoning_details(encoded_message, context_message)
    end)
  end

  defp encode_messages_reasoning_details(encoded_messages, _context_messages),
    do: encoded_messages

  defp encode_message_reasoning_details(encoded_message, %ReqLLM.Message{
         reasoning_details: details
       })
       when is_list(details) and details != [] do
    encoded_details =
      details
      |> Enum.map(&encode_single_reasoning_detail/1)
      |> Enum.reject(&is_nil/1)

    put_encoded_reasoning_details(encoded_message, encoded_details)
  end

  defp encode_message_reasoning_details(encoded_message, _context_message), do: encoded_message

  defp put_encoded_reasoning_details(message, []) when is_map(message) do
    message
    |> Map.delete(:reasoning_details)
    |> Map.delete("reasoning_details")
  end

  defp put_encoded_reasoning_details(%{} = message, details) do
    cond do
      Map.has_key?(message, :role) -> Map.put(message, :reasoning_details, details)
      Map.has_key?(message, "role") -> Map.put(message, "reasoning_details", details)
      true -> Map.put(message, :reasoning_details, details)
    end
  end

  defp encode_single_reasoning_detail(
         %ReqLLM.Message.ReasoningDetails{provider: :openrouter} = detail
       ) do
    detail
    |> ReqLLM.Message.ReasoningDetails.to_openai_compatible()
    |> Map.put_new("type", "reasoning.text")
  end

  defp encode_single_reasoning_detail(%ReqLLM.Message.ReasoningDetails{provider: provider}) do
    Logger.debug("Skipping non-OpenRouter reasoning detail from provider: #{inspect(provider)}")
    nil
  end

  defp encode_single_reasoning_detail(%{"provider" => "openrouter"} = decoded_struct) do
    decoded_struct
    |> openrouter_reasoning_detail_to_wire()
    |> Map.put_new("type", "reasoning.text")
  end

  defp encode_single_reasoning_detail(%{"provider" => provider}) when is_binary(provider) do
    Logger.debug("Skipping non-OpenRouter reasoning detail from provider: #{provider}")
    nil
  end

  defp encode_single_reasoning_detail(%{"type" => _} = raw_map) do
    raw_map
  end

  defp encode_single_reasoning_detail(_), do: nil

  defp openrouter_reasoning_detail_to_wire(detail) do
    detail
    |> Map.get("provider_data", %{})
    |> ensure_map()
    |> put_wire_field("text", detail["text"])
    |> put_wire_field("signature", detail["signature"])
    |> put_wire_field("signature_encrypted", encrypted_signature?(detail))
    |> put_wire_field("format", detail["format"])
    |> put_wire_field("index", detail["index"])
  end

  defp encrypted_signature?(%{"encrypted?" => true}), do: true
  defp encrypted_signature?(%{"encrypted" => true}), do: true
  defp encrypted_signature?(_detail), do: nil

  defp put_wire_field(map, _key, nil), do: map
  defp put_wire_field(map, _key, ""), do: map
  defp put_wire_field(map, key, value), do: Map.put(map, key, value)

  defp ensure_map(map) when is_map(map), do: map
  defp ensure_map(_), do: %{}

  defp attach_reasoning_details_to_response(resp, nil), do: resp

  defp attach_reasoning_details_to_response(%Req.Response{body: body} = resp, details)
       when is_struct(body, ReqLLM.Response) do
    case body.message do
      nil ->
        resp

      message ->
        updated_message = Map.put(message, :reasoning_details, details)

        updated_context =
          case body.context.messages do
            [] ->
              %{body.context | messages: [updated_message]}

            msgs ->
              {init, [last]} = Enum.split(msgs, -1)

              if is_struct(last, ReqLLM.Message) and last.role == message.role do
                updated_last = Map.put(last, :reasoning_details, details)
                %{body.context | messages: init ++ [updated_last]}
              else
                %{body.context | messages: msgs}
              end
          end

        updated_body = %{body | message: updated_message, context: updated_context}
        %{resp | body: updated_body}
    end
  end

  defp attach_reasoning_details_to_response(resp, _details), do: resp

  defp ensure_parsed_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, parsed} -> parsed
      {:error, _} -> body
    end
  end

  defp ensure_parsed_body(body), do: body
end
