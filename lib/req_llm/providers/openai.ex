defmodule ReqLLM.Providers.OpenAI do
  @moduledoc """
  OpenAI provider implementation with multi-driver architecture for Chat, Responses, and Images APIs.

  ## Architecture

  This provider uses a metadata-driven routing system to dispatch requests to specialized
  API drivers:

  - **ChatAPI** (`ReqLLM.Providers.OpenAI.ChatAPI`) - Handles `/v1/chat/completions` endpoint
    for models like GPT-4, GPT-3.5, and other chat-based models.

  - **ResponsesAPI** (`ReqLLM.Providers.OpenAI.ResponsesAPI`) - Handles `/v1/responses` endpoint
    for reasoning models (o1, o3, o4, GPT-4.1, GPT-5) with extended thinking capabilities.

  - **ImagesAPI** (`ReqLLM.Providers.OpenAI.ImagesAPI`) - Handles `/v1/images/generations` endpoint
    for image generation models (DALL-E 2, DALL-E 3, gpt-image-*).

  The provider automatically routes requests based on the operation type and model metadata:
  - `:image` operations → uses ImagesAPI driver
  - `:chat` operations with `"api": "responses"` → uses ResponsesAPI driver
  - `:chat` operations (default) → uses ChatAPI driver

  ## Capabilities

  ### Chat Completions API (ChatAPI)
  - Text generation with GPT models
  - Streaming responses with usage tracking
  - Tool calling (function calling)
  - Multi-modal inputs (text and images)
  - Embeddings generation
  - Full OpenAI Chat API compatibility

  ### Responses API (ResponsesAPI)
  - Extended reasoning for o1/o3/o4/GPT-4.1/GPT-5 models
  - Reasoning effort control (minimal, low, medium, high)
  - Streaming with reasoning token tracking
  - Tool calling with responses-specific format
  - Enhanced usage metrics including `:reasoning_tokens`

  ### Images API (ImagesAPI)
  - Image generation with DALL-E and gpt-image-* models
  - Multiple output formats: PNG, JPEG, WebP (gpt-image-* only)
  - Size and aspect ratio control
  - Quality and style options (DALL-E 3)
  - Returns images as `ReqLLM.Message.ContentPart` with `:image` or `:image_url` type
  - Streaming not supported

  ## Usage Normalization

  Chat and Responses drivers normalize usage metrics to provide consistent field names:

  - `:reasoning_tokens` - Primary field for reasoning token count (ResponsesAPI)
  - `:reasoning` - Backward-compatibility alias (deprecated, use `:reasoning_tokens`)

  **Deprecation Notice**: The `:reasoning` usage key is deprecated in favor of
  `:reasoning_tokens` and will be removed in a future version.

  ## Configuration

  Set your OpenAI API key via environment variable or application config:

      # Option 1: Environment variable (automatically loaded from .env via dotenvy)
      OPENAI_API_KEY=sk-...

      # Option 2: Store in application config
      ReqLLM.put_key(:openai_api_key, "sk-...")

  ## Examples

      # Simple text generation (ChatAPI)
      model = ReqLLM.model("openai:gpt-4")
      {:ok, response} = ReqLLM.generate_text(model, "Hello!")

      # Reasoning model (ResponsesAPI)
      model = ReqLLM.model("openai:o1")
      {:ok, response} = ReqLLM.generate_text(model, "Solve this problem...")
      response.usage.reasoning_tokens  # Reasoning tokens used

      # Streaming with reasoning
      {:ok, stream} = ReqLLM.stream_text(model, "Complex question", stream: true)

      # Tool calling (both APIs)
      tools = [%ReqLLM.Tool{name: "get_weather", ...}]
      {:ok, response} = ReqLLM.generate_text(model, "What's the weather?", tools: tools)

      # Embeddings (ChatAPI)
      {:ok, embedding} = ReqLLM.generate_embedding("openai:text-embedding-3-small", "Hello world")

      # Reasoning effort (ResponsesAPI)
      {:ok, response} = ReqLLM.generate_text(
        "openai:gpt-5",
        "Hard problem",
        reasoning_effort: :high
      )

      # Image generation (ImagesAPI)
      {:ok, response} = ReqLLM.generate_image("openai:gpt-image-1", "A futuristic city at sunset")

      # DALL-E with options
      {:ok, response} = ReqLLM.generate_image(
        "openai:dall-e-3",
        "A watercolor painting of a forest",
        size: {1792, 1024},
        quality: :hd,
        style: :natural
      )
  """

  use ReqLLM.Provider,
    id: :openai,
    default_base_url: "https://api.openai.com/v1",
    default_env_key: "OPENAI_API_KEY"

  # The Responses API supports richer file types than the Chat Completions API.
  @responses_api_mimes ~w(image/jpeg image/png image/gif image/webp application/pdf)

  @provider_schema [
    access_token: [
      type: :string,
      doc: "OAuth access token used as Authorization Bearer credential"
    ],
    auth_mode: [
      type: {:in, [:api_key, :oauth]},
      default: :api_key,
      doc: "Authentication mode: :api_key (default) or :oauth"
    ],
    oauth_file: [
      type: :string,
      doc: "Path to an oauth/auth JSON file with provider credentials"
    ],
    auth_file: [
      type: :string,
      doc: "Alias for :oauth_file"
    ],
    oauth_http_options: [
      type: {:list, :any},
      doc: "Req options for OAuth refresh HTTP requests"
    ],
    dimensions: [
      type: :pos_integer,
      doc: "Dimensions for embedding models (e.g., text-embedding-3-small supports 512-1536)"
    ],
    encoding_format: [type: :string, doc: "Format for embedding output (float, base64)"],
    max_completion_tokens: [
      type: :integer,
      doc: "Maximum completion tokens (required for reasoning models like o1, o3, gpt-5)"
    ],
    max_output_tokens: [
      type: :integer,
      doc: "Maximum output tokens for Responses API models"
    ],
    openai_structured_output_mode: [
      type: {:in, [:auto, :json_schema, :tool_strict]},
      default: :auto,
      doc: """
      Strategy for structured output generation:
      - `:auto` - Use json_schema when supported, else strict tools (default)
      - `:json_schema` - Force response_format with json_schema (requires model support)
      - `:tool_strict` - Force strict: true on function tools
      """
    ],
    openai_json_schema_strict: [
      type: :boolean,
      default: true,
      doc: """
      Whether to use strict mode for JSON schema response format.
      When `true` (default), OpenAI enforces strict schema validation which requires
      all schema properties to have explicit types and `additionalProperties: false`.
      Set to `false` when using schemas with features incompatible with strict mode
      (e.g., `additionalProperties: {}` from Ecto :map fields).
      """
    ],
    response_format: [
      type: :map,
      doc: "Response format configuration (e.g., json_schema for structured output)"
    ],
    openai_parallel_tool_calls: [
      type: {:or, [:boolean, nil]},
      default: nil,
      doc: "Override parallel_tool_calls setting. Required false for json_schema mode."
    ],
    previous_response_id: [
      type: :string,
      doc: "Previous response ID for Responses API tool resume flow"
    ],
    store: [
      type: :boolean,
      doc:
        "Whether to store responses for multi-turn chaining via previous_response_id. " <>
          "Set to false for Zero Data Retention (ZDR) organizations."
    ],
    openai_stream_transport: [
      type: {:in, [:sse, :websocket]},
      default: :sse,
      doc:
        "Streaming transport for Responses models. Use :websocket for OpenAI WebSocket mode; SSE remains the default."
    ],
    openai_reuse_websocket: [
      type: :boolean,
      default: false,
      doc:
        "Request that higher-level agent runtimes reuse one Responses API WebSocket across multiple response.create turns."
    ],
    openai_websocket_session: [
      type: :any,
      doc:
        "Existing ReqLLM.Streaming.WebSocketSession pid to reuse for Responses API streams. " <>
          "When set, ReqLLM sends the response.create event on that socket and leaves socket ownership to the caller."
    ],
    openai_compatible_backend: [
      type: {:or, [{:in, [:ollama]}, {:in, ["ollama"]}]},
      doc:
        "Explicit OpenAI-compatible backend marker. Set to :ollama to allow missing API keys for unauthenticated local deployments."
    ],
    tool_outputs: [
      type: {:list, :any},
      doc:
        "Tool execution results for Responses API tool resume flow (list of %{call_id, output})"
    ],
    service_tier: [
      type: {:or, [:atom, :string]},
      doc: "Service tier for request prioritization ('auto', 'default', 'flex' or 'priority')"
    ],
    verbosity: [
      type: {:or, [:atom, :string]},
      doc:
        "Constrains the verbosity of the model's response. Supported values: 'low', 'medium', 'high'. Defaults to 'medium'."
    ],
    openai_logprobs: [
      type: :boolean,
      doc: "Whether to return log probabilities of output tokens"
    ],
    openai_top_logprobs: [
      type: {:in, 0..20},
      doc:
        "Number of most likely tokens to return at each position (0–20, requires openai_logprobs: true)"
    ]
  ]

  @compile {:no_warn_undefined, [{nil, :path, 0}, {nil, :attach_stream, 4}]}

  defp get_api_type(%LLMDB.Model{} = model) do
    protocol =
      get_in(model, [Access.key(:extra, %{}), :wire, :protocol]) ||
        get_in(model, [Access.key(:extra, %{}), "wire", "protocol"])

    case protocol do
      "openai_responses" ->
        "responses"

      "openai_chat" ->
        "chat"

      _ ->
        # Fallback for newer OpenAI models whose wire metadata may lag behind.
        # GPT-4o and reasoning/Codex families should use Responses API.
        model_id = model.provider_model_id || model.id

        if ReqLLM.Providers.OpenAI.AdapterHelpers.responses_model?(model_id) do
          "responses"
        else
          nil
        end
    end
  end

  defp select_api_mod(%LLMDB.Model{} = model) do
    case get_api_type(model) do
      "chat" -> ReqLLM.Providers.OpenAI.ChatAPI
      "responses" -> ReqLLM.Providers.OpenAI.ResponsesAPI
      _ -> ReqLLM.Providers.OpenAI.ChatAPI
    end
  end

  defp get_timeout_for_operation(:image, opts) do
    Keyword.get(
      opts,
      :receive_timeout,
      Application.get_env(:req_llm, :image_receive_timeout, 120_000)
    )
  end

  defp get_timeout_for_operation(_operation, opts) do
    user_timeout = Keyword.get(opts, :receive_timeout)
    default_timeout = Application.get_env(:req_llm, :receive_timeout, 30_000)

    user_timeout || default_timeout
  end

  defp get_timeout_for_model(api_mod, opts) do
    user_timeout = Keyword.get(opts, :receive_timeout)
    thinking_timeout = Application.get_env(:req_llm, :thinking_timeout, 300_000)

    cond do
      user_timeout != nil ->
        user_timeout

      api_mod == ReqLLM.Providers.OpenAI.ResponsesAPI ->
        thinking_timeout

      true ->
        get_timeout_for_operation(:chat, opts)
    end
  end

  @impl ReqLLM.Provider
  @doc """
  Custom prepare_request to route requests to appropriate API endpoints.

  - :image operations route to `/v1/images/generations` via ImagesAPI
  - :chat operations detect model type and route to ChatAPI or ResponsesAPI
  - :object operations maintain OpenAI-specific token handling
  """
  def prepare_request(:image, model_spec, prompt_or_messages, opts) do
    with {:ok, model} <- ReqLLM.model(model_spec),
         {:ok, context, prompt} <- image_context(prompt_or_messages, opts),
         opts_with_context = Keyword.put(opts, :context, context),
         http_opts = Keyword.get(opts, :req_http_options, []),
         {:ok, processed_opts} <-
           ReqLLM.Provider.Options.process(__MODULE__, :image, model, opts_with_context) do
      api_mod = ReqLLM.Providers.OpenAI.ImagesAPI
      path = api_mod.path()

      req_keys =
        supported_provider_options() ++
          [
            :context,
            :operation,
            :model,
            :prompt,
            :n,
            :size,
            :aspect_ratio,
            :output_format,
            :response_format,
            :quality,
            :style,
            :seed,
            :negative_prompt,
            :user,
            :provider_options,
            :req_http_options,
            :api_mod,
            :base_url
          ]

      timeout = get_timeout_for_operation(:image, processed_opts)

      request =
        Req.new(
          [
            url: path,
            method: :post,
            receive_timeout: timeout,
            pool_timeout: timeout
          ] ++ http_opts
        )
        |> Req.Request.register_options(req_keys)
        |> Req.Request.merge_options(
          Keyword.take(processed_opts, req_keys) ++
            [
              operation: :image,
              model: model.id,
              prompt: prompt,
              context: context,
              base_url: Keyword.get(processed_opts, :base_url, base_url()),
              api_mod: api_mod
            ]
        )
        |> attach(model, processed_opts)

      {:ok, request}
    end
  end

  def prepare_request(:chat, model_spec, prompt, opts) do
    with {:ok, model} <- ReqLLM.model(model_spec),
         {:ok, context} <- ReqLLM.Context.normalize(prompt, opts),
         :ok <- validate_attachments(context, model),
         opts_with_context = Keyword.put(opts, :context, context),
         http_opts = Keyword.get(opts, :req_http_options, []),
         {:ok, processed_opts} <-
           ReqLLM.Provider.Options.process(__MODULE__, :chat, model, opts_with_context) do
      api_mod = select_api_mod(model)
      path = api_mod.path()

      req_keys =
        supported_provider_options() ++
          [
            :context,
            :operation,
            :text,
            :stream,
            :model,
            :provider_options,
            :api_mod,
            :max_completion_tokens,
            :reasoning_effort,
            :service_tier
          ]

      timeout = get_timeout_for_model(api_mod, processed_opts)

      request =
        Req.new(
          [
            url: path,
            method: :post,
            receive_timeout: timeout,
            pool_timeout: timeout
          ] ++ http_opts
        )
        |> Req.Request.register_options(req_keys)
        |> Req.Request.merge_options(
          Keyword.take(processed_opts, req_keys) ++
            [
              model: model.id,
              base_url: Keyword.get(processed_opts, :base_url, base_url()),
              api_mod: api_mod
            ]
        )
        |> attach(model, processed_opts)

      {:ok, request}
    end
  end

  def prepare_request(:object, model_spec, prompt, opts) do
    compiled_schema = Keyword.fetch!(opts, :compiled_schema)
    {:ok, model} = ReqLLM.model(model_spec)

    mode = determine_output_mode(model, opts)

    case mode do
      :json_schema ->
        prepare_json_schema_request(model_spec, prompt, compiled_schema, opts)

      :tool_strict ->
        prepare_strict_tool_request(model_spec, prompt, compiled_schema, opts)
    end
  end

  def prepare_request(:transcription, model_spec, audio_data, opts) do
    with {:ok, model} <- ReqLLM.model(model_spec) do
      http_opts = Keyword.get(opts, :req_http_options, [])
      media_type = Keyword.get(opts, :media_type, "audio/mpeg")
      language = Keyword.get(opts, :language)
      provider_options = Keyword.get(opts, :provider_options, [])
      timeout = Keyword.get(opts, :receive_timeout, 120_000)

      ext = ReqLLM.Provider.Defaults.media_type_to_extension(media_type)
      filename = "audio.#{ext}"

      # Determine response_format based on model
      response_format =
        if model.id in ["gpt-4o-transcribe", "gpt-4o-mini-transcribe"] do
          "json"
        else
          "verbose_json"
        end

      form_parts =
        [
          file: {audio_data, filename: filename, content_type: media_type},
          model: model.id,
          response_format: response_format
        ]
        |> maybe_add_transcription_part(:language, language)
        |> maybe_add_transcription_provider_parts(provider_options)

      credential = resolve_request_credential!(model, opts)

      request =
        Req.new(
          [
            url: "/audio/transcriptions",
            method: :post,
            base_url: Keyword.get(opts, :base_url, base_url()),
            receive_timeout: timeout,
            pool_timeout: timeout,
            form_multipart: form_parts
          ] ++ auth_req_options(credential) ++ http_opts
        )
        |> maybe_put_authorization_header(credential)
        |> ReqLLM.Step.Retry.attach()
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
    case ReqLLM.Provider.Defaults.prepare_request(__MODULE__, operation, model_spec, input, opts) do
      {:error, %ReqLLM.Error.Invalid.Parameter{parameter: param}} ->
        custom_param = String.replace(param, inspect(__MODULE__), "OpenAI provider")
        {:error, ReqLLM.Error.Invalid.Parameter.exception(parameter: custom_param)}

      result ->
        result
    end
  end

  defp image_context(prompt_or_messages, opts) do
    context_result =
      case Keyword.get(opts, :context) do
        %ReqLLM.Context{} = context -> {:ok, context}
        _ -> ReqLLM.Context.normalize(prompt_or_messages, opts)
      end

    with {:ok, context} <- context_result,
         {:ok, prompt} <- extract_image_prompt(context) do
      {:ok, context, prompt}
    end
  end

  defp extract_image_prompt(%ReqLLM.Context{messages: messages}) do
    last_user =
      messages
      |> Enum.reverse()
      |> Enum.find(&(&1.role == :user))

    prompt =
      case last_user do
        nil ->
          ""

        %ReqLLM.Message{content: content} when is_list(content) ->
          content
          |> Enum.filter(&(&1.type == :text))
          |> Enum.map_join("", & &1.text)

        %ReqLLM.Message{content: content} when is_binary(content) ->
          content

        _ ->
          ""
      end
      |> String.trim()

    if prompt == "" do
      {:error,
       ReqLLM.Error.Invalid.Parameter.exception(
         parameter: "image generation requires a non-empty user text prompt"
       )}
    else
      {:ok, prompt}
    end
  end

  defp prepare_json_schema_request(model_spec, prompt, compiled_schema, opts) do
    schema_name = Map.get(compiled_schema, :name, "output_schema")
    json_schema = ReqLLM.Schema.to_json(compiled_schema.schema)

    provider_opts = Keyword.get(opts, :provider_options, [])
    strict = Keyword.get(provider_opts, :openai_json_schema_strict, true)

    json_schema =
      if strict do
        enforce_strict_schema_requirements(json_schema)
      else
        json_schema
      end

    response_format = %{
      type: "json_schema",
      json_schema: %{
        name: schema_name,
        strict: strict,
        schema: json_schema
      }
    }

    opts_with_format =
      opts
      |> Keyword.update(
        :provider_options,
        [response_format: response_format, openai_parallel_tool_calls: false],
        fn existing_provider_opts ->
          existing_provider_opts
          |> Keyword.put(:response_format, response_format)
          |> Keyword.put(:openai_parallel_tool_calls, false)
        end
      )
      |> ReqLLM.Provider.Options.put_model_max_tokens_default(model_spec, fallback: 4096)
      |> Keyword.put(:operation, :object)

    prepare_request(:chat, model_spec, prompt, opts_with_format)
  end

  @dialyzer {:nowarn_function, prepare_strict_tool_request: 4}
  defp prepare_strict_tool_request(model_spec, prompt, compiled_schema, opts) do
    structured_output_tool =
      ReqLLM.Tool.new!(
        name: "structured_output",
        description: "Generate structured output matching the provided schema",
        parameter_schema: compiled_schema.schema,
        strict: true,
        callback: fn _args -> {:ok, "structured output generated"} end
      )

    opts_with_tool =
      opts
      |> Keyword.update(:tools, [structured_output_tool], &[structured_output_tool | &1])
      |> Keyword.put(:tool_choice, %{
        type: "function",
        function: %{name: "structured_output"}
      })
      |> Keyword.update(
        :provider_options,
        [],
        &Keyword.put(&1, :openai_parallel_tool_calls, false)
      )
      |> ReqLLM.Provider.Options.put_model_max_tokens_default(model_spec, fallback: 4096)
      |> Keyword.put(:operation, :object)

    prepare_request(:chat, model_spec, prompt, opts_with_tool)
  end

  @doc """
  Translates provider-specific options for different model types.

  Uses a profile-based system to apply model-specific parameter transformations.
  Profiles are resolved from model metadata and capabilities, making it easy to
  add new model-specific rules without modifying this function.

  ## Reasoning Models

  Models with reasoning capabilities (o1, o3, o4, gpt-5, etc.) have special parameter requirements:
  - `max_tokens` is renamed to `max_completion_tokens`
  - `temperature` may be unsupported or restricted depending on the specific model

  ## Returns

  `{translated_opts, warnings}` where warnings is a list of transformation messages.
  """
  @impl ReqLLM.Provider
  def translate_options(:image, %LLMDB.Model{}, opts) do
    # Image generation has no special parameter translations
    {opts, []}
  end

  def translate_options(op, %LLMDB.Model{} = model, opts) do
    steps = ReqLLM.Providers.OpenAI.ParamProfiles.steps_for(op, model)
    {opts1, warns} = ReqLLM.ParamTransform.apply(opts, steps)

    if get_api_type(model) == "responses" do
      mct = Keyword.get(opts1, :max_completion_tokens)

      if is_integer(mct) and mct < 16 do
        {Keyword.put(opts1, :max_completion_tokens, 16),
         ["Raised :max_completion_tokens to API minimum (16)" | warns]}
      else
        {opts1, warns}
      end
    else
      {opts1, warns}
    end
  end

  def translate_options(_operation, _model, opts) do
    {opts, []}
  end

  @impl ReqLLM.Provider
  def attach(request, model_input, user_opts) do
    {:ok, %LLMDB.Model{} = model} = ReqLLM.model(model_input)

    if model.provider != __MODULE__.provider_id() do
      raise ReqLLM.Error.Invalid.Provider.exception(provider: model.provider)
    end

    credential = resolve_request_credential!(model, user_opts)
    extra_option_keys = ReqLLM.Provider.Defaults.extra_option_keys(__MODULE__)

    request
    |> Req.Request.put_header("content-type", "application/json")
    |> maybe_put_authorization_header(credential)
    |> Req.Request.register_options(extra_option_keys)
    |> Req.Request.merge_options(
      ReqLLM.Provider.Defaults.finch_option(request) ++
        [
          model: model.provider_model_id || model.id
        ] ++ auth_req_options(credential) ++ user_opts
    )
    |> ReqLLM.Step.Retry.attach()
    |> ReqLLM.Step.Error.attach()
    |> Req.Request.append_request_steps(llm_encode_body: &encode_body/1)
    |> Req.Request.append_response_steps(llm_decode_response: &decode_response/1)
    |> ReqLLM.Step.Usage.attach(model)
    |> ReqLLM.Step.Telemetry.attach(model, user_opts)
    |> ReqLLM.Step.Fixture.maybe_attach(model, user_opts)
  end

  @impl ReqLLM.Provider
  def oauth_provider_id, do: "openai-codex"

  @impl ReqLLM.Provider
  def refresh_oauth_credentials(credentials, opts) do
    ReqLLM.Providers.OpenAI.OAuth.refresh(credentials, opts)
  end

  @doc """
  Custom attach_stream to route reasoning models to /v1/responses endpoint for streaming.
  """
  @impl ReqLLM.Provider
  def attach_stream(model, context, opts, finch_name) do
    api_mod = select_api_mod(model)
    operation = opts[:operation] || :chat

    processed_opts =
      ReqLLM.Provider.Options.process_stream!(
        __MODULE__,
        operation,
        model,
        context,
        opts
      )

    api_mod.attach_stream(model, context, processed_opts, finch_name)
  end

  def attach_websocket_stream(model, context, opts) do
    api_mod = select_api_mod(model)

    if function_exported?(api_mod, :attach_websocket_stream, 3) do
      Function.capture(api_mod, :attach_websocket_stream, 3).(model, context, opts)
    else
      {:error,
       ReqLLM.Error.API.Request.exception(
         reason:
           "OpenAI WebSocket mode is only supported for Responses models. #{LLMDB.Model.spec(model)} routes to #{inspect(api_mod)}."
       )}
    end
  end

  def start_responses_session(%LLMDB.Model{} = model, opts \\ []) do
    ReqLLM.Providers.OpenAI.WebSocket.start_responses_session(model, opts)
  end

  def stream_transport(_model, opts) do
    provider_opts = Keyword.get(opts, :provider_options, [])

    case Keyword.get(provider_opts, :openai_stream_transport, :sse) do
      :websocket -> :websocket
      "websocket" -> :websocket
      _ -> :http
    end
  end

  @doc false
  def resolve_request_credential!(%LLMDB.Model{} = model, opts) do
    case ReqLLM.Auth.resolve(model, opts) do
      {:ok, credential} ->
        credential

      {:error, message} ->
        if allow_missing_api_key?(model, opts) and missing_api_key_error?(message) do
          :none
        else
          raise ReqLLM.Error.Invalid.Parameter.exception(parameter: message)
        end
    end
  end

  @doc false
  def auth_header_list(:none), do: []
  def auth_header_list(credential), do: [{"Authorization", "Bearer " <> credential.token}]

  @doc false
  def auth_req_options(:none), do: []
  def auth_req_options(credential), do: [auth: {:bearer, credential.token}]

  @doc """
  Custom body encoding that delegates to the selected API module.
  """
  @impl ReqLLM.Provider
  def encode_body(request) do
    api_mod = request.options[:api_mod] || ReqLLM.Providers.OpenAI.ChatAPI
    api_mod.encode_body(request)
  end

  @doc """
  Custom decode_response to delegate to the selected API module.

  Auto-detects the API type from the response body if not already set.
  This is important for fixture replay where api_mod isn't set during prepare_request.
  """
  @impl ReqLLM.Provider
  def decode_response({req, resp}) do
    api_mod = req.options[:api_mod] || detect_api_from_response(resp)
    api_mod.decode_response({req, resp})
  end

  defp detect_api_from_response(resp) do
    body = ReqLLM.Provider.Utils.ensure_parsed_body(resp.body)

    case body do
      %{"object" => "response"} -> ReqLLM.Providers.OpenAI.ResponsesAPI
      %{"object" => "chat.completion"} -> ReqLLM.Providers.OpenAI.ChatAPI
      %ReqLLM.Response{} -> ReqLLM.Providers.OpenAI.ChatAPI
      _ -> ReqLLM.Providers.OpenAI.ChatAPI
    end
  rescue
    _ -> ReqLLM.Providers.OpenAI.ChatAPI
  end

  @doc """
  Custom decode_stream_event to route based on model API type.
  """
  @impl ReqLLM.Provider
  def decode_stream_event(event, model) do
    {chunks, _state} = decode_stream_event(event, model, nil)
    chunks
  end

  @impl ReqLLM.Provider
  def decode_stream_event(event, model, state) do
    if get_api_type(model) == "responses" do
      ReqLLM.Providers.OpenAI.ResponsesAPI.decode_stream_event(event, model, state)
    else
      chunks = ReqLLM.Providers.OpenAI.ChatAPI.decode_stream_event(event, model)
      {chunks, state}
    end
  end

  @doc false
  def supports_json_schema?(%LLMDB.Model{} = model) do
    ReqLLM.ModelHelpers.json_schema?(model)
  end

  @doc false
  def supports_strict_tools?(%LLMDB.Model{} = model) do
    ReqLLM.ModelHelpers.tools_strict?(model)
  end

  @doc false
  def has_other_tools?(opts) do
    tools = Keyword.get(opts, :tools, [])
    Enum.any?(tools, fn tool -> tool.name != "structured_output" end)
  end

  @doc false
  def determine_output_mode(model, opts) do
    explicit_mode = Keyword.get(opts, :openai_structured_output_mode, :auto)

    case explicit_mode do
      :auto ->
        cond do
          supports_json_schema?(model) and not has_other_tools?(opts) -> :json_schema
          supports_strict_tools?(model) -> :tool_strict
          true -> :tool_strict
        end

      mode ->
        mode
    end
  end

  defp enforce_strict_schema_requirements(schema) do
    ReqLLM.Providers.OpenAI.AdapterHelpers.enforce_strict_recursive(schema)
  end

  defp validate_attachments(context, model) do
    case select_api_mod(model) do
      ReqLLM.Providers.OpenAI.ResponsesAPI ->
        validate_responses_api_attachments(context)

      _ ->
        case ReqLLM.Provider.Defaults.validate_image_only_attachments(context) do
          :ok ->
            :ok

          {:error, message} ->
            {:error, ReqLLM.Error.Invalid.Parameter.exception(parameter: message)}
        end
    end
  end

  defp validate_responses_api_attachments(%ReqLLM.Context{messages: messages}) do
    unsupported =
      messages
      |> Enum.flat_map(fn msg -> msg.content || [] end)
      |> Enum.filter(fn part ->
        part.type == :file and part.media_type not in @responses_api_mimes
      end)

    case unsupported do
      [] ->
        :ok

      parts ->
        mimes = parts |> Enum.map(& &1.media_type) |> Enum.uniq() |> Enum.join(", ")

        {:error,
         ReqLLM.Error.Invalid.Parameter.exception(
           parameter:
             "OpenAI Responses API supports image and PDF attachments. " <>
               "Found unsupported file types: #{mimes}."
         )}
    end
  end

  defp maybe_add_transcription_part(parts, _key, nil), do: parts
  defp maybe_add_transcription_part(parts, key, value), do: parts ++ [{key, to_string(value)}]

  defp maybe_put_authorization_header(request, :none), do: request

  defp maybe_put_authorization_header(request, credential) do
    Req.Request.put_header(request, "authorization", "Bearer #{credential.token}")
  end

  defp allow_missing_api_key?(%LLMDB.Model{} = model, opts) do
    auth_mode(opts) == :api_key and openai_compatible_backend(model, opts) == :ollama
  end

  defp auth_mode(opts) do
    case option_value(opts, :auth_mode) || provider_option_value(opts, :auth_mode) || :api_key do
      :oauth -> :oauth
      "oauth" -> :oauth
      _ -> :api_key
    end
  end

  defp openai_compatible_backend(%LLMDB.Model{extra: extra}, opts) do
    normalize_backend(
      provider_option_value(opts, :openai_compatible_backend) ||
        map_option_value(extra, :openai_compatible_backend)
    )
  end

  defp normalize_backend(:ollama), do: :ollama
  defp normalize_backend("ollama"), do: :ollama
  defp normalize_backend(_), do: nil

  defp missing_api_key_error?(message) when is_binary(message) do
    String.contains?(
      message,
      ":api_key option, config :req_llm, openai_api_key, or OPENAI_API_KEY env var"
    )
  end

  defp option_value(opts, key) when is_list(opts), do: Keyword.get(opts, key)
  defp option_value(opts, key) when is_map(opts), do: map_option_value(opts, key)

  defp provider_option_value(opts, key) do
    opts
    |> option_value(:provider_options)
    |> map_or_keyword_value(key)
  end

  defp map_option_value(opts, key) when is_map(opts) do
    Map.get(opts, key) || Map.get(opts, Atom.to_string(key))
  end

  defp map_option_value(_opts, _key), do: nil

  defp map_or_keyword_value(opts, key) when is_list(opts), do: Keyword.get(opts, key)
  defp map_or_keyword_value(opts, key) when is_map(opts), do: map_option_value(opts, key)
  defp map_or_keyword_value(_opts, _key), do: nil

  defp maybe_add_transcription_provider_parts(parts, opts) when is_list(opts) do
    Enum.reduce(opts, parts, fn
      {_key, nil}, acc ->
        acc

      {:timestamp_granularities, values}, acc when is_list(values) ->
        Enum.reduce(values, acc, fn v, inner_acc ->
          inner_acc ++ [{:"timestamp_granularities[]", to_string(v)}]
        end)

      {key, value}, acc ->
        acc ++ [{key, to_string(value)}]
    end)
  end

  defp maybe_add_transcription_provider_parts(parts, opts) when is_map(opts) do
    maybe_add_transcription_provider_parts(parts, Map.to_list(opts))
  end

  defp maybe_add_transcription_provider_parts(parts, _), do: parts
end
