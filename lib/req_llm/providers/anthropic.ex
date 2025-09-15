defmodule ReqLLM.Providers.Anthropic do
  @moduledoc """
  Anthropic provider implementation using the Provider behavior.

  Supports Anthropic's Messages API with features including:
  - Text generation with Claude models
  - Streaming responses
  - Tool calling
  - Multi-modal inputs (text and images)
  - Thinking/reasoning tokens

  ## Configuration

  Set your Anthropic API key via JidoKeys (automatically picks up from .env):

      # Option 1: Set directly in JidoKeys
      ReqLLM.put_key(:anthropic_api_key, "sk-ant-...")
      
      # Option 2: Add to .env file (automatically loaded via JidoKeys+Dotenvy)
      ANTHROPIC_API_KEY=sk-ant-...

  ## Examples

      # Simple text generation
      model = ReqLLM.Model.from("anthropic:claude-3-haiku-20240307")
      {:ok, response} = ReqLLM.generate_text(model, "Hello!")

      # Streaming
      {:ok, stream} = ReqLLM.stream_text(model, "Tell me a story", stream: true)

      # Tool calling
      tools = [%ReqLLM.Tool{name: "get_weather", ...}]
      {:ok, response} = ReqLLM.generate_text(model, "What's the weather?", tools: tools)

  """

  @behaviour ReqLLM.Provider

  use ReqLLM.Provider.DSL,
    id: :anthropic,
    base_url: "https://api.anthropic.com/v1",
    metadata: "priv/models_dev/anthropic.json",
    default_env_key: "ANTHROPIC_API_KEY",
    context_wrapper: ReqLLM.Providers.Anthropic.Context,
    response_wrapper: ReqLLM.Providers.Anthropic.Response,
    provider_schema: []

  import ReqLLM.Provider.Utils,
    only: [prepare_options!: 3, maybe_put: 3, ensure_parsed_body: 1]

  # Anthropic currently shares core options - no provider-specific options yet
  @default_api_version "2023-06-01"

  @doc """
  Attaches the Anthropic plugin to a Req request.

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
    * All options from ReqLLM.Provider.Options schemas are supported

  """
  @impl ReqLLM.Provider
  def prepare_request(:chat, model_input, %ReqLLM.Context{} = context, opts) do
    with {:ok, model} <- ReqLLM.Model.from(model_input) do
      http_opts = Keyword.get(opts, :req_http_options, [])

      request =
        Req.new([url: "/messages", method: :post, receive_timeout: 30_000] ++ http_opts)
        |> attach(model, Keyword.put(opts, :context, context))

      {:ok, request}
    end
  end

  def prepare_request(operation, _model, _input, _opts) do
    {:error,
     ReqLLM.Error.Invalid.Parameter.exception(
       parameter:
         "operation: #{inspect(operation)} not supported by Anthropic provider. Supported operations: [:chat, :object]"
     )}
  end

  def prepare_request(:object, model_input, %ReqLLM.Context{} = context, compiled_schema, opts) do
    # For object generation, we need to add the structured output tool
    # Extract the original schema from the compiled NimbleOptions
    _json_schema = ReqLLM.Schema.to_json(compiled_schema.schema)

    # Create the structured_output tool
    structured_output_tool =
      ReqLLM.Tool.new!(
        name: "structured_output",
        description: "Generate structured output matching the provided schema",
        parameter_schema: compiled_schema.schema,
        callback: fn _args -> {:ok, "structured output generated"} end
      )

    # Add the tool to the options
    opts_with_tool =
      Keyword.update(opts, :tools, [structured_output_tool], fn tools ->
        [structured_output_tool | tools]
      end)

    # Force the model to use our structured output tool by setting tool_choice
    opts_with_choice =
      Keyword.put(opts_with_tool, :tool_choice, %{
        type: "tool",
        name: "structured_output"
      })

    # Ensure max_tokens is set for tool calling
    opts_with_max_tokens =
      case Keyword.get(opts_with_choice, :max_tokens) do
        nil -> Keyword.put(opts_with_choice, :max_tokens, 4096)
        _value -> opts_with_choice
      end

    # Use the regular chat preparation with our modified options
    prepare_request(:chat, model_input, context, opts_with_max_tokens)
  end

  @spec attach(Req.Request.t(), ReqLLM.Model.t() | String.t() | {atom(), keyword()}, keyword()) ::
          Req.Request.t()
  @impl ReqLLM.Provider
  def attach(%Req.Request{} = request, model_input, user_opts \\ []) do
    %ReqLLM.Model{} = model = ReqLLM.Model.from!(model_input)

    if model.provider != provider_id() do
      raise ReqLLM.Error.Invalid.Provider.exception(provider: model.provider)
    end

    if !ReqLLM.Provider.Registry.model_exists?("#{provider_id()}:#{model.model}") do
      raise ReqLLM.Error.Invalid.Parameter.exception(parameter: "model: #{model.model}")
    end

    api_key = ReqLLM.Keys.get!(model, user_opts)

    # Extract tools separately to avoid validation issues
    {tools, other_opts} = Keyword.pop(user_opts, :tools, [])

    # Prepare validated options and extract what Req needs
    opts = prepare_options!(__MODULE__, model, other_opts)

    # Add tools back after validation
    opts = Keyword.put(opts, :tools, tools)
    base_url = Keyword.get(user_opts, :base_url, default_base_url())
    req_keys = __MODULE__.supported_provider_options() ++ [:model, :context]

    request
    |> Req.Request.register_options(req_keys)
    |> Req.Request.merge_options(Keyword.take(opts, req_keys) ++ [base_url: base_url])
    |> Req.Request.put_header("x-api-key", api_key)
    |> Req.Request.put_header("anthropic-version", opts[:api_version] || @default_api_version)
    |> ReqLLM.Step.Error.attach()
    |> Req.Request.append_request_steps(llm_encode_body: &__MODULE__.encode_body/1)
    |> ReqLLM.Step.Stream.maybe_attach(opts[:stream])
    |> Req.Request.append_response_steps(llm_decode_response: &__MODULE__.decode_response/1)
    |> ReqLLM.Step.Usage.attach(model)
  end

  @impl ReqLLM.Provider
  def extract_usage(body, _model) when is_map(body) do
    case body do
      %{"usage" => usage} -> {:ok, usage}
      _ -> {:error, :no_usage_found}
    end
  end

  def extract_usage(_, _), do: {:error, :invalid_body}

  # Helper functions for beta feature support
  defp maybe_set_beta_header(request) do
    beta_flags = encode_beta_flags(request.options)

    if beta_flags == [] do
      request
    else
      beta_header = Enum.join(beta_flags, ",")
      Req.Request.put_header(request, "anthropic-beta", beta_header)
    end
  end

  defp encode_beta_flags(opts) do
    Enum.flat_map(opts, fn
      {:thinking, true} -> ["thinking-2024-12-19"]
      _ -> []
    end)
  end

  # Parameter validation helpers
  defp validate_parameter_ranges(opts) do
    with :ok <- validate_temperature(opts[:temperature]),
         :ok <- validate_top_p(opts[:top_p]),
         :ok <- validate_top_k(opts[:top_k]),
         :ok <- validate_max_tokens(opts[:max_tokens]) do
      validate_stop_sequences(opts[:stop_sequences])
    end
  end

  defp validate_temperature(nil), do: :ok
  defp validate_temperature(temp) when is_number(temp) and temp >= 0.0 and temp <= 1.0, do: :ok

  defp validate_temperature(temp),
    do: {:error, "temperature must be between 0.0 and 1.0, got #{temp}"}

  defp validate_top_p(nil), do: :ok
  defp validate_top_p(top_p) when is_number(top_p) and top_p >= 0.0 and top_p <= 1.0, do: :ok
  defp validate_top_p(top_p), do: {:error, "top_p must be between 0.0 and 1.0, got #{top_p}"}

  defp validate_top_k(nil), do: :ok
  defp validate_top_k(top_k) when is_integer(top_k) and top_k >= 1 and top_k <= 500, do: :ok
  defp validate_top_k(top_k), do: {:error, "top_k must be between 1 and 500, got #{top_k}"}

  defp validate_max_tokens(nil), do: :ok

  defp validate_max_tokens(max_tokens)
       when is_integer(max_tokens) and max_tokens >= 1 and max_tokens <= 4096,
       do: :ok

  defp validate_max_tokens(max_tokens),
    do: {:error, "max_tokens must be between 1 and 4096, got #{max_tokens}"}

  defp validate_stop_sequences(nil), do: :ok
  defp validate_stop_sequences([]), do: :ok

  defp validate_stop_sequences(sequences) when is_list(sequences) and length(sequences) <= 4,
    do: :ok

  defp validate_stop_sequences(sequences),
    do:
      {:error,
       "stop_sequences must be a list of at most 4 strings, got #{length(sequences)} items"}

  # Special handling for thinking parameter - only include when true
  defp maybe_put_thinking(body, true), do: Map.put(body, :thinking, true)
  defp maybe_put_thinking(body, _), do: body

  # Req pipeline steps
  @impl ReqLLM.Provider
  def encode_body(request) do
    # Validate parameter ranges before proceeding
    case validate_parameter_ranges(request.options) do
      :ok ->
        nil

      {:error, reason} ->
        raise ReqLLM.Error.Invalid.Parameter.exception(parameter: reason)
    end

    context_data =
      case request.options[:context] do
        %ReqLLM.Context{} = ctx ->
          ctx
          |> wrap_context()
          |> ReqLLM.Context.Codec.encode_request()

        _ ->
          %{messages: request.options[:messages] || []}
      end

    tools_data =
      case request.options[:tools] do
        tools when is_list(tools) and (is_list(tools) and tools != []) ->
          %{tools: Enum.map(tools, &ReqLLM.Tool.to_schema(&1, :anthropic))}

        _ ->
          %{}
      end

    body =
      %{
        model: request.options[:model] || request.options[:id],
        stream: request.options[:stream]
      }
      |> Map.merge(context_data)
      |> Map.merge(tools_data)
      |> maybe_put(:temperature, request.options[:temperature])
      |> maybe_put(:max_tokens, request.options[:max_tokens])
      |> maybe_put(:system, request.options[:system])
      |> maybe_put(:top_p, request.options[:top_p])
      |> maybe_put(:top_k, request.options[:top_k])
      |> maybe_put(:stop_sequences, request.options[:stop_sequences])
      |> maybe_put(:response_format, request.options[:response_format])
      |> maybe_put_thinking(request.options[:thinking])

    try do
      encoded_body = Jason.encode!(body)

      request
      |> Req.Request.put_header("content-type", "application/json")
      |> Map.put(:body, encoded_body)
      |> maybe_set_beta_header()
    rescue
      error ->
        reraise error, __STACKTRACE__
    end
  end

  @impl ReqLLM.Provider
  def decode_response({req, resp}) do
    case resp.status do
      200 ->
        body = ensure_parsed_body(resp.body)
        # Return raw parsed data directly - no wrapping needed
        {req, %{resp | body: body}}

      status ->
        err =
          ReqLLM.Error.API.Response.exception(
            reason: "Anthropic API error",
            status: status,
            response_body: resp.body
          )

        {req, err}
    end
  end
end
