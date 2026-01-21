defmodule ReqLLM.Providers.Zenmux do
  @moduledoc """
  Zenmux provider – OpenAI Chat Completions compatible with Zenmux's unified API.

  ## Implementation

  Uses built-in OpenAI-style encoding/decoding defaults.
  No custom wrapper modules – leverages the standard OpenAI-compatible implementations.

  ## Zenmux-Specific Extensions

  Beyond standard OpenAI parameters, Zenmux supports:
  - `provider` - Provider routing configuration with routing strategy and fallback
  - `model_routing_config` - Model selection and routing within the same provider
  - `reasoning` - Reasoning process configuration (enable, depth, expose)
  - `web_search_options` - Web search tool configuration
  - `verbosity` - Output detail level (low, medium, high)

  ## Provider Routing

  Zenmux supports advanced provider routing with the `provider` option:
  - `routing.type` - Routing type (priority, round_robin, least_latency)
  - `routing.primary_factor` - Primary consideration (cost, speed, quality)
  - `routing.providers` - List of providers for routing
  - `fallback` - Failover strategy (true, false, or specific provider name)

  ## Model Routing

  Configure model selection with `model_routing_config`:
  - `available_models` - List of model names for routing
  - `preference` - Preferred model name
  - `task_info` - Task metadata (task_type, complexity)

  See `provider_schema/0` for the complete Zenmux-specific schema and
  `ReqLLM.Provider.Options` for inherited OpenAI parameters.

  ## Configuration

      # Add to .env file (automatically loaded)
      ZENMUX_API_KEY=sk-ai-v1-...
  """

  use ReqLLM.Provider,
    id: :zenmux,
    default_base_url: "https://zenmux.ai/api/v1",
    default_env_key: "ZENMUX_API_KEY"

  import ReqLLM.Provider.Utils, only: [maybe_put: 3]

  @provider_schema [
    provider: [
      type: :map,
      doc: "Provider routing configuration with routing strategy and fallback"
    ],
    model_routing_config: [
      type: :map,
      doc: "Model selection and routing configuration within the same provider"
    ],
    reasoning: [
      type: :map,
      doc: "Reasoning process configuration (enable, depth, expose)"
    ],
    web_search_options: [
      type: :map,
      doc: "Web search tool configuration"
    ],
    verbosity: [
      type: {:in, ~w(low medium high)},
      doc: "Output detail level"
    ],
    max_completion_tokens: [
      type: :pos_integer,
      doc: "Maximum number of tokens to generate (includes reasoning tokens)"
    ]
  ]

  @doc """
  Custom prepare_request for :object operations to maintain Zenmux-specific max_tokens handling.

  Ensures that structured output requests have adequate token limits while delegating
  other operations to the default implementation.
  """
  @impl ReqLLM.Provider
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

    opts_with_tokens =
      case Keyword.get(opts_with_tool, :max_tokens) do
        nil -> Keyword.put(opts_with_tool, :max_tokens, 4096)
        tokens when tokens < 200 -> Keyword.put(opts_with_tool, :max_tokens, 200)
        _tokens -> opts_with_tool
      end

    opts_with_operation = Keyword.put(opts_with_tokens, :operation, :object)

    ReqLLM.Provider.Defaults.prepare_request(
      __MODULE__,
      :chat,
      model_spec,
      prompt,
      opts_with_operation
    )
  end

  def prepare_request(:embedding, _model_spec, _input, _opts) do
    supported_operations = [:chat, :object]

    {:error,
     ReqLLM.Error.Invalid.Parameter.exception(
       parameter:
         "operation: :embedding not supported by #{inspect(__MODULE__)}. Supported operations: #{inspect(supported_operations)}"
     )}
  end

  def prepare_request(operation, model_spec, input, opts) do
    ReqLLM.Provider.Defaults.prepare_request(__MODULE__, operation, model_spec, input, opts)
  end

  @impl ReqLLM.Provider
  def translate_options(_operation, _model, opts) do
    warnings = []

    {max_tokens, opts} = Keyword.pop(opts, :max_tokens)

    opts =
      if max_tokens do
        Keyword.put(opts, :max_completion_tokens, max_tokens)
      else
        opts
      end

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

    {opts, Enum.reverse(warnings)}
  end

  @doc """
  Custom body encoding that adds Zenmux-specific extensions to the default OpenAI-compatible format.

  Adds support for Zenmux routing and configuration parameters:
  - provider (routing configuration)
  - model_routing_config (model selection)
  - reasoning (reasoning process config)
  - web_search_options (web search config)
  - verbosity (output detail level)
  - reasoning_effort (reasoning level)
  - max_completion_tokens (replaces max_tokens)
  """
  @impl ReqLLM.Provider
  def encode_body(request) do
    request = ReqLLM.Provider.Defaults.default_encode_body(request)

    body = Jason.decode!(request.body)

    # Ensure tool_choice is present from options if not in body (in case default dropped it)
    tool_choice_opt =
      cond do
        is_map(request.options) -> Map.get(request.options, :tool_choice)
        Keyword.keyword?(request.options) -> Keyword.get(request.options, :tool_choice)
        true -> nil
      end

    body =
      if !Map.has_key?(body, "tool_choice") and !Map.has_key?(body, :tool_choice) and
           tool_choice_opt do
        Map.put(body, "tool_choice", tool_choice_opt)
      else
        body
      end

    enhanced_body =
      body
      |> translate_tool_choice_format()
      |> maybe_put(:max_completion_tokens, request.options[:max_completion_tokens])
      |> maybe_put(:provider, request.options[:provider])
      |> maybe_put(:model_routing_config, request.options[:model_routing_config])
      |> maybe_put(:reasoning, request.options[:reasoning])
      |> maybe_put(:web_search_options, request.options[:web_search_options])
      |> maybe_put(:verbosity, request.options[:verbosity])
      |> maybe_put(:reasoning_effort, request.options[:reasoning_effort])
      |> add_stream_options(request.options)

    encoded_body = Jason.encode!(enhanced_body)
    request = Map.put(request, :body, encoded_body)

    request
  end

  defp add_stream_options(body, request_options) do
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

    type = tool_choice && (Map.get(tool_choice, :type) || Map.get(tool_choice, "type"))
    name = tool_choice && (Map.get(tool_choice, :name) || Map.get(tool_choice, "name"))

    if type == "tool" && name do
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

  @impl ReqLLM.Provider
  def decode_response({req, resp} = args) do
    case resp.status do
      200 ->
        body = ensure_parsed_body(resp.body)

        reasoning_details = extract_reasoning_details(body)

        body_with_tool_calls =
          case extract_deepseek_tool_calls(body) do
            {:ok, updated_body} -> updated_body
            :no_tool_calls -> body
          end

        {req, resp_with_decoded} =
          ReqLLM.Provider.Defaults.default_decode_response(
            {req, %{resp | body: body_with_tool_calls}}
          )

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
    |> String.replace(~r/<｜tool▁call▁begin｜>.*?<｜tool▁call▁end｜>/s, "")
    |> String.trim()
  end

  defp extract_reasoning_details(body) when is_map(body) do
    with %{"choices" => [first_choice | _]} <- body,
         %{"message" => %{"reasoning_details" => details}} when is_list(details) <- first_choice do
      if Enum.all?(details, &is_map/1) do
        details
      end
    else
      _ -> nil
    end
  end

  defp extract_reasoning_details(_), do: nil

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
