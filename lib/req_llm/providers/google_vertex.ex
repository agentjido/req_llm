defmodule ReqLLM.Providers.GoogleVertex do
  @moduledoc """
  Google Vertex AI provider implementation.

  Supports Vertex AI's unified API for accessing multiple AI models including:
  - Anthropic Claude models (claude-haiku-4-5, claude-sonnet-4-5, claude-opus-4-1)
  - Google Gemini models (gemini-2.0-flash, gemini-2.5-flash, gemini-2.5-pro)
  - And more as Google adds them

  ## Authentication

  Vertex AI uses Google Cloud OAuth2 authentication with service accounts.

  ### Service Account (Recommended)

      # Option 1: Environment variables
      export GOOGLE_APPLICATION_CREDENTIALS="/path/to/service-account.json"
      export GOOGLE_CLOUD_PROJECT="your-project-id"
      export GOOGLE_CLOUD_REGION="us-central1"

      # Option 2: Pass directly in options
      ReqLLM.generate_text(
        "google-vertex:claude-haiku-4-5@20251001",
        "Hello",
        provider_options: [
          service_account_json: "/path/to/service-account.json",
          project_id: "your-project-id",
          region: "us-central1"
        ]
      )

  ### Access Token

      ReqLLM.generate_text(
        "google-vertex:gemini-2.5-flash",
        "Hello from Vertex",
        provider_options: [
          access_token: "your-access-token",
          project_id: "your-project-id",
          region: "us-central1"
        ]
      )

  ## Examples

      # Simple text generation with Claude on Vertex
      {:ok, response} = ReqLLM.generate_text(
        "google-vertex:claude-haiku-4-5@20251001",
        "Hello!"
      )

      # Streaming
      {:ok, response} = ReqLLM.stream_text(
        "google-vertex:claude-haiku-4-5@20251001",
        "Tell me a story"
      )

  ## Extending for New Models

  To add support for a new model family:

  1. Add the model family to `@model_families`
  2. Implement the formatter module (e.g., `ReqLLM.Providers.GoogleVertex.Gemini`)
  3. The formatter needs:
     - `format_request/3` - Convert ReqLLM context to provider format
     - `parse_response/2` - Convert provider response to ReqLLM format
     - `extract_usage/2` - Extract usage information
  """

  use ReqLLM.Provider,
    id: :google_vertex,
    default_base_url: "https://{region}-aiplatform.googleapis.com",
    default_env_key: "GOOGLE_APPLICATION_CREDENTIALS"

  alias ReqLLM.ModelHelpers

  require Logger

  @provider_schema [
    service_account_json: [
      type: :string,
      doc:
        "Path to service account JSON file (can also use GOOGLE_APPLICATION_CREDENTIALS env var)"
    ],
    access_token: [
      type: :string,
      doc:
        "Pre-existing OAuth2 access token (bypasses service account authentication and token caching)"
    ],
    project_id: [
      type: :string,
      doc: "Google Cloud project ID (can also use GOOGLE_CLOUD_PROJECT env var)"
    ],
    region: [
      type: :string,
      default: "global",
      doc: "Google Cloud region where Vertex AI is available (default 'global' for newest models)"
    ],
    additional_model_request_fields: [
      type: :map,
      doc:
        "Additional model-specific request fields (e.g., thinking config for extended thinking support)"
    ]
  ]

  @default_region "global"
  @vertex_base_url_global "https://aiplatform.googleapis.com"
  @vertex_base_url_regional "https://{region}-aiplatform.googleapis.com"

  # Model family to formatter module mapping
  @model_families %{
    "claude" => ReqLLM.Providers.GoogleVertex.Anthropic,
    "gemini" => ReqLLM.Providers.GoogleVertex.Gemini
  }

  @impl ReqLLM.Provider
  def prepare_request(:chat, model_input, input, opts) do
    do_prepare_request(model_input, input, opts)
  end

  @impl ReqLLM.Provider
  def prepare_request(:object, model_input, input, opts) do
    # Mark operation type so formatter can handle appropriately
    opts_with_operation = Keyword.put(opts, :operation, :object)
    do_prepare_request(model_input, input, opts_with_operation)
  end

  defp do_prepare_request(model_input, input, opts) do
    with {:ok, model} <- ReqLLM.model(model_input),
         {:ok, context} <- ReqLLM.Context.normalize(input, opts) do
      # Process and validate options
      operation = opts[:operation] || :chat

      {gcp_creds, other_opts, model_family, formatter} =
        process_and_validate_opts(opts, model, operation)

      # Add context to opts so it can be stored in request.options
      other_opts = Keyword.put(other_opts, :context, context)

      # Build request body using formatter
      body = formatter.format_request(model.provider_model_id || model.id, context, other_opts)

      # Build Vertex AI endpoint URL
      region = gcp_creds[:region] || @default_region
      project_id = gcp_creds[:project_id]

      # Vertex AI URL structure depends on model family
      path =
        build_model_path(model_family, model.provider_model_id || model.id, project_id, region)

      base_url = build_base_url(region)
      url = "#{base_url}#{path}"

      # Reasoning models with extended thinking need longer timeouts
      http_opts = Keyword.get(other_opts, :req_http_options, [])

      timeout =
        if ModelHelpers.reasoning_enabled?(model) do
          180_000
        else
          60_000
        end

      # Create request
      request =
        Req.new(
          [
            url: url,
            method: :post,
            json: body,
            receive_timeout: timeout,
            headers: [
              {"content-type", "application/json"}
            ]
          ] ++ http_opts
        )
        |> Req.Request.register_options([:context, :operation])
        |> Req.Request.merge_options(Keyword.take(other_opts, [:context, :operation]))
        |> Req.Request.put_private(:gcp_credentials, gcp_creds)
        |> Req.Request.put_private(:model, model)
        |> attach(model, other_opts)

      {:ok, request}
    end
  end

  @impl ReqLLM.Provider
  def attach(request, model, opts) do
    # Get GCP credentials - store them for lazy auth in request step
    gcp_creds = Req.Request.get_private(request, :gcp_credentials)

    request
    |> ReqLLM.Step.Error.attach()
    |> ReqLLM.Step.Retry.attach()
    |> Req.Request.append_response_steps(llm_decode_response: &decode_response/1)
    |> ReqLLM.Step.Usage.attach(model)
    |> ReqLLM.Step.Fixture.maybe_attach(model, opts)
    |> put_gcp_auth(gcp_creds)
  end

  # Attach GCP OAuth2 authentication as a request step
  # This runs AFTER Fixture.maybe_attach so replay mode can intercept before auth
  defp put_gcp_auth(request, gcp_creds) do
    Req.Request.append_request_steps(request,
      gcp_vertex_auth: fn req ->
        Logger.debug("Getting GCP access token for Vertex AI")

        case fetch_access_token(gcp_creds) do
          {:ok, access_token} ->
            Logger.debug("Successfully obtained GCP access token")
            Req.Request.put_header(req, "authorization", "Bearer #{access_token}")

          {:error, reason} ->
            Logger.error("Failed to get GCP access token: #{inspect(reason)}")
            raise "Failed to get GCP access token: #{inspect(reason)}"
        end
      end
    )
  end

  defp fetch_access_token(%{access_token: token})
       when is_binary(token) and byte_size(token) > 0 do
    {:ok, token}
  end

  defp fetch_access_token(%{service_account_json: service_account_json})
       when is_binary(service_account_json) do
    ReqLLM.Providers.GoogleVertex.TokenCache.get_or_refresh(service_account_json)
  end

  defp fetch_access_token(_), do: {:error, :missing_credentials}

  # Get model family from model ID
  defp get_model_family(model_id) do
    # Claude models start with "claude-"
    cond do
      String.starts_with?(model_id, "claude-") -> "claude"
      String.starts_with?(model_id, "gemini-") -> "gemini"
      true -> raise ArgumentError, "Unknown model family for: #{model_id}"
    end
  end

  # Get formatter module for model family
  defp get_formatter_module(model_family) do
    case Map.fetch(@model_families, model_family) do
      {:ok, module} ->
        module

      :error ->
        raise ArgumentError, """
        No formatter implemented for model family: #{model_family}
        Currently supported: #{Map.keys(@model_families) |> Enum.join(", ")}
        """
    end
  end

  # Get formatter module for model ID (combines model_family + formatter lookup)
  defp get_formatter(model_id) do
    model_id
    |> get_model_family()
    |> get_formatter_module()
  end

  # Build the model path for Vertex AI
  defp build_model_path("claude", model_id, project_id, region) do
    # Anthropic models on Vertex use the publishers/anthropic path
    "/v1/projects/#{project_id}/locations/#{region}/publishers/anthropic/models/#{model_id}:rawPredict"
  end

  defp build_model_path("gemini", model_id, project_id, region) do
    # Gemini models on Vertex use the publishers/google path
    "/v1/projects/#{project_id}/locations/#{region}/publishers/google/models/#{model_id}:generateContent"
  end

  # Build base URL based on region
  defp build_base_url(region) do
    if region == "global" do
      @vertex_base_url_global
    else
      String.replace(@vertex_base_url_regional, "{region}", region)
    end
  end

  # Process and validate options (shared between do_prepare_request and attach_stream)
  defp process_and_validate_opts(opts, model, operation) do
    # Extract and validate GCP credentials
    {gcp_creds, other_opts} = extract_gcp_credentials(opts)
    validate_gcp_credentials!(gcp_creds)

    # Extract Req HTTP options before validation (they'll be re-added later)
    {req_opts, other_opts} =
      Keyword.split(other_opts, [:json, :retry, :max_retries, :retry_log_level])

    # Process options (validates, normalizes, and calls translate_options)
    other_opts =
      case ReqLLM.Provider.Options.process(__MODULE__, operation, model, other_opts) do
        {:ok, processed_opts} -> processed_opts
        {:error, error} -> raise error
      end

    # Merge Req options back
    other_opts = Keyword.merge(other_opts, req_opts)

    # Get model family and formatter
    model_family = get_model_family(model.provider_model_id || model.id)
    formatter = get_formatter_module(model_family)

    # Clean thinking after translation if incompatible
    other_opts =
      if function_exported?(formatter, :maybe_clean_thinking_after_translation, 2) do
        formatter.maybe_clean_thinking_after_translation(other_opts, operation)
      else
        other_opts
      end

    {gcp_creds, other_opts, model_family, formatter}
  end

  # Extract GCP credentials from options
  defp extract_gcp_credentials(opts) do
    gcp_keys = [:service_account_json, :access_token, :project_id, :region]
    {passed_creds, other_opts} = Keyword.split(opts, gcp_keys)

    creds = %{
      service_account_json:
        passed_creds[:service_account_json] ||
          System.get_env("GOOGLE_APPLICATION_CREDENTIALS"),
      project_id: passed_creds[:project_id] || System.get_env("GOOGLE_CLOUD_PROJECT"),
      region: passed_creds[:region] || System.get_env("GOOGLE_CLOUD_REGION") || "global",
      access_token: passed_creds[:access_token]
    }

    {creds, other_opts}
  end

  # Validate GCP credentials
  defp validate_gcp_credentials!(creds) do
    if !creds[:service_account_json] and !creds[:access_token] do
      raise ArgumentError, """
      Google Cloud credentials required for Vertex AI. Please provide either:

      1. Environment variables:
         GOOGLE_APPLICATION_CREDENTIALS=/path/to/service-account.json
         GOOGLE_CLOUD_PROJECT=your-project-id

      2. Service account:
         provider_options: [
           service_account_json: "/path/to/service-account.json",
           project_id: "your-project-id"
         ]

      3. Access token:
         provider_options: [
           access_token: "ya29.ci...",
           project_id: "your-project-id"
         ]
      """
    end

    if !creds[:project_id] do
      raise ArgumentError, """
      Google Cloud project ID required for Vertex AI.
      Set GOOGLE_CLOUD_PROJECT environment variable or pass project_id in provider_options.
      """
    end

    creds
  end

  # Decode response
  def decode_response({request, response}) do
    # Get formatter for this model
    model = Req.Request.get_private(request, :model)
    formatter = get_formatter(model.provider_model_id || model.id)

    # Build opts with operation and context from request.options (which is a map)
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

    # Parse response using formatter
    result = formatter.parse_response(response.body, model, opts)

    case result do
      {:ok, parsed} ->
        {request, %{response | body: parsed}}

      {:error, reason} ->
        raise "Failed to parse Vertex AI response: #{inspect(reason)}"
    end
  end

  @impl ReqLLM.Provider
  def thinking_constraints do
    # Google Vertex AI requires the same constraints as Bedrock for extended thinking
    # temperature=1.0 and max_tokens > thinking.budget_tokens (4000 for :low effort)
    # See: https://docs.claude.com/en/docs/build-with-claude/extended-thinking
    %{required_temperature: 1.0, min_max_tokens: 4001}
  end

  @impl ReqLLM.Provider
  def extract_usage(body, model) do
    formatter = get_formatter(model.provider_model_id || model.id)

    if function_exported?(formatter, :extract_usage, 2) do
      formatter.extract_usage(body, model)
    else
      {:error, :no_usage_extractor}
    end
  end

  def pre_validate_options(operation, model, opts) do
    # Delegate to model-specific formatter if it has pre_validate_options
    formatter = get_formatter(model.provider_model_id || model.id)

    if function_exported?(formatter, :pre_validate_options, 3) do
      formatter.pre_validate_options(operation, model, opts)
    else
      {opts, []}
    end
  end

  @impl ReqLLM.Provider
  def translate_options(operation, model, opts) do
    # Delegate to native Anthropic option translation for Anthropic models
    # This ensures we get all Anthropic-specific handling (temperature/top_p conflicts, etc.)
    model_family = get_model_family(model.provider_model_id || model.id)

    case model_family do
      "claude" ->
        # Delegate to Anthropic provider for Anthropic-specific option handling
        ReqLLM.Providers.Anthropic.translate_options(operation, model, opts)

      _ ->
        # Other model families: no translation needed yet
        {opts, []}
    end
  end

  @impl ReqLLM.Provider
  def attach_stream(model, context, opts, _finch_name) do
    # Process and validate options
    operation = opts[:operation] || :chat

    {gcp_creds, other_opts, model_family, formatter} =
      process_and_validate_opts(opts, model, operation)

    # Build request body using formatter (with stream: true)
    body =
      formatter.format_request(
        model.provider_model_id || model.id,
        context,
        Keyword.put(other_opts, :stream, true)
      )

    # Build Vertex AI endpoint URL for streaming
    region = gcp_creds[:region] || @default_region
    project_id = gcp_creds[:project_id]

    # Use streamRawPredict for streaming
    path =
      build_stream_path(model_family, model.provider_model_id || model.id, project_id, region)

    base_url = build_base_url(region)
    url = "#{base_url}#{path}"

    case fetch_access_token(gcp_creds) do
      {:ok, access_token} ->
        headers = [
          {"Authorization", "Bearer #{access_token}"},
          {"Content-Type", "application/json"},
          {"Accept", "text/event-stream"}
        ]

        finch_request = Finch.build(:post, url, headers, Jason.encode!(body))
        {:ok, finch_request}

      {:error, reason} ->
        {:error,
         ReqLLM.Error.API.Request.exception(
           reason: "Failed to get GCP access token: #{inspect(reason)}"
         )}
    end
  rescue
    error ->
      {:error,
       ReqLLM.Error.API.Request.exception(
         reason: "Failed to build Vertex stream request: #{inspect(error)}"
       )}
  end

  @impl ReqLLM.Provider
  def decode_stream_event(event, model) do
    # Get formatter for this model
    formatter = get_formatter(model.provider_model_id || model.id)

    # Delegate SSE parsing to formatter
    # For Anthropic models, Vertex uses standard Anthropic SSE format
    if function_exported?(formatter, :decode_stream_event, 2) do
      formatter.decode_stream_event(event, model)
    else
      # Fall back to Anthropic's stream decoder for models using that format
      ReqLLM.Providers.Anthropic.Response.decode_stream_event(event, model)
    end
  end

  # Build streaming path for model
  defp build_stream_path("claude", model_id, project_id, region) do
    # Use streamRawPredict for streaming
    "/v1/projects/#{project_id}/locations/#{region}/publishers/anthropic/models/#{model_id}:streamRawPredict"
  end

  defp build_stream_path("gemini", model_id, project_id, region) do
    # Use streamGenerateContent for Gemini streaming
    "/v1/projects/#{project_id}/locations/#{region}/publishers/google/models/#{model_id}:streamGenerateContent"
  end

  @impl ReqLLM.Provider
  def credential_missing?(%ArgumentError{message: msg}) when is_binary(msg) do
    String.contains?(msg, "Google Cloud credentials required")
  end

  def credential_missing?(_), do: false
end
