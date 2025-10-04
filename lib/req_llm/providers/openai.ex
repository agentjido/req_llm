defmodule ReqLLM.Providers.OpenAI do
  @moduledoc """
  OpenAI provider implementation using the Provider behavior.

  Supports OpenAI's Chat Completions API and Embeddings API with features including:
  - Text generation with GPT models
  - Streaming responses
  - Tool calling
  - Multi-modal inputs (text and images)
  - Embeddings generation
  - O1/O3/GPT-5 model support with automatic parameter translation
  - Reasoning effort control for GPT-5 models

  ## Implementation

  Uses built-in OpenAI-style encoding/decoding defaults.
  No custom request/response handling needed.

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
      encoding_format: [type: :string, doc: "Format for embedding output (float, base64)"],
      max_completion_tokens: [
        type: :integer,
        doc: "Maximum completion tokens (required for reasoning models like o1, o3, gpt-5)"
      ],
      reasoning_effort: [
        type:
          {:or,
           [{:in, [:minimal, :low, :medium, :high]}, {:in, ["minimal", "low", "medium", "high"]}]},
        doc: "Reasoning effort level for GPT-5 models (minimal, low, medium, high)"
      ]
    ]

  import ReqLLM.Provider.Utils, only: [maybe_put: 3]

  require Logger

  @impl ReqLLM.Provider
  @doc """
  Custom prepare_request to route reasoning models to /v1/responses endpoint.

  - :chat operations detect model type and route to appropriate endpoint
  - :object operations maintain OpenAI-specific token handling
  """
  def prepare_request(:chat, model_spec, prompt, opts) do
    with {:ok, model} <- ReqLLM.Model.from(model_spec),
         {:ok, context} <- ReqLLM.Context.normalize(prompt, opts),
         opts_with_context = Keyword.put(opts, :context, context),
         http_opts = Keyword.get(opts, :req_http_options, []),
         {:ok, processed_opts} <-
           ReqLLM.Provider.Options.process(__MODULE__, :chat, model, opts_with_context) do
      responses_api? = use_responses_api?(model)
      path = if responses_api?, do: "/responses", else: "/chat/completions"

      req_keys =
        supported_provider_options() ++
          [:context, :operation, :text, :stream, :model, :provider_options, :responses_api]

      request =
        Req.new(
          [
            url: path,
            method: :post,
            receive_timeout: Keyword.get(processed_opts, :receive_timeout, 30_000)
          ] ++ http_opts
        )
        |> Req.Request.register_options(req_keys)
        |> Req.Request.merge_options(
          Keyword.take(processed_opts, req_keys) ++
            [
              model: model.model,
              base_url: Keyword.get(processed_opts, :base_url, default_base_url()),
              responses_api: responses_api?
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
      |> Keyword.put(:tool_choice, %{
        type: "function",
        function: %{name: "structured_output"}
      })
      |> put_default_max_tokens_for_model(model_spec)
      |> Keyword.put(:operation, :object)

    prepare_request(:chat, model_spec, prompt, opts_with_tool)
  end

  # Delegate all other operations to defaults
  def prepare_request(operation, model_spec, input, opts) do
    case ReqLLM.Provider.Defaults.prepare_request(__MODULE__, operation, model_spec, input, opts) do
      {:error, %ReqLLM.Error.Invalid.Parameter{parameter: param}} ->
        # Customize error message for unsupported operations
        custom_param = String.replace(param, inspect(__MODULE__), "OpenAI provider")
        {:error, ReqLLM.Error.Invalid.Parameter.exception(parameter: custom_param)}

      result ->
        result
    end
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
  def translate_options(operation, %ReqLLM.Model{} = model, opts) do
    steps = ReqLLM.Providers.OpenAI.ParamProfiles.steps_for(operation, model)
    ReqLLM.ParamTransform.apply(opts, steps)
  end

  def translate_options(_operation, _model, opts) do
    {opts, []}
  end

  @doc """
  Custom attach_stream to route reasoning models to /v1/responses endpoint for streaming.
  """
  @impl ReqLLM.Provider
  def attach_stream(model, context, opts, _finch_name) do
    api_key = ReqLLM.Keys.get!(model, opts)
    responses_api? = use_responses_api?(model)
    path = if responses_api?, do: "/responses", else: "/chat/completions"

    headers = [
      {"Authorization", "Bearer " <> api_key},
      {"Content-Type", "application/json"},
      {"Accept", "text/event-stream"}
    ]

    url =
      case Keyword.get(opts, :base_url) do
        nil -> default_base_url() <> path
        base_url -> "#{base_url}#{path}"
      end

    req_opts =
      [
        model: model.model,
        context: context,
        stream: true,
        responses_api: responses_api?
      ] ++ Keyword.delete(opts, :finch_name)

    temp_request = %Req.Request{
      method: :post,
      url: URI.parse("https://example.com/temp"),
      headers: %{},
      body: {:json, %{}},
      options: Map.new(req_opts)
    }

    encoded_request = encode_body(temp_request)
    body = encoded_request.body

    {:ok, Finch.build(:post, url, headers, body)}
  rescue
    error ->
      {:error,
       ReqLLM.Error.API.Request.exception(
         reason: "Failed to build streaming request",
         details: Exception.message(error)
       )}
  end

  @doc """
  Custom body encoding that adds OpenAI-specific token handling for O1/O3 models and Responses API format.
  """
  @impl ReqLLM.Provider
  def encode_body(request) do
    if request.options[:responses_api] do
      encode_responses_body(request)
    else
      encode_chat_body(request)
    end
  end

  defp encode_chat_body(request) do
    request = ReqLLM.Provider.Defaults.default_encode_body(request)
    body = Jason.decode!(request.body)

    enhanced_body =
      case request.options[:operation] do
        :embedding ->
          add_embedding_options(body, request.options)

        _ ->
          body
          |> add_token_limits(request.options[:model], request.options)
          |> add_stream_options(request.options)
          |> add_reasoning_effort(request.options)
          |> translate_tool_choice_format()
      end

    Map.put(request, :body, Jason.encode!(enhanced_body))
  end

  defp encode_responses_body(request) do
    ctx = request.options[:context] || %ReqLLM.Context{messages: []}
    provider_opts = request.options[:provider_options] || []

    input =
      Enum.map(ctx.messages, fn msg ->
        content =
          Enum.flat_map(msg.content, fn part ->
            case part.type do
              :text -> [%{"type" => "input_text", "text" => part.text}]
              _ -> []
            end
          end)

        %{"role" => Atom.to_string(msg.role), "content" => content}
      end)

    max_output_tokens =
      request.options[:max_output_tokens] ||
        request.options[:max_completion_tokens] ||
        request.options[:max_tokens]

    body =
      %{"model" => request.options[:model], "input" => input}
      |> maybe_put("stream", request.options[:stream])
      |> maybe_put("max_output_tokens", max_output_tokens)
      |> maybe_put("tools", encode_tools_if_any(request))
      |> maybe_put("tool_choice", encode_tool_choice_if_any(request))
      |> maybe_put("reasoning", encode_reasoning_effort(provider_opts[:reasoning_effort]))

    Map.put(request, :body, Jason.encode!(body))
  end

  defp encode_tools_if_any(request) do
    case request.options[:tools] do
      nil -> nil
      [] -> nil
      tools -> Enum.map(tools, &ReqLLM.Tool.to_schema/1)
    end
  end

  defp encode_tool_choice_if_any(request) do
    case request.options[:tool_choice] do
      nil -> nil
      choice -> choice
    end
  end

  defp encode_reasoning_effort(nil), do: nil

  defp encode_reasoning_effort(effort) when is_atom(effort),
    do: %{"effort" => Atom.to_string(effort)}

  defp encode_reasoning_effort(effort) when is_binary(effort), do: %{"effort" => effort}
  defp encode_reasoning_effort(_), do: nil

  defp add_embedding_options(body, request_options) do
    provider_opts = request_options[:provider_options] || []

    body
    |> maybe_put(:dimensions, provider_opts[:dimensions])
    |> maybe_put(:encoding_format, provider_opts[:encoding_format])
  end

  @doc """
  Custom decode_response to handle both Chat Completions and Responses API formats.
  """
  @impl ReqLLM.Provider
  def decode_response({req, resp}) do
    case {req.options[:responses_api], resp.status} do
      {true, 200} ->
        decode_responses_api({req, resp})

      {_, 200} ->
        ReqLLM.Provider.Defaults.default_decode_response({req, resp})

      {_, status} ->
        decode_openai_error_response(req, resp, status)
    end
  end

  defp decode_responses_api({req, resp}) do
    body = ReqLLM.Provider.Utils.ensure_parsed_body(resp.body)

    text =
      body["output_text"] ||
        (body["output"] || [])
        |> Enum.find_value(fn seg ->
          case seg do
            %{"type" => "output_text", "text" => t} -> t
            _ -> nil
          end
        end) || ""

    usage = %{
      input_tokens: get_in(body, ["usage", "input_tokens"]) || 0,
      output_tokens: get_in(body, ["usage", "output_tokens"]) || 0,
      total_tokens:
        (get_in(body, ["usage", "input_tokens"]) || 0) +
          (get_in(body, ["usage", "output_tokens"]) || 0)
    }

    msg = %ReqLLM.Message{
      role: :assistant,
      content: [%ReqLLM.Message.ContentPart{type: :text, text: text}]
    }

    response = %ReqLLM.Response{
      id: body["id"] || "unknown",
      model: body["model"] || req.options[:model],
      context: %ReqLLM.Context{messages: if(text == "", do: [], else: [msg])},
      message: msg,
      stream?: false,
      stream: nil,
      usage: usage,
      finish_reason: :stop,
      provider_meta: Map.drop(body, ["id", "model", "output_text", "output", "usage"])
    }

    ctx = req.options[:context] || %ReqLLM.Context{messages: []}
    merged_response = %{response | context: ReqLLM.Context.append(ctx, msg)}

    {req, %{resp | body: merged_response}}
  end

  defp decode_openai_error_response(req, resp, status) do
    err =
      ReqLLM.Error.API.Response.exception(
        reason: "OpenAI API error",
        status: status,
        response_body: resp.body
      )

    {req, err}
  end

  @doc """
  Custom decode_sse_event to handle both Chat Completions and Responses API SSE events.
  """
  @impl ReqLLM.Provider
  def decode_sse_event(%{data: data} = event, model) when is_map(data) do
    cond do
      Map.has_key?(data, "choices") ->
        ReqLLM.Provider.Defaults.default_decode_sse_event(event, model)

      is_binary(data["type"]) and String.starts_with?(data["type"], "response.") ->
        decode_responses_sse_event(data, model)

      true ->
        []
    end
  end

  def decode_sse_event(%{data: "[DONE]"}, _model) do
    [ReqLLM.StreamChunk.meta(%{terminal?: true})]
  end

  def decode_sse_event(_event, _model), do: []

  defp decode_responses_sse_event(data, model) do
    case data["type"] do
      "response.output_text.delta" ->
        text = data["delta"] || ""
        if text == "", do: [], else: [ReqLLM.StreamChunk.text(text)]

      "response.usage" ->
        usage_data = data["usage"] || %{}

        usage = %{
          input_tokens: usage_data["input_tokens"] || 0,
          output_tokens: usage_data["output_tokens"] || 0,
          total_tokens: (usage_data["input_tokens"] || 0) + (usage_data["output_tokens"] || 0)
        }

        [ReqLLM.StreamChunk.meta(%{usage: usage, model: model.model})]

      "response.output_text.done" ->
        []

      "response.completed" ->
        [ReqLLM.StreamChunk.meta(%{terminal?: true, finish_reason: :stop})]

      _ ->
        []
    end
  end

  @doc false
  defp add_token_limits(body, model_name, request_options) do
    if is_reasoning_model_name?(model_name) do
      maybe_put(
        body,
        :max_completion_tokens,
        request_options[:max_completion_tokens] || request_options[:max_tokens]
      )
    else
      body
      |> maybe_put(:max_tokens, request_options[:max_tokens])
      |> maybe_put(:max_completion_tokens, request_options[:max_completion_tokens])
    end
  end

  defp put_default_max_tokens_for_model(opts, model_spec) do
    case ReqLLM.Model.from(model_spec) do
      {:ok, %{model: model_name}} when is_binary(model_name) ->
        if is_reasoning_model_name?(model_name) do
          Keyword.put_new(opts, :max_completion_tokens, 4096)
        else
          Keyword.put_new(opts, :max_tokens, 4096)
        end

      _ ->
        Keyword.put_new(opts, :max_tokens, 4096)
    end
  end

  defp is_reasoning_model_name?(<<"gpt-5", _::binary>>), do: true
  defp is_reasoning_model_name?(<<"gpt-4.1", _::binary>>), do: true
  defp is_reasoning_model_name?(<<"o1", _::binary>>), do: true
  defp is_reasoning_model_name?(<<"o3", _::binary>>), do: true
  defp is_reasoning_model_name?(<<"o4", _::binary>>), do: true
  defp is_reasoning_model_name?(_), do: false

  @doc false
  defp use_responses_api?(%ReqLLM.Model{model: model_name}), do: use_responses_api?(model_name)
  defp use_responses_api?(<<"gpt-5", _::binary>>), do: true
  defp use_responses_api?(<<"gpt-4.1", _::binary>>), do: true
  defp use_responses_api?(<<"gpt-image-1">>), do: true
  defp use_responses_api?(<<"computer-use-preview">>), do: true
  defp use_responses_api?(<<"o1-mini", _::binary>>), do: false
  defp use_responses_api?(<<"o1-preview", _::binary>>), do: false
  defp use_responses_api?(<<"o1">>), do: true
  defp use_responses_api?(<<"o3", _::binary>>), do: true
  defp use_responses_api?(<<"o4", _::binary>>), do: true
  defp use_responses_api?(_), do: false

  @doc false
  defp add_stream_options(body, request_options) do
    # Automatically include usage data when streaming for better user experience
    if request_options[:stream] do
      maybe_put(body, :stream_options, %{include_usage: true})
    else
      body
    end
  end

  @doc false
  defp add_reasoning_effort(body, request_options) do
    provider_opts = request_options[:provider_options] || []
    maybe_put(body, :reasoning_effort, provider_opts[:reasoning_effort])
  end

  @doc false
  defp translate_tool_choice_format(body) do
    # Handle both atom and string keys in body
    {tool_choice, body_key} =
      cond do
        Map.has_key?(body, :tool_choice) -> {Map.get(body, :tool_choice), :tool_choice}
        Map.has_key?(body, "tool_choice") -> {Map.get(body, "tool_choice"), "tool_choice"}
        true -> {nil, nil}
      end

    # Handle both atom and string keys in tool_choice map
    type = tool_choice && (Map.get(tool_choice, :type) || Map.get(tool_choice, "type"))
    name = tool_choice && (Map.get(tool_choice, :name) || Map.get(tool_choice, "name"))

    if type == "tool" && name do
      # Build replacement with same key types as tool_choice
      replacement =
        if is_map_key(tool_choice, :type) do
          %{type: "function", function: %{name: name}}
        else
          %{"type" => "function", "function" => %{"name" => name}}
        end

      Map.put(body, body_key, replacement)
    else
      body
    end
  end
end
