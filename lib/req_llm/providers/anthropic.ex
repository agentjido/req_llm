defmodule ReqLLM.Providers.Anthropic do
  @moduledoc """
  Provider implementation for Anthropic Claude models.

  Supports Claude 3 models including:
  - claude-3-5-sonnet-20241022
  - claude-3-5-haiku-20241022
  - claude-3-opus-20240229

  ## Key Differences from OpenAI

  - Uses `/v1/messages` endpoint instead of `/chat/completions`
  - Different authentication: `x-api-key` header instead of `Authorization: Bearer`
  - Different message format with content blocks
  - Different response structure with top-level `role` and `content`
  - System messages are included in the messages array, not separate
  - Tool calls use different format with content blocks

  ## Usage

      iex> ReqLLM.generate_text("anthropic:claude-3-5-sonnet-20241022", "Hello!")
      {:ok, response}

  """

  @behaviour ReqLLM.Provider

  use ReqLLM.Provider.DSL,
    id: :anthropic,
    base_url: "https://api.anthropic.com",
    metadata: "priv/models_dev/anthropic.json",
    default_env_key: "ANTHROPIC_API_KEY",
    provider_schema: [
      anthropic_top_k: [
        type: :pos_integer,
        doc: "Sample from the top K options for each subsequent token (1-40)"
      ],
      anthropic_version: [
        type: :string,
        doc: "Anthropic API version to use",
        default: "2023-06-01"
      ],
      stop_sequences: [
        type: {:list, :string},
        doc: "Custom sequences that will cause the model to stop generating"
      ],
      anthropic_metadata: [
        type: :map,
        doc: "Optional metadata to include with the request"
      ]
    ]

  import ReqLLM.Provider.Utils, only: [maybe_put: 3, ensure_parsed_body: 1]

  require Logger

  @impl ReqLLM.Provider
  def prepare_request(operation, model_spec, input, opts) do
    case operation do
      :chat ->
        prepare_chat_request(model_spec, input, opts)

      :object ->
        prepare_object_request(model_spec, input, opts)

      _ ->
        supported_operations = [:chat, :object]

        {:error,
         ReqLLM.Error.Invalid.Parameter.exception(
           parameter:
             "operation: #{inspect(operation)} not supported by #{inspect(__MODULE__)}. Supported operations: #{inspect(supported_operations)}"
         )}
    end
  end

  @impl ReqLLM.Provider
  def attach(request, model, user_opts) do
    # Validate provider compatibility
    if model.provider != :anthropic do
      raise ReqLLM.Error.Invalid.Provider.exception(provider: model.provider)
    end

    api_key = ReqLLM.Keys.get!(model, user_opts)

    # Register options that might be passed by users but aren't standard Req options
    extra_option_keys =
      [:model, :compiled_schema, :temperature, :max_tokens, :app_referer, :app_title, :fixture] ++
        supported_provider_options()

    request
    |> Req.Request.register_options(extra_option_keys ++ [:anthropic_version, :anthropic_beta])
    |> Req.Request.put_header("content-type", "application/json")
    |> Req.Request.put_header("x-api-key", api_key)
    |> Req.Request.put_header("anthropic-version", get_anthropic_version(user_opts))
    |> maybe_add_beta_header(user_opts)
    |> Req.Request.merge_options([model: model.model] ++ user_opts)
    |> ReqLLM.Step.Error.attach()
    |> Req.Request.append_request_steps(llm_encode_body: &encode_body/1)
    |> ReqLLM.Step.Stream.maybe_attach(user_opts[:stream] == true, model)
    |> Req.Request.append_response_steps(llm_decode_response: &decode_response/1)
    |> ReqLLM.Step.Usage.attach(model)
    |> ReqLLM.Step.Fixture.maybe_attach(model, user_opts)
    |> Req.Request.put_private(:req_llm_model, model)
  end

  @impl ReqLLM.Provider
  def encode_body(request) do
    operation = request.options[:operation] || :chat

    body =
      case operation do
        :chat -> encode_chat_body(request)
        # Object uses same chat format with tools
        :object -> encode_chat_body(request)
      end

    json_body = Jason.encode!(body)
    %{request | body: json_body}
  end

  @impl ReqLLM.Provider
  def decode_response({request, response}) do
    case response.status do
      status when status in 200..299 ->
        decode_success_response(request, response)

      status ->
        decode_error_response(request, response, status)
    end
  end

  @impl ReqLLM.Provider
  def extract_usage(body, _model) when is_map(body) do
    case body do
      %{"usage" => usage} -> {:ok, usage}
      _ -> {:error, :no_usage_found}
    end
  end

  def extract_usage(_, _), do: {:error, :invalid_body}

  @impl ReqLLM.Provider
  def translate_options(_operation, _model, opts) do
    # Anthropic-specific parameter translation
    translated_opts =
      opts
      |> translate_stop_parameter()
      |> translate_unsupported_parameters()

    {translated_opts, []}
  end

  # Private implementation functions

  defp prepare_chat_request(model_spec, prompt, opts) do
    with {:ok, model} <- ReqLLM.Model.from(model_spec),
         {:ok, context} <- ReqLLM.Context.normalize(prompt, opts),
         opts_with_context = Keyword.put(opts, :context, context),
         {:ok, processed_opts} <-
           ReqLLM.Provider.Options.process(__MODULE__, :chat, model, opts_with_context) do
      http_opts = Keyword.get(processed_opts, :req_http_options, [])

      req_keys =
        supported_provider_options() ++
          [:context, :operation, :text, :stream, :model, :provider_options]

      request =
        Req.new(
          [
            url: "/v1/messages",
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

  defp prepare_object_request(model_spec, prompt, opts) do
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
      |> Keyword.put(:tool_choice, %{type: "tool", name: "structured_output"})
      |> Keyword.put_new(:max_tokens, 4096)
      |> Keyword.put(:operation, :object)

    prepare_chat_request(model_spec, prompt, opts_with_tool)
  end

  defp get_anthropic_version(user_opts) do
    Keyword.get(user_opts, :anthropic_version, "2023-06-01")
  end

  defp maybe_add_beta_header(request, user_opts) do
    # Add beta header if tools are being used
    if has_tools?(user_opts) do
      Req.Request.put_header(request, "anthropic-beta", "tools-2024-05-16")
    else
      request
    end
  end

  defp has_tools?(user_opts) do
    tools = Keyword.get(user_opts, :tools, [])
    is_list(tools) and tools != []
  end

  defp encode_chat_body(request) do
    context = request.options[:context]
    model_name = request.options[:model]

    # Use Anthropic-specific context encoding
    body_data = ReqLLM.Providers.Anthropic.Context.encode_request(context, %{model: model_name})

    body_data
    |> add_basic_options(request.options)
    |> maybe_put(:stream, request.options[:stream])
    |> maybe_put(:max_tokens, request.options[:max_tokens])
    |> maybe_add_tools(request.options)
  end

  defp add_basic_options(body, request_options) do
    body_options = [
      :temperature,
      :top_p,
      :stop_sequences
    ]

    body =
      Enum.reduce(body_options, body, fn key, acc ->
        maybe_put(acc, key, request_options[key])
      end)

    # Handle Anthropic-specific parameters with proper names
    body
    |> maybe_put(:top_k, request_options[:anthropic_top_k])
    |> maybe_put(:metadata, request_options[:anthropic_metadata])
  end

  defp maybe_add_tools(body, options) do
    tools = get_option(options, :tools, [])

    case tools do
      [] ->
        body

      tools when is_list(tools) ->
        body = Map.put(body, :tools, Enum.map(tools, &tool_to_anthropic_format/1))

        case get_option(options, :tool_choice) do
          nil -> body
          choice -> Map.put(body, :tool_choice, choice)
        end
    end
  end

  # Handle both map and keyword list options (for tests vs real requests)
  defp get_option(options, key, default \\ nil)

  defp get_option(options, key, default) when is_map(options) do
    Map.get(options, key, default)
  end

  defp get_option(options, key, default) when is_list(options) do
    Keyword.get(options, key, default)
  end

  defp tool_to_anthropic_format(tool) do
    schema = ReqLLM.Tool.to_schema(tool, :openai)

    %{
      name: schema["function"]["name"],
      description: schema["function"]["description"],
      input_schema: schema["function"]["parameters"]
    }
  end

  defp translate_stop_parameter(opts) do
    case Keyword.get(opts, :stop) do
      nil ->
        opts

      stop when is_binary(stop) ->
        opts |> Keyword.delete(:stop) |> Keyword.put(:stop_sequences, [stop])

      stop when is_list(stop) ->
        opts |> Keyword.delete(:stop) |> Keyword.put(:stop_sequences, stop)
    end
  end

  defp translate_unsupported_parameters(opts) do
    # Remove parameters not supported by Anthropic
    unsupported = [
      :presence_penalty,
      :frequency_penalty,
      :logprobs,
      :top_logprobs,
      :response_format
    ]

    Enum.reduce(unsupported, opts, &Keyword.delete(&2, &1))
  end

  defp decode_success_response(req, resp) do
    operation = req.options[:operation]

    case operation do
      _ ->
        decode_anthropic_response(req, resp, operation)
    end
  end

  defp decode_error_response(req, resp, status) do
    err =
      ReqLLM.Error.API.Response.exception(
        reason: "Anthropic API error",
        status: status,
        response_body: resp.body
      )

    {req, err}
  end

  defp decode_anthropic_response(req, resp, operation) do
    model_name = req.options[:model]

    # Handle case where model_name might be nil
    model =
      case model_name do
        nil ->
          case req.private[:req_llm_model] do
            %ReqLLM.Model{} = stored_model -> stored_model
            _ -> %ReqLLM.Model{provider: :anthropic, model: "unknown"}
          end

        model_name when is_binary(model_name) ->
          %ReqLLM.Model{provider: :anthropic, model: model_name}
      end

    is_streaming = req.options[:stream] == true

    if is_streaming do
      decode_streaming_response(req, resp, model_name)
    else
      decode_non_streaming_response(req, resp, model, operation)
    end
  end

  defp decode_streaming_response(req, resp, model_name) do
    # Similar structure to defaults but use Anthropic-specific stream handling
    {stream, provider_meta} =
      case resp.body do
        %Stream{} = existing_stream ->
          {existing_stream, %{}}

        _ ->
          # Real-time streaming - use the stream created by Stream step
          # The request has already been initiated by the initial Req.request call
          # We just need to return the configured stream, not make another request
          real_time_stream = Req.Request.get_private(req, :real_time_stream, [])

          {real_time_stream, %{}}
      end

    response = %ReqLLM.Response{
      id: "stream-#{System.unique_integer([:positive])}",
      model: model_name,
      context: req.options[:context] || %ReqLLM.Context{messages: []},
      message: nil,
      stream?: true,
      stream: stream,
      usage: %{input_tokens: 0, output_tokens: 0, total_tokens: 0},
      finish_reason: nil,
      provider_meta: provider_meta
    }

    {req, %{resp | body: response}}
  end

  defp decode_non_streaming_response(req, resp, model, operation) do
    body = ensure_parsed_body(resp.body)
    {:ok, response} = ReqLLM.Providers.Anthropic.Response.decode_response(body, model)

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
end
