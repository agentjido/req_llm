defmodule ReqLLM.Providers.Azure do
  @moduledoc """
  Azure AI provider implementation.

  Supports Azure's AI services for accessing models from multiple families:

  ### OpenAI Models
  - GPT-4o, GPT-4, GPT-3.5 Turbo
  - Reasoning models (o1, o3 series)
  - Text embedding models

  ### Anthropic Claude Models
  - Claude 3 Opus, Sonnet, Haiku
  - Claude 3.5 Sonnet
  - Extended thinking/reasoning support

  ## Capabilities

  - Text generation (chat completions / messages)
  - Streaming responses with usage tracking
  - Tool calling (function calling)
  - Embeddings generation (OpenAI models only)
  - Multi-modal inputs (text and images)
  - Structured output generation
  - Extended thinking (Claude models)

  ## Key Differences from Direct Provider APIs

  1. **Custom endpoints**: Each Azure resource has a unique base URL.
     Azure supports two endpoint formats, auto-detected from the domain:

     - **Azure OpenAI Service** (`.cognitiveservices.azure.com` or `.openai.azure.com`):
       URL: `/deployments/{deployment}/chat/completions?api-version={version}`
       Model determined by deployment name in URL path.

  2. **API key authentication**: Uses `api-key` header for all model families

  3. **Bearer token authentication**: Prefix api_key with `"Bearer "` to use `Authorization: Bearer` header

  4. **Deployment names**: The deployment name is used either in the URL path
     (traditional) or in the request body (Foundry format)

  5. **No model field in body**: The deployment ID in the URL determines the model
     - **Azure AI Foundry** (`.services.ai.azure.com`):
       URL: `/models/chat/completions?api-version={version}`
       Model specified in request body (deployment name used).

  ## Authentication

  Environment variables are resolved by model family:

      # For OpenAI models (GPT, o1, o3, etc.)
      export AZURE_OPENAI_API_KEY=your-api-key
      export AZURE_OPENAI_BASE_URL=https://your-openai-resource.openai.azure.com/openai

      # For Anthropic models (Claude)
      export AZURE_ANTHROPIC_API_KEY=your-api-key
      export AZURE_ANTHROPIC_BASE_URL=https://your-anthropic-resource.openai.azure.com/openai

      # Universal fallbacks (if all models share the same Azure resource)
      export AZURE_API_KEY=your-api-key
      export AZURE_BASE_URL=https://your-resource.openai.azure.com/openai

      # Or pass directly in options (Azure OpenAI Service format)
      ReqLLM.generate_text(
        "azure:gpt-4o",
        "Hello!",
        api_key: "your-api-key",
        base_url: "https://my-resource.openai.azure.com/openai",
        deployment: "my-gpt4-deployment"
      )

      # Using Bearer token authentication (e.g., Entra ID / Azure AD tokens)
      ReqLLM.generate_text(
        "azure:gpt-4o",
        "Hello!",
        api_key: "Bearer eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9...",
        base_url: "https://my-resource.openai.azure.com/openai",
        deployment: "my-gpt4-deployment"
      )
      
      # Azure AI Foundry format (auto-detected from domain)
      ReqLLM.generate_text(
        "azure:deepseek-v3",
        "Hello!",
        api_key: "your-api-key",
        base_url: "https://my-resource.services.ai.azure.com",
        deployment: "deepseek-v3"
      )

  ## Examples

      # Basic usage
      {:ok, response} = ReqLLM.generate_text(
        "azure:gpt-4o",
        "What is Elixir?",
        base_url: "https://my-resource.openai.azure.com/openai",
        deployment: "my-gpt4-deployment"
      )

      # Streaming
      {:ok, response} = ReqLLM.stream_text(
        "azure:gpt-4o",
        "Tell me a story",
        base_url: "https://my-resource.openai.azure.com/openai",
        deployment: "my-gpt4-deployment"
      )

      # With tools
      tools = [%ReqLLM.Tool{name: "get_weather", ...}]
      {:ok, response} = ReqLLM.generate_text(
        "azure:gpt-4o",
        "What's the weather?",
        base_url: "https://my-resource.openai.azure.com/openai",
        deployment: "my-gpt4-deployment",
        tools: tools
      )

      # Embeddings
      {:ok, embedding} = ReqLLM.generate_embedding(
        "azure:text-embedding-3-small",
        "Hello world",
        base_url: "https://my-resource.openai.azure.com/openai",
        deployment: "my-embedding-deployment"
      )

      # OpenAI reasoning models (o1, o3, o4-mini)
      {:ok, response} = ReqLLM.generate_text(
        "azure:o1",
        "Solve this complex math problem step by step...",
        base_url: "https://my-resource.openai.azure.com/openai",
        deployment: "my-o1-deployment",
        max_tokens: 8000,
        provider_options: [reasoning_effort: "high"]
      )

      # Claude with extended thinking
      {:ok, response} = ReqLLM.generate_text(
        "azure:claude-3-5-sonnet-20241022",
        "Analyze this complex problem...",
        base_url: "https://my-resource.openai.azure.com/openai",
        deployment: "my-claude-deployment",
        thinking: %{type: "enabled", budget_tokens: 10000},
        max_tokens: 4096
      )

  ## Deployment Configuration

  Azure uses deployment names to route requests to specific model instances.
  If no deployment is specified, the model ID is used as a default (with a warning).

  To find your deployment name:
  1. Go to Azure OpenAI Studio (https://oai.azure.com/)
  2. Navigate to "Deployments"
  3. Copy the deployment name (e.g., "gpt-4o-prod", "claude-sonnet")

  ## Error Handling

  Common error scenarios:
  - Missing API key: Set `AZURE_API_KEY` (or family-specific: `AZURE_OPENAI_API_KEY`, `AZURE_ANTHROPIC_API_KEY`)
  - Missing base URL: Set `AZURE_BASE_URL` (or family-specific: `AZURE_OPENAI_BASE_URL`, `AZURE_ANTHROPIC_BASE_URL`)
  - Invalid deployment: Ensure the deployment name matches your Azure resource
  - Unsupported API version: Check Azure documentation for supported versions

  ## Extending for New Model Families

  Azure hosts multiple model families (OpenAI GPT, Anthropic Claude). To add
  support for a new model family:

  1. Create a formatter module under `ReqLLM.Providers.Azure.*` (see `Azure.OpenAI`
     or `Azure.Anthropic` as examples)
  2. Add the model prefix to `@model_families` map in this module
  3. Handle any family-specific endpoint paths in `get_chat_endpoint_path/3`
  4. Add family-specific headers in `get_anthropic_headers/2` if needed
  """

  use ReqLLM.Provider,
    id: :azure,
    default_base_url: "",
    default_env_key: "AZURE_API_KEY"

  alias ReqLLM.Providers.Anthropic.PlatformReasoning
  alias ReqLLM.Providers.OpenAI.AdapterHelpers

  require Logger

  @default_api_version "2025-04-01-preview"
  @anthropic_version "2023-06-01"

  @provider_schema [
    api_version: [
      type: :string,
      default: @default_api_version,
      doc: "Azure OpenAI API version (e.g., '2025-04-01-preview')"
    ],
    anthropic_version: [
      type: :string,
      default: @anthropic_version,
      doc: "Anthropic API version for Claude models (e.g., '2023-06-01')"
    ],
    deployment: [
      type: :string,
      doc: "Azure deployment name (overrides model.id for URL construction)"
    ],
    service_tier: [
      type: {:in, ["auto", "default", "priority"]},
      doc:
        "Service tier for request prioritization (OpenAI models only). " <>
          "'auto' uses deployment setting, 'default' for standard, 'priority' for priority processing."
    ],
    dimensions: [
      type: :pos_integer,
      doc: "Dimensions for embedding models (e.g., text-embedding-3-small supports 512-1536)"
    ],
    encoding_format: [
      type: :string,
      doc: "Format for embedding output (float, base64)"
    ],
    anthropic_prompt_cache: [
      type: :boolean,
      doc: "Enable Anthropic prompt caching for Claude models on Azure"
    ],
    anthropic_prompt_cache_ttl: [
      type: :string,
      doc: "TTL for cache (\"1h\" for one hour; omit for default ~5m)"
    ],
    additional_model_request_fields: [
      type: :map,
      doc:
        "Additional model-specific request fields (e.g., thinking config for Claude extended thinking)"
    ],
    # OpenAI-specific options - passed through to Azure.OpenAI formatter
    # These use loose validation (type: :any); actual validation happens at the API level
    response_format: [
      type: :any,
      doc: "Response format configuration (OpenAI models only)"
    ],
    openai_structured_output_mode: [
      type: :any,
      doc: "Structured output strategy for OpenAI models"
    ],
    openai_parallel_tool_calls: [
      type: :any,
      doc: "Parallel tool calls setting for OpenAI models"
    ],
    max_completion_tokens: [
      type: :any,
      doc: "Maximum completion tokens (OpenAI reasoning models)"
    ],
    verbosity: [
      type: {:or, [:atom, :string]},
      doc:
        "Constrains the verbosity of the model's response. Supported values: 'low', 'medium', 'high'. Defaults to 'medium'. (OpenAI models only)"
    ]
  ]

  # Default formatters by model family prefix (used when model.extra.wire.protocol is not "openai_responses")
  @model_families %{
    "gpt" => __MODULE__.OpenAI,
    "text-embedding" => __MODULE__.OpenAI,
    "codex" => __MODULE__.OpenAI,
    "o1" => __MODULE__.OpenAI,
    "o3" => __MODULE__.OpenAI,
    "o4" => __MODULE__.OpenAI,
    "deepseek" => __MODULE__.OpenAI,
    "mai-ds" => __MODULE__.OpenAI,
    "claude" => __MODULE__.Anthropic
  }

  @model_family_prefixes @model_families |> Map.keys() |> Enum.sort_by(&String.length/1, :desc)

  @service_tier_families ["gpt", "text-embedding", "o1", "o3", "o4"]

  @common_req_keys [:context, :operation, :text, :stream, :model, :provider_options, :deployment]

  @family_env_vars %{
    "claude" => "AZURE_ANTHROPIC_BASE_URL",
    "gpt" => "AZURE_OPENAI_BASE_URL",
    "text-embedding" => "AZURE_OPENAI_BASE_URL",
    "codex" => "AZURE_OPENAI_BASE_URL",
    "o1" => "AZURE_OPENAI_BASE_URL",
    "o3" => "AZURE_OPENAI_BASE_URL",
    "o4" => "AZURE_OPENAI_BASE_URL",
    "deepseek" => "AZURE_DEEPSEEK_BASE_URL",
    "mai-ds" => "AZURE_MAI_BASE_URL"
  }

  @family_api_key_env_vars %{
    "claude" => "AZURE_ANTHROPIC_API_KEY",
    "gpt" => "AZURE_OPENAI_API_KEY",
    "text-embedding" => "AZURE_OPENAI_API_KEY",
    "codex" => "AZURE_OPENAI_API_KEY",
    "o1" => "AZURE_OPENAI_API_KEY",
    "o3" => "AZURE_OPENAI_API_KEY",
    "o4" => "AZURE_OPENAI_API_KEY",
    "deepseek" => "AZURE_DEEPSEEK_API_KEY",
    "mai-ds" => "AZURE_MAI_API_KEY"
  }

  @doc """
  Prepares a request for Azure AI services.

  Routes to the appropriate formatter (OpenAI or Anthropic) based on model family.

  ## Operations

  - `:chat` - Text generation via chat completions or messages endpoint
  - `:object` - Structured output generation (uses tools for OpenAI, native for Claude)
  - `:embedding` - Vector embeddings (OpenAI embedding models only)
  """
  @impl ReqLLM.Provider
  def prepare_request(:chat, model_spec, prompt, opts) do
    do_prepare_chat_request(model_spec, prompt, opts)
  end

  def prepare_request(:object, model_spec, prompt, opts) do
    {:ok, model} = ReqLLM.model(model_spec)
    model_id = effective_model_id(model)
    model_family = get_model_family(model_id)

    opts_for_object =
      opts
      |> Keyword.put_new(:max_tokens, 4096)
      |> Keyword.put(:operation, :object)

    case model_family do
      "claude" ->
        do_prepare_chat_request(model_spec, prompt, opts_for_object)

      _ ->
        compiled_schema = Keyword.fetch!(opts, :compiled_schema)

        structured_output_tool =
          ReqLLM.Tool.new!(
            name: "structured_output",
            description: "Generate structured output matching the provided schema",
            parameter_schema: compiled_schema.schema,
            callback: fn _args -> {:ok, "structured output generated"} end
          )

        # Check if model supports forced tool choice (specific tool by name)
        # If not, fall back to "required" which just requires *some* tool call
        tool_choice =
          if get_in(model.capabilities, [:tools, :forced_choice]) == false do
            "required"
          else
            %{type: "function", function: %{name: "structured_output"}}
          end

        opts_with_tool =
          opts_for_object
          |> Keyword.update(:tools, [structured_output_tool], &[structured_output_tool | &1])
          |> Keyword.put(:tool_choice, tool_choice)

        do_prepare_chat_request(model_spec, prompt, opts_with_tool)
    end
  end

  def prepare_request(:embedding, model_spec, text, opts) do
    do_prepare_embedding_request(model_spec, text, opts)
  end

  def prepare_request(operation, model_spec, input, opts) do
    ReqLLM.Provider.Defaults.prepare_request(__MODULE__, operation, model_spec, input, opts)
  end

  defp do_prepare_chat_request(model_spec, prompt, opts) do
    with {:ok, model} <- ReqLLM.model(model_spec),
         {:ok, context} <- ReqLLM.Context.normalize(prompt, opts) do
      model_id = effective_model_id(model)
      model_family = get_model_family(model_id)

      # Resolve base_url BEFORE Options.process so put_new_lazy won't inject placeholder
      resolved_base_url = resolve_base_url(model_family, opts)

      opts_with_context =
        opts
        |> Keyword.put(:context, context)
        |> Keyword.put(:base_url, resolved_base_url)

      http_opts = Keyword.get(opts, :req_http_options, [])

      {:ok, processed_opts} =
        ReqLLM.Provider.Options.process(__MODULE__, :chat, model, opts_with_context)

      operation = opts[:operation] || :chat

      processed_opts =
        processed_opts
        |> maybe_clean_thinking_after_translation(model_family, operation)
        |> maybe_warn_service_tier(model_family, model_id)

      {api_version, deployment, base_url} =
        extract_azure_credentials(model, processed_opts)

      formatter = get_formatter(model_id, model)

      path = get_chat_endpoint_path(model_id, model, deployment, api_version, base_url)

      Logger.debug(
        "[Azure prepare_request] model_family=#{model_family}, base_url=#{base_url}, path=#{path}, formatter=#{inspect(formatter)}"
      )

      body =
        formatter.format_request(model_id, context, processed_opts)
        |> maybe_add_model_for_foundry(deployment, base_url)

      req_keys = supported_provider_options() ++ @common_req_keys
      default_timeout = default_timeout_for_model(model_id, processed_opts)

      request =
        Req.new(
          [
            url: path,
            method: :post,
            json: body,
            receive_timeout: Keyword.get(processed_opts, :receive_timeout, default_timeout)
          ] ++ http_opts
        )
        |> Req.Request.register_options(req_keys)
        |> Req.Request.merge_options(
          Keyword.take(processed_opts, req_keys) ++
            [
              model: model.id,
              base_url: base_url
            ]
        )
        |> Req.Request.put_private(:model, model)
        |> Req.Request.put_private(:formatter, formatter)
        |> attach(model, processed_opts)

      {:ok, request}
    end
  end

  defp do_prepare_embedding_request(model_spec, text, opts) do
    with {:ok, model} <- ReqLLM.model(model_spec),
         model_id = effective_model_id(model),
         :ok <- validate_embedding_model(model_id) do
      model_family = get_model_family(model_id)

      # Resolve base_url BEFORE Options.process
      resolved_base_url = resolve_base_url(model_family, opts)

      opts_with_text =
        opts
        |> Keyword.merge(text: text, operation: :embedding)
        |> Keyword.put(:base_url, resolved_base_url)

      http_opts = Keyword.get(opts, :req_http_options, [])

      {:ok, processed_opts} =
        ReqLLM.Provider.Options.process(__MODULE__, :embedding, model, opts_with_text)

      {api_version, deployment, base_url} =
        extract_azure_credentials(model, processed_opts)

      formatter = get_formatter(model_id, model)

      path = get_embedding_endpoint_path(deployment, api_version, base_url)

      body =
        formatter.format_embedding_request(model_id, text, processed_opts)
        |> maybe_add_model_for_foundry(deployment, base_url)

      req_keys = supported_provider_options() ++ @common_req_keys

      request =
        Req.new(
          [
            url: path,
            method: :post,
            json: body,
            receive_timeout: Keyword.get(processed_opts, :receive_timeout, 30_000)
          ] ++ http_opts
        )
        |> Req.Request.register_options(req_keys)
        |> Req.Request.merge_options(
          Keyword.take(processed_opts, req_keys) ++
            [
              model: model.id,
              base_url: base_url
            ]
        )
        |> Req.Request.put_private(:model, model)
        |> Req.Request.put_private(:formatter, formatter)
        |> attach(model, processed_opts)

      {:ok, request}
    end
  end

  @doc """
  Attaches Azure-specific authentication and pipeline steps to a request.

  Authentication is determined by the api_key format:
  - If api_key starts with "Bearer ", uses `Authorization: Bearer` header
  - Otherwise, uses `api-key` header for OpenAI models, `x-api-key` for Claude

  Also adds model-family specific headers (e.g., `anthropic-version` for Claude models).
  """
  @impl ReqLLM.Provider
  def attach(request, model_input, user_opts) do
    {:ok, %LLMDB.Model{} = model} = ReqLLM.model(model_input)

    if model.provider != provider_id() do
      raise ReqLLM.Error.Invalid.Provider.exception(provider: model.provider)
    end

    model_id = effective_model_id(model)
    model_family = get_model_family(model_id)

    {api_key, extra_option_keys} = resolve_api_key(model_family, model, user_opts)
    extra_headers = get_anthropic_headers(model_id, user_opts)
    {auth_header_name, auth_header_value} = build_auth_header(api_key, model_family)

    request
    |> Req.Request.put_header("content-type", "application/json")
    |> Req.Request.put_header(auth_header_name, auth_header_value)
    |> then(fn req ->
      Enum.reduce(extra_headers, req, fn {key, value}, acc ->
        Req.Request.put_header(acc, key, value)
      end)
    end)
    |> Req.Request.register_options(extra_option_keys ++ [:deployment])
    |> Req.Request.merge_options(user_opts)
    |> ReqLLM.Step.Retry.attach()
    |> ReqLLM.Step.Error.attach()
    |> Req.Request.append_response_steps(llm_decode_response: &decode_response/1)
    |> ReqLLM.Step.Usage.attach(model)
    |> ReqLLM.Step.Fixture.maybe_attach(model, user_opts)
  end

  @doc """
  Pass-through encoding - body is pre-encoded by formatters in `prepare_request`.

  This follows the same pattern as Amazon Bedrock where the model-family-specific
  formatter handles body encoding during request preparation.
  """
  @impl ReqLLM.Provider
  def encode_body(request) do
    request
  end

  @doc """
  Decodes Azure API responses using the appropriate model-family formatter.

  Routes to `Azure.OpenAI.parse_response/3` or `Azure.Anthropic.parse_response/3`
  based on the model. Handles both successful responses and error extraction.
  """
  @impl ReqLLM.Provider
  def decode_response({request, %{status: status} = response}) when status in 200..299 do
    # Embedding responses should return raw body, not parsed ReqLLM.Response
    if request.options[:operation] == :embedding do
      {request, response}
    else
      model = Req.Request.get_private(request, :model)
      model_id = effective_model_id(model)
      formatter = Req.Request.get_private(request, :formatter) || get_formatter(model_id, model)

      opts =
        []
        |> then(
          &if request.options[:operation],
            do: Keyword.put(&1, :operation, request.options[:operation]),
            else: &1
        )
        |> then(
          &if request.options[:context],
            do: Keyword.put(&1, :context, request.options[:context]),
            else: &1
        )

      result = formatter.parse_response(response.body, model, opts)

      case result do
        {:ok, parsed} ->
          {request, %{response | body: parsed}}

        {:error, reason} ->
          {request,
           ReqLLM.Error.API.Response.exception(
             reason: "Failed to parse Azure response: #{inspect(reason)}",
             status: response.status,
             response_body: response.body
           )}
      end
    end
  end

  def decode_response({request, response}) do
    reason = extract_error_message(response.body)

    {request,
     ReqLLM.Error.API.Response.exception(
       reason: reason,
       status: response.status,
       response_body: response.body
     )}
  end

  defp extract_error_message(body) when is_map(body) do
    case body do
      %{"error" => %{"message" => message, "type" => type, "code" => code}} ->
        "#{type} (#{code}): #{message}"

      %{"error" => %{"message" => message, "code" => code}} ->
        "(#{code}): #{message}"

      %{"error" => %{"message" => message}} ->
        message

      %{"error" => error} when is_binary(error) ->
        error

      %{"message" => message} ->
        message

      _ ->
        "Azure API error: #{inspect(body)}"
    end
  end

  defp extract_error_message(body) when is_binary(body), do: body
  defp extract_error_message(_body), do: "Azure API error"

  @doc """
  Builds a Finch request for streaming responses.

  Constructs the appropriate endpoint URL based on model family and adds
  Azure-specific headers (`api-key`, `anthropic-version` for Claude).
  """
  @impl ReqLLM.Provider
  def attach_stream(model, context, opts, _finch_name) do
    if model.provider != provider_id() do
      raise ReqLLM.Error.Invalid.Provider.exception(provider: model.provider)
    end

    model_id = effective_model_id(model)
    model_family = get_model_family(model_id)

    {provider_options, standard_opts} = Keyword.pop(opts, :provider_options, [])
    flattened_opts = Keyword.merge(standard_opts, provider_options)

    # Resolve base_url early (attach_stream doesn't use Options.process)
    resolved_base_url = resolve_base_url(model_family, flattened_opts)
    flattened_opts = Keyword.put(flattened_opts, :base_url, resolved_base_url)

    {pre_validated_opts, _warnings} = pre_validate_options(:chat, model, flattened_opts)
    {translated_opts, _warnings} = translate_options(:chat, model, pre_validated_opts)

    operation = opts[:operation] || :chat

    translated_opts =
      translated_opts
      |> maybe_clean_thinking_after_translation(model_family, operation)
      |> maybe_warn_service_tier(model_family, model_id)

    {api_key, _extra_option_keys} = resolve_api_key(model_family, model, translated_opts)

    {api_version, deployment, base_url} =
      extract_azure_credentials(model, translated_opts)

    formatter = get_formatter(model_id, model)

    path = get_chat_endpoint_path(model_id, model, deployment, api_version, base_url)
    url = "#{base_url}#{path}"

    Logger.debug(
      "[Azure attach_stream] model_family=#{model_family}, url=#{url}, formatter=#{inspect(formatter)}"
    )

    base_headers = [
      build_auth_header(api_key, model_family),
      {"content-type", "application/json"},
      {"accept", "text/event-stream"}
    ]

    extra_headers = get_anthropic_headers(model_id, translated_opts)
    headers = base_headers ++ extra_headers

    body =
      formatter.format_request(model_id, context, Keyword.put(translated_opts, :stream, true))
      |> maybe_add_model_for_foundry(deployment, base_url)

    finch_request = Finch.build(:post, url, headers, Jason.encode!(body))
    {:ok, finch_request}
  rescue
    error ->
      Logger.error(
        "Failed to build Azure stream request: #{Exception.message(error)}\n" <>
          "Stacktrace: #{Exception.format_stacktrace(__STACKTRACE__)}"
      )

      {:error,
       ReqLLM.Error.API.Request.exception(
         reason: "Failed to build Azure stream request: #{Exception.message(error)}"
       )}
  end

  @doc """
  Decodes Server-Sent Events for streaming responses.

  Delegates to the appropriate model-family formatter for SSE parsing.
  """
  @impl ReqLLM.Provider
  def decode_stream_event(event, model) do
    {chunks, _state} = decode_stream_event(event, model, nil)
    chunks
  end

  @impl ReqLLM.Provider
  def decode_stream_event(event, model, state) do
    model_id = effective_model_id(model)
    formatter = get_formatter(model_id, model)

    if function_exported?(formatter, :decode_stream_event, 3) do
      formatter.decode_stream_event(event, model, state)
    else
      chunks = formatter.decode_stream_event(event, model)
      {chunks, state}
    end
  end

  @doc """
  Extracts usage/token information from API responses.

  Delegates to the model-family formatter for provider-specific usage extraction.
  """
  @impl ReqLLM.Provider
  def extract_usage(body, model) do
    model_id = effective_model_id(model)
    formatter = get_formatter(model_id, model)

    if function_exported?(formatter, :extract_usage, 2) do
      formatter.extract_usage(body, model)
    else
      {:error, :no_usage_extractor}
    end
  end

  @doc """
  Translates ReqLLM options to provider-specific format.

  Delegates to `OpenAI.translate_options/3` for GPT models or
  `Anthropic.translate_options/3` for Claude models to handle
  model-specific parameter requirements.
  """
  @impl ReqLLM.Provider
  def translate_options(operation, model, opts) do
    model_id = effective_model_id(model)

    case get_model_family(model_id) do
      family when family in ["gpt", "text-embedding", "o1", "o3", "o4", "deepseek", "mai-ds"] ->
        synthetic_model = %{model | provider: :openai}
        ReqLLM.Providers.OpenAI.translate_options(operation, synthetic_model, opts)

      "claude" ->
        synthetic_model = %{model | provider: :anthropic}
        ReqLLM.Providers.Anthropic.translate_options(operation, synthetic_model, opts)

      _ ->
        {opts, []}
    end
  end

  @doc """
  Pre-validates and transforms options before request building.

  Delegates to the model-specific formatter (Azure.OpenAI or Azure.Anthropic).
  This handles model-specific requirements like reasoning parameter translation.

  Note: This is not yet a formal Provider callback but is called by
  Options.process/4 if the provider exports it.
  """
  def pre_validate_options(operation, model, opts) do
    model_id = effective_model_id(model)
    formatter = get_formatter(model_id, model)

    if function_exported?(formatter, :pre_validate_options, 3) do
      formatter.pre_validate_options(operation, model, opts)
    else
      {opts, []}
    end
  end

  @doc """
  Returns thinking constraints for extended thinking support.

  Azure hosts both OpenAI and Anthropic models with different constraints:
  - Claude models require temperature=1.0 for extended thinking (enforced in
    `Azure.Anthropic.pre_validate_options/3`)
  - OpenAI reasoning models (o1, o3, o4) use `reasoning_effort` parameter,
    not the extended thinking protocol

  Returns `:none` since there are no *universal* constraints that apply to all
  Azure models. Model-family-specific constraints are enforced in the respective
  formatter modules during `pre_validate_options`.
  """
  @impl ReqLLM.Provider
  def thinking_constraints do
    :none
  end

  @doc """
  Checks if an error indicates missing Azure credentials.

  Returns true if the error message mentions AZURE_OPENAI_API_KEY or api_key.
  """
  @impl ReqLLM.Provider
  def credential_missing?(%ArgumentError{message: msg}) when is_binary(msg) do
    String.contains?(msg, "AZURE_OPENAI_API_KEY") or
      String.contains?(msg, "api_key")
  end

  def credential_missing?(_), do: false

  defp extract_azure_credentials(model, opts) do
    # base_url should already be resolved and set in opts by prepare_request
    base_url = opts[:base_url] || raise "base_url not set - this is a bug"
    validate_base_url!(base_url)

    api_version = get_provider_option(opts, :api_version, @default_api_version)
    deployment = get_deployment_with_warning(model, opts)

    {api_version, deployment, base_url}
  end

  defp resolve_base_url(model_family, opts) do
    # Standard precedence: opts -> app config -> env var -> default
    opts[:base_url] ||
      Application.get_env(:req_llm, :azure, []) |> Keyword.get(:base_url) ||
      env_base_url(model_family) ||
      System.get_env("AZURE_BASE_URL") ||
      default_base_url()
  end

  defp env_base_url(model_family) do
    case Map.get(@family_env_vars, model_family) do
      nil -> nil
      env_var -> System.get_env(env_var)
    end
  end

  defp resolve_api_key(model_family, _model, opts) do
    # Follow standard ReqLLM.Keys precedence: opts -> app config -> env var
    # But with family-specific env vars taking precedence over universal fallback
    {api_key, source} =
      cond do
        key = opts[:api_key] ->
          {key, "opts[:api_key]"}

        key = Application.get_env(:req_llm, :azure_api_key) ->
          {key, "app config"}

        key = env_api_key(model_family) ->
          {key, "#{Map.get(@family_api_key_env_vars, model_family)}"}

        key = System.get_env("AZURE_API_KEY") ->
          {key, "AZURE_API_KEY"}

        true ->
          {nil, "none"}
      end

    auth_mode =
      if api_key && String.starts_with?(api_key, "Bearer "), do: "bearer", else: "api_key"

    Logger.debug(
      "[Azure resolve_api_key] model_family=#{model_family}, source=#{source}, auth_mode=#{auth_mode}, key_present=#{not is_nil(api_key)}"
    )

    if is_nil(api_key) or api_key == "" do
      family_env = Map.get(@family_api_key_env_vars, model_family, "AZURE_API_KEY")

      raise ReqLLM.Error.Invalid.Parameter.exception(
              parameter:
                ":api_key option, config :req_llm, :azure_api_key, " <>
                  "#{family_env}, or AZURE_API_KEY env var"
            )
    end

    extra_option_keys =
      [
        :model,
        :compiled_schema,
        :temperature,
        :max_tokens,
        :max_completion_tokens,
        :app_referer,
        :app_title,
        :fixture,
        :api_key,
        :on_unsupported,
        :n,
        :tools,
        :tool_choice,
        :req_http_options,
        :frequency_penalty,
        :system_prompt,
        :top_p,
        :presence_penalty,
        :seed,
        :stop,
        :user,
        :reasoning_effort
      ] ++ supported_provider_options()

    {api_key, extra_option_keys}
  end

  defp env_api_key(model_family) do
    case Map.get(@family_api_key_env_vars, model_family) do
      nil -> nil
      env_var -> System.get_env(env_var)
    end
  end

  defp build_auth_header("Bearer " <> token, _model_family) do
    token = String.trim(token)

    cond do
      token == "" ->
        raise ReqLLM.Error.Invalid.Parameter.exception(
                parameter: ":api_key - Bearer token cannot be empty"
              )

      String.contains?(token, ["\r", "\n"]) ->
        raise ReqLLM.Error.Invalid.Parameter.exception(
                parameter: ":api_key - Bearer token contains invalid characters"
              )

      true ->
        {"authorization", "Bearer #{token}"}
    end
  end

  defp build_auth_header(api_key, "claude") do
    {"x-api-key", api_key}
  end

  defp build_auth_header(api_key, _model_family) do
    {"api-key", api_key}
  end

  defp get_deployment_with_warning(model, opts) do
    explicit_deployment =
      get_in(opts, [:provider_options, :deployment]) || Keyword.get(opts, :deployment)

    if explicit_deployment do
      explicit_deployment
    else
      Logger.warning(
        "No deployment specified for Azure model '#{model.id}'. " <>
          "Defaulting to '#{model.id}' as deployment name. " <>
          "Set deployment: \"your-deployment-name\" to avoid this warning."
      )

      model.id
    end
  end

  defp validate_base_url!(base_url) when base_url in [nil, ""] do
    raise ArgumentError, """
    Azure requires a base_url for your resource.

    Please provide one of:
      # Azure OpenAI Service (traditional)
      base_url: "https://YOUR-RESOURCE-NAME.openai.azure.com/openai"

      # Azure AI Foundry
      base_url: "https://YOUR-RESOURCE-NAME.services.ai.azure.com"

    Or set the AZURE_OPENAI_BASE_URL environment variable.
    """
  end

  defp validate_base_url!(_base_url), do: :ok

  # Retrieves an option with provider_options taking precedence over top-level opts.
  # This allows users to specify options either at the top level or nested under provider_options.
  defp get_provider_option(opts, key, default) do
    provider_opts = Keyword.get(opts, :provider_options, [])

    case Keyword.fetch(provider_opts, key) do
      {:ok, value} -> value
      :error -> Keyword.get(opts, key, default)
    end
  end

  # Returns the model ID to use for API calls, preferring provider_model_id if set.
  defp effective_model_id(model), do: model.provider_model_id || model.id

  # Checks if a model uses the Responses API (based on model.extra.wire.protocol metadata).
  # The model metadata should have `extra: %{wire: %{protocol: "openai_responses"}}` for Responses API models.
  defp uses_responses_api?(%LLMDB.Model{} = model) do
    get_in(model, [Access.key(:extra, %{}), :wire, :protocol]) == "openai_responses"
  end

  # Determines the model family (claude, gpt-4o, o1, etc.) from a model ID.
  # Uses longest-prefix matching to handle overlapping prefixes correctly.
  defp get_model_family(model_id) do
    case Enum.find(@model_family_prefixes, &String.starts_with?(model_id, &1)) do
      nil ->
        supported = @model_family_prefixes |> Enum.join(", ")

        raise ArgumentError, """
        Unknown Azure model family for '#{model_id}'.

        Supported model prefixes: #{supported}

        If this is a new model, add its prefix to @model_families in #{__MODULE__}.
        """

      family ->
        family
    end
  end

  # Validates that a model supports embeddings (must be text-embedding-* family).
  defp validate_embedding_model(model_id) do
    case get_model_family(model_id) do
      "text-embedding" ->
        :ok

      _ ->
        {:error,
         ReqLLM.Error.Invalid.Parameter.exception(
           parameter: """
           Model '#{model_id}' does not support embeddings.

           For embeddings on Azure, use an OpenAI embedding model:
             azure:text-embedding-3-small
             azure:text-embedding-3-large
             azure:text-embedding-ada-002
           """
         )}
    end
  end

  # Returns the formatter module for a model.
  # Responses API models use Azure.ResponsesAPI adapter, others use family-specific formatters.
  defp get_formatter(model_id, model) do
    if uses_responses_api?(model) do
      __MODULE__.ResponsesAPI
    else
      model_family = get_model_family(model_id)
      Map.fetch!(@model_families, model_family)
    end
  end

  # Builds the endpoint path based on model type, family, and endpoint format.
  # Supports two Azure endpoint formats:
  # - Traditional (cognitiveservices.azure.com): /deployments/{deployment}/chat/completions
  # - Foundry (services.ai.azure.com): /models/chat/completions (model in body)
  # Special cases:
  # - Responses API models: /responses (model in body)
  # - Claude: /v1/messages (model in body)
  defp get_chat_endpoint_path(model_id, model, deployment, api_version, base_url)
       when is_struct(model) do
    if uses_responses_api?(model) do
      "/responses?api-version=#{api_version}"
    else
      get_chat_endpoint_path_by_family(model_id, deployment, api_version, base_url)
    end
  end

  defp get_chat_endpoint_path_by_family(model_id, deployment, api_version, base_url) do
    model_family = get_model_family(model_id)

    case model_family do
      "claude" ->
        # Azure Anthropic: model goes in body, not URL
        "/v1/messages"

      _ ->
        if uses_foundry_format?(base_url) do
          # Azure AI Foundry: model specified in request body
          "/models/chat/completions?api-version=#{api_version}"
        else
          # Azure OpenAI (traditional): deployment in URL determines model
          "/deployments/#{deployment}/chat/completions?api-version=#{api_version}"
        end
    end
  end

  # Builds the embedding endpoint path based on endpoint format.
  defp get_embedding_endpoint_path(deployment, api_version, base_url) do
    if uses_foundry_format?(base_url) do
      # Azure AI Foundry: model specified in request body
      "/models/embeddings?api-version=#{api_version}"
    else
      # Azure OpenAI (traditional): deployment in URL determines model
      "/deployments/#{deployment}/embeddings?api-version=#{api_version}"
    end
  end

  # Returns Anthropic-specific headers for Claude models on Azure.
  defp get_anthropic_headers(model_id, opts) do
    model_family = get_model_family(model_id)

    case model_family do
      "claude" ->
        version = get_provider_option(opts, :anthropic_version, @anthropic_version)
        [{"anthropic-version", version}]

      _ ->
        []
    end
  end

  # Cleans up thinking options after translation for Claude models.
  # Delegates to PlatformReasoning for consistent cross-platform behavior.
  defp maybe_clean_thinking_after_translation(opts, model_family, operation) do
    if model_family == "claude" do
      PlatformReasoning.maybe_clean_thinking_after_translation(opts, operation)
    else
      opts
    end
  end

  # Computes the default timeout based on model capabilities.
  # Reasoning/thinking models get longer timeouts (120-180s) than standard models (30s).
  defp default_timeout_for_model(model_id, opts) do
    model_family = get_model_family(model_id)

    has_thinking =
      Keyword.has_key?(opts, :thinking) ||
        get_in(opts, [:provider_options, :thinking]) ||
        get_in(opts, [:provider_options, :additional_model_request_fields, :thinking])

    reasoning_effort =
      opts[:reasoning_effort] || get_in(opts, [:provider_options, :reasoning_effort])

    cond do
      model_family == "claude" && (has_thinking || reasoning_effort) -> 180_000
      model_family in ["o1", "o3", "o4"] && reasoning_effort -> 180_000
      model_family in ["o1", "o3", "o4"] -> 120_000
      AdapterHelpers.gpt5_model?(model_id) -> 120_000
      true -> 30_000
    end
  end

  defp maybe_warn_service_tier(opts, model_family, model_id) do
    service_tier =
      get_in(opts, [:provider_options, :service_tier]) ||
        Keyword.get(opts, :service_tier)

    if service_tier && model_family not in @service_tier_families do
      Logger.warning(
        "service_tier is only supported for OpenAI models, ignoring for '#{model_id}'"
      )

      opts
      |> Keyword.update(:provider_options, [], &Keyword.delete(&1, :service_tier))
      |> Keyword.delete(:service_tier)
    else
      opts
    end
  end

  # Detects if the base_url uses Azure AI Foundry format based on domain.
  # Foundry format uses /models/chat/completions with model in request body.
  # Traditional format uses /deployments/{deployment}/chat/completions.
  @doc false
  def uses_foundry_format?(base_url) when is_binary(base_url) do
    case URI.parse(base_url) do
      %URI{host: nil} -> false
      %URI{host: host} -> String.ends_with?(host, ".services.ai.azure.com")
    end
  end

  def uses_foundry_format?(_), do: false

  # Adds the model field to request body when using Foundry format.
  # Traditional Azure OpenAI format doesn't need model in body (deployment in URL determines it).
  # Foundry format requires model in body since URL is generic /models/chat/completions.
  defp maybe_add_model_for_foundry(body, deployment, base_url)
       when is_map(body) and is_binary(deployment) and deployment != "" do
    if uses_foundry_format?(base_url) do
      Map.put(body, "model", deployment)
    else
      body
    end
  end

  defp maybe_add_model_for_foundry(body, _deployment, _base_url), do: body
end
