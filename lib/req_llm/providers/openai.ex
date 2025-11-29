defmodule ReqLLM.Providers.OpenAI do
  @moduledoc """
  OpenAI provider implementation with dual-driver architecture for Chat and Responses APIs.

  ## Architecture

  This provider uses a metadata-driven routing system to dispatch requests to specialized
  API drivers:

  - **ChatAPI** (`ReqLLM.Providers.OpenAI.ChatAPI`) - Handles `/v1/chat/completions` endpoint
    for models like GPT-4, GPT-3.5, and other chat-based models.

  - **ResponsesAPI** (`ReqLLM.Providers.OpenAI.ResponsesAPI`) - Handles `/v1/responses` endpoint
    for reasoning models (o1, o3, o4, GPT-4.1, GPT-5) with extended thinking capabilities.

  The provider automatically routes requests based on the `"api"` field in model metadata:
  - `"api": "chat"` → uses ChatAPI driver (default)
  - `"api": "responses"` → uses ResponsesAPI driver

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

  ## Usage Normalization

  Both drivers normalize usage metrics to provide consistent field names:

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
  """

  use ReqLLM.Provider,
    id: :openai,
    default_base_url: "https://api.openai.com/v1",
    default_env_key: "OPENAI_API_KEY"

  require Logger

  @provider_schema [
    dimensions: [
      type: :pos_integer,
      doc: "Dimensions for embedding models (e.g., text-embedding-3-small supports 512-1536)"
    ],
    encoding_format: [type: :string, doc: "Format for embedding output (float, base64)"],
    max_completion_tokens: [
      type: :integer,
      doc: "Maximum completion tokens (required for reasoning models like o1, o3, gpt-5)"
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
    tool_outputs: [
      type: {:list, :any},
      doc:
        "Tool execution results for Responses API tool resume flow (list of %{call_id, output})"
    ]
  ]

  @compile {:no_warn_undefined, [{nil, :path, 0}, {nil, :attach_stream, 4}]}

  defp get_api_type(%LLMDB.Model{} = model) do
    get_in(model, [Access.key(:extra, %{}), :api])
  end

  defp select_api_mod(%LLMDB.Model{} = model) do
    case get_api_type(model) do
      "chat" -> ReqLLM.Providers.OpenAI.ChatAPI
      "responses" -> ReqLLM.Providers.OpenAI.ResponsesAPI
      _ -> ReqLLM.Providers.OpenAI.ChatAPI
    end
  end

  defp get_timeout_for_model(api_mod, opts) do
    user_timeout = Keyword.get(opts, :receive_timeout)
    default_timeout = Application.get_env(:req_llm, :receive_timeout, 30_000)
    thinking_timeout = Application.get_env(:req_llm, :thinking_timeout, 300_000)

    cond do
      user_timeout != nil ->
        user_timeout

      api_mod == ReqLLM.Providers.OpenAI.ResponsesAPI ->
        thinking_timeout

      true ->
        default_timeout
    end
  end

  @impl ReqLLM.Provider
  @doc """
  Custom prepare_request to route reasoning models to /v1/responses endpoint.

  - :chat operations detect model type and route to appropriate endpoint
  - :object operations maintain OpenAI-specific token handling
  """
  def prepare_request(:chat, model_spec, prompt, opts) do
    with {:ok, model} <- ReqLLM.model(model_spec),
         {:ok, context} <- ReqLLM.Context.normalize(prompt, opts),
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
            :reasoning_effort
          ]

      timeout = get_timeout_for_model(api_mod, processed_opts)

      request =
        Req.new(
          [
            url: path,
            method: :post,
            receive_timeout: timeout,
            pool_timeout: timeout,
            connect_options: [timeout: timeout]
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

  def prepare_request(operation, model_spec, input, opts) do
    case ReqLLM.Provider.Defaults.prepare_request(__MODULE__, operation, model_spec, input, opts) do
      {:error, %ReqLLM.Error.Invalid.Parameter{parameter: param}} ->
        custom_param = String.replace(param, inspect(__MODULE__), "OpenAI provider")
        {:error, ReqLLM.Error.Invalid.Parameter.exception(parameter: custom_param)}

      result ->
        result
    end
  end

  defp prepare_json_schema_request(model_spec, prompt, compiled_schema, opts) do
    schema_name = Map.get(compiled_schema, :name, "output_schema")
    json_schema = ReqLLM.Schema.to_json(compiled_schema.schema)

    json_schema = enforce_strict_schema_requirements(json_schema)

    opts_with_format =
      opts
      |> Keyword.update(
        :provider_options,
        [
          response_format: %{
            type: "json_schema",
            json_schema: %{
              name: schema_name,
              strict: true,
              schema: json_schema
            }
          },
          openai_parallel_tool_calls: false
        ],
        fn provider_opts ->
          provider_opts
          |> Keyword.put(:response_format, %{
            type: "json_schema",
            json_schema: %{
              name: schema_name,
              strict: true,
              schema: json_schema
            }
          })
          |> Keyword.put(:openai_parallel_tool_calls, false)
        end
      )
      |> put_default_max_tokens_for_model(model_spec)
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
      |> put_default_max_tokens_for_model(model_spec)
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

  @doc """
  Custom attach_stream to route reasoning models to /v1/responses endpoint for streaming.
  """
  @impl ReqLLM.Provider
  def attach_stream(model, context, opts, finch_name) do
    api_mod = select_api_mod(model)
    api_mod.attach_stream(model, context, opts, finch_name)
  end

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
    if get_api_type(model) == "responses" do
      ReqLLM.Providers.OpenAI.ResponsesAPI.decode_stream_event(event, model)
    else
      ReqLLM.Providers.OpenAI.ChatAPI.decode_stream_event(event, model)
    end
  end

  defp put_default_max_tokens_for_model(opts, model_spec) do
    case ReqLLM.model(model_spec) do
      {:ok, model} ->
        case get_api_type(model) do
          "responses" ->
            Keyword.put_new(opts, :max_completion_tokens, 4096)

          _ ->
            Keyword.put_new(opts, :max_tokens, 4096)
        end

      _ ->
        Keyword.put_new(opts, :max_tokens, 4096)
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

  defp enforce_strict_schema_requirements(
         %{"type" => "object", "properties" => properties} = schema
       ) do
    all_property_names = Map.keys(properties)

    schema
    |> Map.put("required", all_property_names)
    |> Map.put("additionalProperties", false)
  end

  defp enforce_strict_schema_requirements(schema), do: schema
end
