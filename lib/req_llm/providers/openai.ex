defmodule ReqLLM.Providers.OpenAI do
  @moduledoc """
  OpenAI provider implementation using the Provider behavior.

  Supports OpenAI's Chat Completions API and Embeddings API with features including:
  - Text generation with GPT models
  - Streaming responses
  - Tool calling
  - Multi-modal inputs (text and images)
  - Embeddings generation
  - O1/O3 model support with automatic parameter translation

  ## Protocol Usage

  Uses the generic `ReqLLM.Context.Codec` and `ReqLLM.Response.Codec` protocols.
  No custom wrapper modules – leverages the standard OpenAI-compatible codecs.

  ## Configuration

  Set your OpenAI API key via environment variable or JidoKeys:

      # Option 1: Environment variable (automatically loaded)
      OPENAI_API_KEY=sk-...

      # Option 2: Set directly in JidoKeys
      ReqLLM.put_key(:openai_api_key, "sk-...")

  ## Examples

      # Simple text generation
      model = ReqLLM.Model.from("openai:gpt-4")
      {:ok, response} = ReqLLM.generate_text(model, "Hello!")

      # Streaming
      {:ok, stream} = ReqLLM.stream_text(model, "Tell me a story", stream: true)

      # Tool calling
      tools = [%ReqLLM.Tool{name: "get_weather", ...}]
      {:ok, response} = ReqLLM.generate_text(model, "What's the weather?", tools: tools)

      # Embeddings
      {:ok, embedding} = ReqLLM.generate_embedding("openai:text-embedding-3-small", "Hello world")
  """

  @behaviour ReqLLM.Provider

  use ReqLLM.Provider.DSL,
    id: :openai,
    base_url: "https://api.openai.com/v1",
    metadata: "priv/models_dev/openai.json",
    default_env_key: "OPENAI_API_KEY",
    provider_schema: [
      dimensions: [
        type: :pos_integer,
        doc: "Dimensions for embedding models (e.g., text-embedding-3-small supports 512-1536)"
      ],
      encoding_format: [type: :string, doc: "Format for embedding output (float, base64)"]
    ]

  import ReqLLM.Provider.Utils,
    only: [maybe_put: 3, ensure_parsed_body: 1]

  require Logger

  @doc """
  Attaches the OpenAI plugin to a Req request.

  ## Parameters

    * `request` - The Req request to attach to
    * `model_input` - The model (ReqLLM.Model struct, string, or tuple) that triggers this provider
    * `opts` - Options keyword list (validated against comprehensive schema)

  ## Request Options

    * `:temperature` - Controls randomness (0.0-2.0). Defaults to 0.7
    * `:max_tokens` - Maximum tokens to generate. Defaults to 1024
    * `:stream?` - Enable streaming responses. Defaults to false (alias for :stream)
    * `:stream` - Enable streaming responses. Defaults to false
    * `:base_url` - Override base URL. Defaults to provider default
    * `:messages` - Chat messages to send
    * `:system` - System message
    * All options from ReqLLM.Provider.Options schemas are supported

  """
  @spec prepare_request(
          atom(),
          ReqLLM.Model.t() | String.t() | {atom(), keyword()},
          String.t() | list(),
          keyword()
        ) :: {:ok, Req.Request.t()} | {:error, term()}
  @impl ReqLLM.Provider
  def prepare_request(:chat, model_spec, prompt, opts) do
    with {:ok, model} <- ReqLLM.Model.from(model_spec),
         {:ok, context} <- ReqLLM.Context.normalize(prompt, opts),
         opts_with_context = Keyword.put(opts, :context, context),
         {:ok, processed_opts} <-
           ReqLLM.Provider.Options.process(__MODULE__, :chat, model, opts_with_context) do
      http_opts = Keyword.get(processed_opts, :req_http_options, [])

      req_keys =
        __MODULE__.supported_provider_options() ++
          [:context, :operation, :text, :stream, :model, :provider_options]

      request =
        Req.new(
          [
            url: "/chat/completions",
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

    opts_with_tool =
      opts
      |> Keyword.update(:tools, [structured_output_tool], &[structured_output_tool | &1])
      |> Keyword.put(:tool_choice, %{type: "function", function: %{name: "structured_output"}})
      |> Keyword.put_new(:max_tokens, 4096)
      |> Keyword.put(:operation, :object)

    prepare_request(:chat, model_spec, prompt, opts_with_tool)
  end

  def prepare_request(:embedding, model_spec, text, opts) do
    with {:ok, model} <- ReqLLM.Model.from(model_spec),
         opts_with_text = Keyword.merge(opts, text: text, operation: :embedding),
         {:ok, processed_opts} <-
           ReqLLM.Provider.Options.process(__MODULE__, :embedding, model, opts_with_text) do
      http_opts = Keyword.get(processed_opts, :req_http_options, [])

      req_keys =
        __MODULE__.supported_provider_options() ++
          [:context, :operation, :text, :stream, :model, :provider_options]

      request =
        Req.new(
          [
            url: "/embeddings",
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

  def prepare_request(operation, _model, _input, _opts) do
    {:error,
     ReqLLM.Error.Invalid.Parameter.exception(
       parameter:
         "operation: #{inspect(operation)} not supported by OpenAI provider. Supported operations: [:chat, :object, :embedding]"
     )}
  end

  @doc """
  Attaches OpenAI-specific pipeline steps to a Req request.

  This method focuses purely on:
  - Authentication (API key header)
  - Pipeline step attachment (encoding, decoding, streaming, etc.)

  Option registration and merging is handled by `prepare_request` methods.
  """
  @spec attach(Req.Request.t(), ReqLLM.Model.t() | String.t() | {atom(), keyword()}, keyword()) ::
          Req.Request.t()
  @impl ReqLLM.Provider
  def attach(%Req.Request{} = request, model_input, user_opts \\ []) do
    %ReqLLM.Model{} = model = ReqLLM.Model.from!(model_input)

    if model.provider != provider_id() do
      raise ReqLLM.Error.Invalid.Provider.exception(provider: model.provider)
    end

    api_key = ReqLLM.Keys.get!(model, user_opts)

    request
    |> Req.Request.put_header("authorization", "Bearer #{api_key}")
    |> ReqLLM.Step.Error.attach()
    |> Req.Request.append_request_steps(llm_encode_body: &__MODULE__.encode_body/1)
    |> ReqLLM.Step.Stream.maybe_attach_real_time(user_opts[:stream], model)
    |> Req.Request.append_response_steps(llm_decode_response: &__MODULE__.decode_response/1)
    |> ReqLLM.Step.Usage.attach(model)
    |> ReqLLM.Step.LLMFixture.maybe_attach(model, user_opts)
  end

  @doc """
  Extracts usage from the provider response body
  """
  @spec extract_usage(map(), ReqLLM.Model.t()) :: {:ok, map()} | {:error, term()}
  @impl ReqLLM.Provider
  def extract_usage(body, _model) when is_map(body) do
    case body do
      %{"usage" => usage} -> {:ok, usage}
      _ -> {:error, :no_usage_found}
    end
  end

  def extract_usage(_, _), do: {:error, :invalid_body}

  @doc """
  Translates provider-specific options for different model types.

  ## O1/O3 Models

  These models have special parameter requirements:
  - `max_tokens` must be renamed to `max_completion_tokens`
  - `temperature` is not supported and will be dropped

  ## Returns

  `{translated_opts, warnings}` where warnings is a list of transformation messages.
  """
  @impl ReqLLM.Provider
  def translate_options(:chat, %ReqLLM.Model{model: <<"o1", _::binary>>}, opts) do
    {opts_after_rename, rename_warnings} =
      translate_rename(opts, :max_tokens, :max_completion_tokens)

    {final_opts, drop_warnings} =
      translate_drop(
        opts_after_rename,
        :temperature,
        "OpenAI o1 models do not support :temperature – dropped"
      )

    {final_opts, rename_warnings ++ drop_warnings}
  end

  def translate_options(:chat, %ReqLLM.Model{model: <<"o3", _::binary>>}, opts) do
    {opts_after_rename, rename_warnings} =
      translate_rename(opts, :max_tokens, :max_completion_tokens)

    {final_opts, drop_warnings} =
      translate_drop(
        opts_after_rename,
        :temperature,
        "OpenAI o3 models do not support :temperature – dropped"
      )

    {final_opts, rename_warnings ++ drop_warnings}
  end

  def translate_options(_operation, _model, opts) do
    {opts, []}
  end

  @doc """
  Encodes the request body based on operation type.

  Handles different request formats for different operations:
  - `:embedding` - Uses embedding-specific body format
  - Other operations - Uses chat completion body format

  The body is JSON-encoded and the appropriate content-type header is set.
  """
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
          ReqLLM.Context.Codec.encode_request(ctx, model)

        _ ->
          %{messages: request.options[:messages] || []}
      end

    model_name = request.options[:model]

    body =
      %{model: model_name}
      |> Map.merge(context_data)
      |> add_basic_options(request.options)
      |> maybe_put(:stream, request.options[:stream])
      |> add_token_limits(model_name, request.options)

    body =
      case request.options[:tools] do
        tools when is_list(tools) and tools != [] ->
          body = Map.put(body, :tools, Enum.map(tools, &ReqLLM.Tool.to_schema(&1, :openai)))

          case request.options[:tool_choice] do
            nil -> body
            choice -> Map.put(body, :tool_choice, choice)
          end

        _ ->
          body
      end

    case request.options[:response_format] do
      format when is_map(format) -> Map.put(body, :response_format, format)
      _ -> body
    end
  end

  defp encode_embedding_body(request) do
    input = request.options[:text]
    provider_opts = request.options[:provider_options] || []

    %{
      model: request.options[:model],
      input: input
    }
    |> maybe_put(:dimensions, provider_opts[:dimensions])
    |> maybe_put(:encoding_format, provider_opts[:encoding_format])
    |> maybe_put(:user, request.options[:user])
  end

  @doc """
  Decodes OpenAI API responses based on operation type and streaming mode.

  ## Response Handling

  - **Embedding operations**: Returns raw parsed JSON data
  - **Chat operations**: Converts to ReqLLM.Response struct
  - **Streaming**: Creates response with chunk stream
  - **Non-streaming**: Merges context with assistant response

  ## Error Handling

  Non-200 status codes are converted to ReqLLM.Error.API.Response exceptions.
  """
  @impl ReqLLM.Provider
  def decode_response({req, resp}) do
    case resp.status do
      200 ->
        decode_success_response(req, resp)

      status ->
        decode_error_response(req, resp, status)
    end
  end

  defp decode_success_response(req, resp) do
    operation = req.options[:operation]

    case operation do
      :embedding ->
        decode_embedding_response(req, resp)

      _ ->
        decode_chat_response(req, resp, operation)
    end
  end

  defp decode_error_response(req, resp, status) do
    err =
      ReqLLM.Error.API.Response.exception(
        reason: "OpenAI API error",
        status: status,
        response_body: resp.body
      )

    {req, err}
  end

  defp decode_embedding_response(req, resp) do
    body = ensure_parsed_body(resp.body)
    {req, %{resp | body: body}}
  end

  defp decode_chat_response(req, resp, operation) do
    model_name = req.options[:model]
    model = %ReqLLM.Model{provider: :openai, model: model_name}
    is_streaming = req.options[:stream] == true

    if is_streaming do
      decode_streaming_response(req, resp, model_name)
    else
      decode_non_streaming_response(req, resp, model, operation)
    end
  end

  defp decode_streaming_response(req, resp, model_name) do
    # Real-time streaming - use the stream created by Stream step
    real_time_stream = Req.Request.get_private(req, :real_time_stream, [])

    # Start HTTP request in background task
    http_task =
      Task.async(fn ->
        into_callback = Req.Request.get_private(req, :streaming_into_callback)
        Req.request(req, into: into_callback)
      end)

    response = %ReqLLM.Response{
      id: "stream-#{System.unique_integer([:positive])}",
      model: model_name,
      context: req.options[:context] || %ReqLLM.Context{messages: []},
      message: nil,
      stream?: true,
      stream: real_time_stream,
      usage: %{input_tokens: 0, output_tokens: 0, total_tokens: 0},
      finish_reason: nil,
      provider_meta: %{http_task: http_task}
    }

    {req, %{resp | body: response}}
  end

  defp decode_non_streaming_response(req, resp, model, operation) do
    body = ensure_parsed_body(resp.body)
    {:ok, response} = ReqLLM.Response.Codec.decode_response(body, model)

    final_response =
      case operation do
        :object ->
          extract_and_set_object(response)

        _ ->
          response
      end

    merged_response = merge_response_with_context(req, final_response)
    {req, %{resp | body: merged_response}}
  end

  defp extract_and_set_object(response) do
    extracted_object =
      case ReqLLM.Response.tool_calls(response) do
        [] ->
          nil

        tool_calls ->
          case Enum.find(tool_calls, &(&1.name == "structured_output")) do
            nil -> nil
            %{arguments: object} -> object
          end
      end

    %{response | object: extracted_object}
  end

  defp merge_response_with_context(req, response) do
    context = req.options[:context] || %ReqLLM.Context{messages: []}
    ReqLLM.Context.merge_response(context, response)
  end

  @doc false
  defp add_basic_options(body, request_options) do
    body_options = [
      :temperature,
      :top_p,
      :frequency_penalty,
      :presence_penalty,
      :user,
      :seed,
      :stop
    ]

    Enum.reduce(body_options, body, fn key, acc ->
      maybe_put(acc, key, request_options[key])
    end)
  end

  @doc false
  defp add_token_limits(body, model_name, request_options) do
    case model_name do
      <<"o1", _::binary>> ->
        maybe_put(body, :max_completion_tokens, request_options[:max_completion_tokens])

      <<"o3", _::binary>> ->
        maybe_put(body, :max_completion_tokens, request_options[:max_completion_tokens])

      _ ->
        maybe_put(body, :max_tokens, request_options[:max_tokens])
    end
  end
end
