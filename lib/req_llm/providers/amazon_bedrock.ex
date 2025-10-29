defmodule ReqLLM.Providers.AmazonBedrock do
  @moduledoc """
  AWS Bedrock provider implementation using the Provider behavior.

  Supports AWS Bedrock's unified API for accessing multiple AI models including:
  - Anthropic Claude models (fully implemented)
  - Meta Llama models (extensible)
  - Amazon Nova models (extensible)
  - Cohere models (extensible)
  - And more as AWS adds them

  ## Authentication

  Bedrock uses AWS Signature V4 authentication. Configure credentials via:

      # Option 1: Environment variables (recommended)
      export AWS_ACCESS_KEY_ID=AKIA...
      export AWS_SECRET_ACCESS_KEY=...
      export AWS_REGION=us-east-1

      # Option 2: Pass directly in options
      model = ReqLLM.Model.from("bedrock:anthropic.claude-3-sonnet-20240229-v1:0",
        region: "us-east-1",
        access_key_id: "AKIA...",
        secret_access_key: "..."
      )

      # Option 3: Use ReqLLM.Keys (with composite key)
      ReqLLM.put_key(:aws_bedrock, %{
        access_key_id: "AKIA...",
        secret_access_key: "...",
        region: "us-east-1"
      })

  ## Examples

      # Simple text generation with Claude on Bedrock
      model = ReqLLM.Model.from("bedrock:anthropic.claude-3-sonnet-20240229-v1:0")
      {:ok, response} = ReqLLM.generate_text(model, "Hello!")

      # Streaming
      {:ok, response} = ReqLLM.stream_text(model, "Tell me a story")
      response
      |> ReqLLM.StreamResponse.tokens()
      |> Stream.each(&IO.write/1)
      |> Stream.run()

      # Tool calling (for models that support it)
      tools = [%ReqLLM.Tool{name: "get_weather", ...}]
      {:ok, response} = ReqLLM.generate_text(model, "What's the weather?", tools: tools)

  ## Extending for New Models

  To add support for a new model family:

  1. Add the model family to `@model_families`
  2. Implement format functions in the corresponding module (e.g., `ReqLLM.Providers.Bedrock.Meta`)
  3. The functions needed are:
     - `format_request/3` - Convert ReqLLM context to provider format
     - `parse_response/2` - Convert provider response to ReqLLM format
     - `parse_stream_chunk/2` - Handle streaming responses
  """

  @behaviour ReqLLM.Provider

  use ReqLLM.Provider.DSL,
    id: :amazon_bedrock,
    base_url: "https://bedrock-runtime.{region}.amazonaws.com",
    metadata: "priv/models_dev/amazon_bedrock.json",
    default_env_key: "AWS_ACCESS_KEY_ID",
    provider_schema: [
      region: [
        type: :string,
        default: "us-east-1",
        doc: "AWS region where Bedrock is available"
      ],
      access_key_id: [
        type: :string,
        doc: "AWS Access Key ID (can also use AWS_ACCESS_KEY_ID env var)"
      ],
      secret_access_key: [
        type: :string,
        doc: "AWS Secret Access Key (can also use AWS_SECRET_ACCESS_KEY env var)"
      ],
      session_token: [
        type: :string,
        doc: "AWS Session Token for temporary credentials"
      ],
      use_converse: [
        type: :boolean,
        doc: "Force use of Bedrock Converse API (default: auto-detect based on tools presence)"
      ],
      additional_model_request_fields: [
        type: :map,
        doc:
          "Additional model-specific request fields (e.g., reasoning_config for Claude extended thinking)"
      ],
      anthropic_prompt_cache: [
        type: :boolean,
        doc: "Enable Anthropic prompt caching for Claude models on Bedrock"
      ],
      anthropic_prompt_cache_ttl: [
        type: :string,
        doc: "TTL for cache (\"1h\" for one hour; omit for default ~5m)"
      ]
    ]

  import ReqLLM.Provider.Utils,
    only: [ensure_parsed_body: 1]

  alias ReqLLM.Error
  alias ReqLLM.Error.Invalid.Parameter, as: InvalidParameter
  alias ReqLLM.Providers.AmazonBedrock.AWSEventStream
  alias ReqLLM.Step

  @dialyzer :no_match
  # Base URL will be constructed with region
  @model_families %{
    "anthropic" => ReqLLM.Providers.AmazonBedrock.Anthropic,
    "openai" => ReqLLM.Providers.AmazonBedrock.OpenAI,
    "meta" => ReqLLM.Providers.AmazonBedrock.Meta
  }

  def default_base_url do
    # Override to handle region template
    "https://bedrock-runtime.{region}.amazonaws.com"
  end

  @impl ReqLLM.Provider
  def prepare_request(:chat, model_input, input, opts) do
    with {:ok, model} <- ReqLLM.Model.from(model_input),
         {:ok, context} <- ReqLLM.Context.normalize(input, opts) do
      http_opts = Keyword.get(opts, :req_http_options, [])

      # Bedrock endpoints vary by streaming
      endpoint = if opts[:stream], do: "/invoke-with-response-stream", else: "/invoke"

      request =
        Req.new([url: endpoint, method: :post, receive_timeout: 60_000] ++ http_opts)
        |> attach(model, Keyword.put(opts, :context, context))

      {:ok, request}
    end
  end

  @impl ReqLLM.Provider
  def prepare_request(:object, model_input, input, opts) do
    # Structured output is implemented via tool calling for Claude models
    # We leverage the existing Anthropic tool-based approach
    with {:ok, model} <- ReqLLM.Model.from(model_input),
         {:ok, context} <- ReqLLM.Context.normalize(input, opts) do
      http_opts = Keyword.get(opts, :req_http_options, [])

      # Bedrock endpoints vary by streaming
      endpoint = if opts[:stream], do: "/invoke-with-response-stream", else: "/invoke"

      # Mark operation as :object so the formatter can handle it appropriately
      opts_with_operation = Keyword.put(opts, :operation, :object)

      request =
        Req.new([url: endpoint, method: :post, receive_timeout: 60_000] ++ http_opts)
        |> attach(model, Keyword.put(opts_with_operation, :context, context))

      {:ok, request}
    end
  end

  def prepare_request(operation, _model, _input, _opts) do
    {:error,
     InvalidParameter.exception(
       parameter:
         "operation: #{inspect(operation)} not supported by Bedrock provider. Supported operations: [:chat, :object]"
     )}
  end

  @impl ReqLLM.Provider
  def attach(%Req.Request{} = request, model_input, user_opts) do
    %ReqLLM.Model{} = model = ReqLLM.Model.from!(model_input)

    if model.provider != provider_id() do
      raise Error.Invalid.Provider.exception(provider: model.provider)
    end

    # Get AWS credentials
    {aws_creds, other_opts} = extract_aws_credentials(user_opts)

    # Validate we have necessary AWS credentials
    validate_aws_credentials!(aws_creds)

    # Process options (validates, normalizes, and calls pre_validate_options)
    operation = other_opts[:operation] || :chat

    opts =
      case ReqLLM.Provider.Options.process(__MODULE__, operation, model, other_opts) do
        {:ok, processed_opts} -> processed_opts
        {:error, error} -> raise error
      end

    # For Anthropic models: Remove thinking from additional_model_request_fields if it was removed by translate_options
    # This handles the case where thinking is incompatible with forced tool_choice
    opts = maybe_clean_thinking_after_translation(opts, get_model_family(model.model), operation)

    # Construct the base URL with region
    region = aws_creds.region || "us-east-1"
    base_url = "https://bedrock-runtime.#{region}.amazonaws.com"

    model_id = model.model

    # Check if we should use Converse API
    # Priority: explicit use_converse option > prompt caching optimization > auto-detect from tools presence
    use_converse = determine_use_converse(opts)

    {endpoint_base, formatter, model_family} =
      if use_converse do
        # Use Converse API for unified tool calling
        endpoint =
          if opts[:stream],
            do: "/model/#{model_id}/converse-stream",
            else: "/model/#{model_id}/converse"

        {endpoint, ReqLLM.Providers.AmazonBedrock.Converse, :converse}
      else
        # Use native model-specific endpoint
        endpoint =
          if opts[:stream],
            do: "/model/#{model_id}/invoke-with-response-stream",
            else: "/model/#{model_id}/invoke"

        family = get_model_family(model_id)
        {endpoint, get_formatter_module(family), family}
      end

    updated_request =
      request
      |> Map.put(:url, URI.parse(base_url <> endpoint_base))
      |> Req.Request.register_options([
        :model,
        :context,
        :model_family,
        :use_converse,
        :operation
      ])
      |> Req.Request.merge_options(
        base_url: base_url,
        model: model_id,
        model_family: model_family,
        context: opts[:context],
        use_converse: use_converse,
        operation: opts[:operation]
      )

    model_body =
      formatter.format_request(
        model_id,
        opts[:context],
        opts
      )

    request_with_body =
      updated_request
      |> Req.Request.put_header("content-type", "application/json")
      |> Map.put(:body, Jason.encode!(model_body))

    request_with_body
    |> Step.Error.attach()
    |> ReqLLM.Step.Retry.attach()
    |> put_aws_sigv4(aws_creds)
    # No longer attach streaming here - it's handled by attach_stream
    |> Req.Request.append_response_steps(bedrock_decode_response: &decode_response/1)
    |> Step.Usage.attach(model)
  end

  @impl ReqLLM.Provider
  def attach_stream(model, context, opts, _finch_name) do
    # Get AWS credentials
    {aws_creds, other_opts} = extract_aws_credentials(opts)

    # Validate we have necessary AWS credentials
    validate_aws_credentials!(aws_creds)

    # Apply pre-validation (reasoning params, etc.) - streaming bypasses Options.process
    {pre_validated_opts, _warnings} = pre_validate_options(:chat, model, other_opts)

    # Apply option translation (temperature/top_p conflicts, etc.)
    # This is critical for streaming requests which bypass the normal Options.process pipeline
    {translated_opts, _warnings} = translate_options(:chat, model, pre_validated_opts)

    # Check if we should use Converse API
    # Priority: explicit use_converse option > prompt caching optimization > auto-detect from tools presence
    use_converse = determine_use_converse(translated_opts)

    # Get model-specific or Converse formatter
    model_id = model.model

    {formatter, path} =
      if use_converse do
        {ReqLLM.Providers.AmazonBedrock.Converse, "/model/#{model_id}/converse-stream"}
      else
        model_family = get_model_family(model_id)
        formatter = get_formatter_module(model_family)
        {formatter, "/model/#{model_id}/invoke-with-response-stream"}
      end

    # Build request body with translated options
    body = formatter.format_request(model_id, context, translated_opts)
    json_body = Jason.encode!(body)

    # Ensure json_body is binary
    if !is_binary(json_body) do
      raise ArgumentError, "JSON body must be binary, got: #{inspect(json_body)}"
    end

    # Construct streaming URL
    region = aws_creds.region || "us-east-1"
    host = "bedrock-runtime.#{region}.amazonaws.com"
    url = "https://#{host}#{path}"

    # Create base headers for AWS signature
    headers = [
      {"Content-Type", "application/json"},
      {"Accept", "application/vnd.amazon.eventstream"},
      {"Host", host}
    ]

    # Build Finch request (without signature yet)
    finch_request = Finch.build(:post, url, headers, json_body)

    # Add AWS Signature V4
    signed_request = sign_aws_request(finch_request, aws_creds, region, "bedrock")

    {:ok, signed_request}
  rescue
    error ->
      require Logger

      Logger.error(
        "Error in attach_stream: #{Exception.message(error)}\nStacktrace: #{Exception.format_stacktrace(__STACKTRACE__)}"
      )

      {:error, {:bedrock_stream_build_failed, error}}
  end

  @impl ReqLLM.Provider
  def parse_stream_protocol(chunk, buffer) do
    # Bedrock uses AWS Event Stream protocol
    data = buffer <> chunk

    case AWSEventStream.parse_binary(data) do
      {:ok, events, rest} ->
        # Return parsed events and remaining buffer
        {:ok, events, rest}

      {:incomplete, incomplete_data} ->
        # Need more data
        {:incomplete, incomplete_data}

      {:error, reason} ->
        require Logger

        Logger.error("Bedrock parse error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl ReqLLM.Provider
  def decode_sse_event(event, model) when is_map(event) do
    # Decode AWS event stream events into StreamChunks
    # This is called after parse_stream_protocol returns events
    model_family = get_model_family(model.model)
    formatter = get_formatter_module(model_family)

    case formatter.parse_stream_chunk(event, %{}) do
      {:ok, nil} -> []
      {:ok, chunk} -> [chunk]
      {:error, _} -> []
    end
  end

  def decode_sse_event(_data, _model) do
    []
  end

  # Note: pre_validate_options is not yet a formal Provider callback
  # It's called by Options.process/4 if the provider exports it
  def pre_validate_options(_operation, model, opts) do
    # Handle reasoning parameters for Claude models on Bedrock
    opts = maybe_translate_reasoning_params(model, opts)
    {opts, []}
  end

  # Translate reasoning_effort/reasoning_token_budget to Bedrock additionalModelRequestFields
  # Only for Claude models that support extended thinking
  defp maybe_translate_reasoning_params(model, opts) do
    model_id = model.model

    # Check if this is a Claude model with reasoning capability
    # Use model.capabilities.reasoning instead of hardcoding model IDs
    is_claude = String.contains?(model_id, "anthropic.claude")
    has_reasoning = get_in(model, [Access.key(:capabilities), Access.key(:reasoning)]) == true

    if is_claude and has_reasoning do
      {reasoning_effort, opts} = Keyword.pop(opts, :reasoning_effort)
      {reasoning_budget, opts} = Keyword.pop(opts, :reasoning_token_budget)

      cond do
        reasoning_budget && is_integer(reasoning_budget) ->
          # Explicit budget_tokens provided
          add_reasoning_to_additional_fields(opts, reasoning_budget)

        reasoning_effort ->
          # Map effort to budget
          budget = map_reasoning_effort_to_budget(reasoning_effort)
          add_reasoning_to_additional_fields(opts, budget)

        true ->
          opts
      end
    else
      # Not a Claude reasoning model, pass through
      opts
    end
  end

  defp add_reasoning_to_additional_fields(opts, budget_tokens) do
    # Get existing additional_model_request_fields from provider_options (if any)
    provider_opts = Keyword.get(opts, :provider_options, [])

    additional_fields =
      Keyword.get(provider_opts, :additional_model_request_fields, %{})
      |> Map.put(:thinking, %{type: "enabled", budget_tokens: budget_tokens})

    # Put it back into provider_options
    updated_provider_opts =
      Keyword.put(provider_opts, :additional_model_request_fields, additional_fields)

    Keyword.put(opts, :provider_options, updated_provider_opts)
  end

  defp map_reasoning_effort_to_budget(:low), do: 4_000
  defp map_reasoning_effort_to_budget(:medium), do: 8_000
  defp map_reasoning_effort_to_budget(:high), do: 16_000
  defp map_reasoning_effort_to_budget("low"), do: 4_000
  defp map_reasoning_effort_to_budget("medium"), do: 8_000
  defp map_reasoning_effort_to_budget("high"), do: 16_000
  defp map_reasoning_effort_to_budget(_), do: 8_000

  @impl ReqLLM.Provider
  def extract_usage(body, model) when is_map(body) do
    # Delegate to model family formatter
    model_family = get_model_family(model.model)
    formatter = get_formatter_module(model_family)

    if function_exported?(formatter, :extract_usage, 2) do
      formatter.extract_usage(body, model)
    else
      {:error, :no_usage_extractor}
    end
  end

  def extract_usage(_, _), do: {:error, :invalid_body}

  def wrap_response(%ReqLLM.Providers.AmazonBedrock.Response{} = already_wrapped) do
    # Don't double-wrap
    already_wrapped
  end

  def wrap_response(data) when is_map(data) do
    %ReqLLM.Providers.AmazonBedrock.Response{payload: data}
  end

  def wrap_response(data), do: data

  # AWS Authentication
  defp extract_aws_credentials(opts) do
    aws_keys = [:access_key_id, :secret_access_key, :session_token, :region]

    # Split AWS credentials from other options
    {passed_creds, other_opts} = Keyword.split(opts, aws_keys)

    # Try to get credentials from environment first, then overlay passed options
    creds =
      case AWSAuth.Credentials.from_env() do
        nil ->
          # No env credentials, use passed credentials directly
          if passed_creds[:access_key_id] && passed_creds[:secret_access_key] do
            AWSAuth.Credentials.from_map(passed_creds)
          end

        %AWSAuth.Credentials{} = env_creds ->
          # Merge passed credentials over environment credentials
          merged =
            env_creds
            |> Map.from_struct()
            |> Map.merge(Map.new(passed_creds))

          struct(AWSAuth.Credentials, merged)
      end

    {creds, other_opts}
  end

  defp validate_aws_credentials!(nil) do
    raise ArgumentError, """
    AWS credentials required for Bedrock. Please provide either:

    1. Environment variables:
       AWS_ACCESS_KEY_ID=...
       AWS_SECRET_ACCESS_KEY=...

    2. Options:
       access_key_id: "...", secret_access_key: "..."
    """
  end

  defp validate_aws_credentials!(%AWSAuth.Credentials{access_key_id: nil}) do
    raise ArgumentError, """
    AWS credentials required for Bedrock. Please provide either:

    1. Environment variables:
       AWS_ACCESS_KEY_ID=...
       AWS_SECRET_ACCESS_KEY=...

    2. Options:
       access_key_id: "...", secret_access_key: "..."
    """
  end

  defp validate_aws_credentials!(%AWSAuth.Credentials{secret_access_key: nil}) do
    raise ArgumentError, """
    AWS credentials required for Bedrock. Please provide either:

    1. Environment variables:
       AWS_ACCESS_KEY_ID=...
       AWS_SECRET_ACCESS_KEY=...

    2. Options:
       access_key_id: "...", secret_access_key: "..."
    """
  end

  defp validate_aws_credentials!(%AWSAuth.Credentials{}), do: :ok

  defp put_aws_sigv4(request, %AWSAuth.Credentials{} = aws_creds) do
    case Code.ensure_loaded(AWSAuth.Req) do
      {:module, _} ->
        :ok

      {:error, _} ->
        raise """
        AWS Bedrock support requires the ex_aws_auth dependency.
        Please add {:ex_aws_auth, "~> 1.3", optional: true} to your mix.exs dependencies.
        """
    end

    # Use the AWSAuth.Req plugin for automatic signing
    AWSAuth.Req.attach(request, credentials: aws_creds, service: "bedrock")
  end

  # Sign a Finch request with AWS Signature V4 using ex_aws_auth library
  defp sign_aws_request(finch_request, %AWSAuth.Credentials{} = aws_creds, _region, service) do
    case Code.ensure_loaded(AWSAuth) do
      {:module, _} ->
        :ok

      {:error, _} ->
        raise """
        AWS Bedrock streaming requires the ex_aws_auth dependency.
        Please add {:ex_aws_auth, "~> 1.3", optional: true} to your mix.exs dependencies.
        """
    end

    # Extract request details
    %Finch.Request{
      method: method,
      path: path,
      headers: headers,
      body: body,
      query: query
    } = finch_request

    # Ensure body is binary (Finch always provides binary or nil)
    body_binary =
      case body do
        nil -> ""
        binary when is_binary(binary) -> binary
      end

    # Build URL
    region = aws_creds.region || "us-east-1"
    url = "https://bedrock-runtime.#{region}.amazonaws.com#{path}"
    url = if query && query != "", do: "#{url}?#{query}", else: url

    # Convert headers to map for signing
    headers_map = Map.new(headers, fn {k, v} -> {String.downcase(k), v} end)

    # Sign using credential-based API - returns list of header tuples
    signed_headers =
      AWSAuth.sign_authorization_header(
        aws_creds,
        String.upcase(to_string(method)),
        url,
        service,
        headers: headers_map,
        payload: body_binary
      )

    # Return signed request
    %{finch_request | headers: signed_headers, body: body_binary}
  end

  defp get_model_family(model_id) do
    normalized_id =
      case String.split(model_id, ".", parts: 2) do
        [possible_region, rest] when possible_region in ["us", "eu", "ap", "ca", "global"] ->
          rest

        _ ->
          model_id
      end

    found_family =
      @model_families
      |> Enum.find_value(fn {prefix, _module} ->
        if String.starts_with?(normalized_id, prefix <> "."), do: prefix
      end)

    found_family ||
      raise ArgumentError, """
      Unsupported model family for: #{model_id}
      Currently supported: #{Map.keys(@model_families) |> Enum.join(", ")}
      """
  end

  @impl ReqLLM.Provider
  def translate_options(operation, model, opts) do
    # Delegate to native Anthropic option translation for Anthropic models
    # This ensures we get all Anthropic-specific handling (temperature/top_p conflicts,
    # reasoning effort, etc.) for free
    model_family = get_model_family(model.model)

    case model_family do
      "anthropic" ->
        # Delegate temperature/top_p translation to Anthropic provider
        ReqLLM.Providers.Anthropic.translate_options(operation, model, opts)

      _ ->
        # Other model families: no translation needed yet
        {opts, []}
    end
  end

  @impl ReqLLM.Provider
  def encode_body(request) do
    request
  end

  @impl ReqLLM.Provider
  def normalize_model_id(model_id) when is_binary(model_id) do
    # Strip region prefix from inference profile IDs for metadata lookup
    # e.g., "us.anthropic.claude-3-sonnet" -> "anthropic.claude-3-sonnet"
    case String.split(model_id, ".", parts: 2) do
      [possible_region, rest] when possible_region in ["us", "eu", "ap", "ca", "global"] ->
        rest

      _ ->
        model_id
    end
  end

  defp get_formatter_module(model_family) do
    case Map.fetch(@model_families, model_family) do
      {:ok, module} ->
        module

      :error ->
        raise ArgumentError, """
        No formatter module found for model family: #{model_family}
        This shouldn't happen - please report this as a bug.
        """
    end
  end

  # Response decoding
  @impl ReqLLM.Provider
  def decode_response({req, %{status: 200} = resp}) do
    # Check if we're using Converse API
    formatter =
      if req.options[:use_converse] do
        ReqLLM.Providers.AmazonBedrock.Converse
      else
        model_family = req.options[:model_family]
        get_formatter_module(model_family)
      end

    parsed_body = ensure_parsed_body(resp.body)

    # Let the formatter handle model-specific parsing
    case formatter.parse_response(parsed_body, req.options) do
      {:ok, formatted_response} ->
        {req, %{resp | body: formatted_response}}

      {:error, reason} ->
        {req,
         Error.API.Response.exception(
           reason: reason,
           status: 200,
           response_body: resp.body
         )}
    end
  end

  def decode_response({req, resp}) do
    err =
      ReqLLM.Error.API.Response.exception(
        reason: "Bedrock API error",
        status: resp.status,
        response_body: resp.body
      )

    {req, err}
  end

  # Remove thinking from additional_model_request_fields after Options.process if needed
  # This is necessary because translate_options can't modify provider_options (they get restored)
  defp maybe_clean_thinking_after_translation(opts, model_family, operation) do
    if model_family == "anthropic" do
      # Check if we have forced tool_choice
      # For :object operation, tool_choice is added later by the formatter, but we know it will be forced
      tool_choice = opts[:tool_choice]
      has_forced_tool = match?(%{type: "tool"}, tool_choice) or operation == :object

      if has_forced_tool do
        # Remove thinking from additional_model_request_fields
        update_in(
          opts,
          [:provider_options, :additional_model_request_fields],
          fn
            nil -> nil
            fields when is_map(fields) -> Map.delete(fields, :thinking)
          end
        )
      else
        opts
      end
    else
      opts
    end
  end

  # Private helper: Determine whether to use Converse API with caching optimization
  defp determine_use_converse(opts) do
    # After Options.process, use_converse is in :provider_options
    case get_in(opts, [:provider_options, :use_converse]) do
      true ->
        true

      false ->
        false

      nil ->
        has_tools = opts[:tools] != nil and opts[:tools] != []
        # After Options.process, anthropic_prompt_cache is in :provider_options
        has_caching = get_in(opts, [:provider_options, :anthropic_prompt_cache]) == true

        cond do
          # If caching is enabled with tools, force native API for full caching support
          has_caching and has_tools ->
            require Logger

            Logger.warning("""
            Bedrock prompt caching enabled with tools present. Auto-switching to native API
            (use_converse: false) for full cache control. Converse API only caches system prompts.
            To silence this warning, explicitly set use_converse: true or use_converse: false.
            """)

            false

          # Default: use Converse for tools, native otherwise
          has_tools ->
            true

          true ->
            false
        end
    end
  end
end
