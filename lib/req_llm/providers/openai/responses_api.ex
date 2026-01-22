defmodule ReqLLM.Providers.OpenAI.ResponsesAPI do
  @moduledoc """
  OpenAI Responses API driver for reasoning models.

  Implements the `ReqLLM.Providers.OpenAI.API` behaviour for OpenAI's Responses endpoint,
  which provides extended reasoning capabilities for advanced models.

  ## Endpoint

  `/v1/responses`

  ## Supported Models

  Models with `"api": "responses"` metadata:
  - o-series: o1, o3, o4, o1-preview, o1-mini
  - GPT-4.1 series: gpt-4.1, gpt-4.1-mini
  - GPT-5 series: gpt-5, gpt-5-preview

  ## Capabilities

  - **Reasoning**: Extended thinking with explicit reasoning token tracking
  - **Streaming**: SSE-based streaming with reasoning deltas and usage events
  - **Tools**: Function calling with responses-specific format
  - **Reasoning effort**: Control computation intensity (minimal, low, medium, high)
  - **Enhanced usage**: Separate tracking of reasoning vs output tokens

  ## Encoding Specifics

  - Input messages use `input_text` content type instead of `text`
  - Token limits use `max_output_tokens` instead of `max_tokens`
  - Tool choice format: `{type: "function", name: "tool_name"}`
  - Reasoning effort: `{effort: "high"}` format

  ## Decoding

  ### Non-streaming Responses

  Aggregates multiple output segment types:
  - `output_text` segments → text content
  - `reasoning` segments (summary + content) → thinking content
  - `function_call` segments → tool_call parts

  ### Streaming Events

  - `response.output_text.delta` → text chunks
  - `response.reasoning.delta` → thinking chunks
  - `response.usage` → usage metrics with reasoning_tokens
  - `response.completed` → terminal event with finish_reason
  - `response.incomplete` → terminal event for truncated responses

  ## Usage Normalization

  Extracts reasoning tokens from `usage.output_tokens_details.reasoning_tokens` and provides:
  - `:reasoning_tokens` - Primary field (recommended)
  - `:reasoning` - Backward-compatibility alias (deprecated)
  """
  @behaviour ReqLLM.Providers.OpenAI.API

  require ReqLLM.Debug, as: Debug

  @impl true
  def path, do: "/responses"

  @impl true
  def encode_body(request) do
    context = request.options[:context] || %ReqLLM.Context{messages: []}
    model_name = request.options[:model] || request.options[:id]
    opts = request.options

    body = build_request_body(context, model_name, opts, request)

    Map.put(request, :body, Jason.encode!(body))
  end

  @impl true
  def decode_response({req, resp}) do
    case resp.status do
      200 ->
        decode_responses_success({req, resp})

      status ->
        err =
          ReqLLM.Error.API.Response.exception(
            reason: "OpenAI Responses API error",
            status: status,
            response_body: resp.body
          )

        {req, err}
    end
  end

  @impl true
  def decode_stream_event(%{data: "[DONE]"}, _model) do
    [ReqLLM.StreamChunk.meta(%{terminal?: true})]
  end

  def decode_stream_event(%{data: data} = event, model) when is_map(data) do
    event_type =
      Map.get(event, :event) || Map.get(event, "event") || data["event"] || data["type"]

    Debug.dbug(
      fn ->
        "ResponsesAPI decode_stream_event: event=#{inspect(Map.keys(event))}, event_type=#{inspect(event_type)}"
      end,
      component: :provider
    )

    case event_type do
      "response.output_text.delta" ->
        text = data["delta"] || ""
        if text == "", do: [], else: [ReqLLM.StreamChunk.text(text)]

      "response.reasoning.delta" ->
        text = data["delta"] || ""
        if text == "", do: [], else: [ReqLLM.StreamChunk.thinking(text)]

      "response.usage" ->
        usage_data = data["usage"] || %{}

        raw_usage = %{
          input_tokens: usage_data["input_tokens"] || 0,
          output_tokens: usage_data["output_tokens"] || 0,
          total_tokens: (usage_data["input_tokens"] || 0) + (usage_data["output_tokens"] || 0)
        }

        usage = normalize_responses_usage(raw_usage, data)

        [ReqLLM.StreamChunk.meta(%{usage: usage, model: model.id})]

      "response.output_text.done" ->
        []

      "response.function_call.delta" ->
        handle_function_call_delta(data)

      "response.function_call_arguments.delta" ->
        handle_function_call_arguments_delta(data)

      "response.function_call_arguments.done" ->
        []

      "response.function_call.name.delta" ->
        handle_function_call_name_delta(data)

      "response.output_item.added" ->
        handle_output_item_added(data)

      "response.output_item.done" ->
        []

      "response.completed" ->
        usage_data = get_in(data, ["response", "usage"])
        response_id = get_in(data, ["response", "id"])

        meta = %{terminal?: true, finish_reason: :stop}

        meta =
          if response_id do
            Map.put(meta, :response_id, response_id)
          else
            meta
          end

        meta =
          if usage_data do
            raw_usage = %{
              input_tokens: usage_data["input_tokens"] || 0,
              output_tokens: usage_data["output_tokens"] || 0,
              total_tokens:
                usage_data["total_tokens"] ||
                  (usage_data["input_tokens"] || 0) + (usage_data["output_tokens"] || 0)
            }

            response_data = data["response"] || %{}
            usage = normalize_responses_usage(raw_usage, response_data)
            Map.put(meta, :usage, usage)
          else
            meta
          end

        [ReqLLM.StreamChunk.meta(meta)]

      "response.incomplete" ->
        reason = data["reason"] || "incomplete"

        [
          ReqLLM.StreamChunk.meta(%{
            terminal?: true,
            finish_reason: normalize_finish_reason(reason)
          })
        ]

      _ ->
        []
    end
  end

  def decode_stream_event(_event, _model), do: []

  # ========================================================================
  # Shared Request Building Helpers (used by both encode_body and attach_stream)
  # ========================================================================

  defp build_request_headers(model, opts) do
    api_key = ReqLLM.Keys.get!(model, opts)

    [
      {"Authorization", "Bearer " <> api_key},
      {"Content-Type", "application/json"}
    ]
  end

  defp build_request_url(opts) do
    case Keyword.get(opts, :base_url) do
      nil -> ReqLLM.Providers.OpenAI.base_url() <> path()
      base_url -> "#{base_url}#{path()}"
    end
  end

  defp build_request_body(context, model_name, opts, request) do
    opts_map = if is_map(opts), do: opts, else: Map.new(opts)
    provider_opts = opts_map[:provider_options] || []

    previous_response_id =
      provider_opts[:previous_response_id] ||
        extract_previous_response_id_from_context(context)

    {input, tool_messages} =
      Enum.reduce(context.messages, {[], []}, fn msg, {input_acc, tool_acc} ->
        case msg.role do
          :tool ->
            {input_acc, [msg | tool_acc]}

          _ ->
            content_type = if msg.role == :assistant, do: "output_text", else: "input_text"

            content =
              Enum.flat_map(msg.content, fn part ->
                case part.type do
                  :text -> [%{"type" => content_type, "text" => part.text}]
                  _ -> []
                end
              end)

            if content == [] and msg.tool_calls == nil do
              {input_acc, tool_acc}
            else
              if msg.role == :assistant and msg.tool_calls != nil and msg.tool_calls != [] do
                {input_acc, tool_acc}
              else
                {input_acc ++ [%{"role" => Atom.to_string(msg.role), "content" => content}],
                 tool_acc}
              end
            end
        end
      end)

    # Only send tool outputs if the response we're continuing from has pending tool calls.
    # Find which tool_call_ids are pending (have a tool call but no subsequent tool result yet).
    pending_tool_call_ids = find_pending_tool_call_ids(context.messages)

    tool_outputs_from_context =
      tool_messages
      |> Enum.reverse()
      |> Enum.filter(fn msg -> msg.tool_call_id in pending_tool_call_ids end)
      |> extract_tool_outputs_from_messages()

    tool_outputs =
      case provider_opts[:tool_outputs] do
        nil -> tool_outputs_from_context
        [] -> tool_outputs_from_context
        explicit_outputs -> explicit_outputs
      end

    input =
      case tool_outputs do
        [] -> input
        outputs -> input ++ encode_tool_outputs(outputs)
      end

    max_output_tokens =
      opts_map[:max_output_tokens] ||
        opts_map[:max_completion_tokens] ||
        opts_map[:max_tokens]

    temp_request = request || %{options: opts_map}
    tools = encode_tools_if_any(temp_request) |> ensure_deep_research_tools(temp_request)

    tool_choice = encode_tool_choice(opts_map[:tool_choice])
    reasoning = encode_reasoning_effort(opts_map[:reasoning_effort])

    text_format = encode_text_format(provider_opts[:response_format])

    body =
      Map.new()
      |> Map.put("model", model_name)
      |> Map.put("input", input)
      |> maybe_put_string("stream", opts_map[:stream])
      |> maybe_put_string("max_output_tokens", max_output_tokens)
      |> maybe_put_string("reasoning", reasoning)
      |> maybe_put_string("tools", tools)
      |> maybe_put_string("tool_choice", tool_choice)
      |> maybe_put_string("text", text_format)

    if previous_response_id do
      Map.put(body, "previous_response_id", previous_response_id)
    else
      body
    end
  end

  # ========================================================================

  @impl true
  def attach_stream(model, context, opts, _finch_name) do
    headers = build_request_headers(model, opts) ++ [{"Accept", "text/event-stream"}]

    base_url = ReqLLM.Provider.Options.effective_base_url(ReqLLM.Providers.OpenAI, model, opts)

    cleaned_opts =
      opts
      |> Keyword.delete(:finch_name)
      |> Keyword.delete(:compiled_schema)
      |> Keyword.put(:provider_options, Keyword.get(opts, :provider_options, []))
      |> Keyword.put(:stream, true)
      |> Keyword.put(:model, model.id)
      |> Keyword.put(:context, context)
      |> Keyword.put(:base_url, base_url)

    body = build_request_body(context, model.id, cleaned_opts, nil)
    url = build_request_url(cleaned_opts)

    {:ok, Finch.build(:post, url, headers, Jason.encode!(body))}
  rescue
    error ->
      {:error,
       ReqLLM.Error.API.Request.exception(
         reason: "Failed to build Responses API streaming request: #{Exception.message(error)}"
       )}
  end

  defp handle_function_call_delta(%{"delta" => delta} = data) when is_map(delta) do
    # Use output_index to match the tool_call index from response.output_item.added
    index = data["output_index"] || data["index"] || 0
    call_id = data["call_id"] || data["id"] || "call_#{:erlang.unique_integer([:positive])}"

    chunks = []

    chunks =
      case delta["name"] do
        name when is_binary(name) and name != "" ->
          [ReqLLM.StreamChunk.tool_call(name, %{}, %{id: call_id, index: index})]

        _ ->
          chunks
      end

    chunks =
      case delta["arguments"] do
        fragment when is_binary(fragment) and fragment != "" ->
          chunks ++
            [
              ReqLLM.StreamChunk.meta(%{
                tool_call_args: %{index: index, fragment: fragment}
              })
            ]

        _ ->
          chunks
      end

    chunks
  end

  defp handle_function_call_delta(_), do: []

  defp handle_function_call_arguments_delta(%{"delta" => fragment} = data)
       when is_binary(fragment) and fragment != "" do
    # Use output_index to match the tool_call index from response.output_item.added
    index = data["output_index"] || data["index"] || 0

    [
      ReqLLM.StreamChunk.meta(%{
        tool_call_args: %{index: index, fragment: fragment}
      })
    ]
  end

  defp handle_function_call_arguments_delta(_), do: []

  defp handle_function_call_name_delta(%{"delta" => name} = data)
       when is_binary(name) and name != "" do
    # Use output_index to match the tool_call index from response.output_item.added
    index = data["output_index"] || data["index"] || 0
    call_id = data["call_id"] || data["id"] || "call_#{:erlang.unique_integer([:positive])}"

    [ReqLLM.StreamChunk.tool_call(name, %{}, %{id: call_id, index: index})]
  end

  defp handle_function_call_name_delta(_), do: []

  defp handle_output_item_added(%{"item" => item} = data) when is_map(item) do
    case item["type"] do
      "function_call" ->
        index = data["output_index"] || 0
        call_id = item["call_id"] || item["id"] || "call_#{:erlang.unique_integer([:positive])}"
        name = item["name"]

        if name && name != "" do
          [ReqLLM.StreamChunk.tool_call(name, %{}, %{id: call_id, index: index})]
        else
          []
        end

      _ ->
        []
    end
  end

  defp handle_output_item_added(_), do: []

  defp maybe_put_string(map, _key, nil), do: map
  defp maybe_put_string(map, key, value), do: Map.put(map, key, value)

  # Extract the most recent response_id from assistant messages.
  # This should be the LAST assistant message, not specifically one with tool_calls.
  # The response_id creates a chain: A -> B -> C, and we need to continue from the
  # most recent response in the chain.
  defp extract_previous_response_id_from_context(context) do
    context.messages
    |> Enum.reverse()
    |> Enum.find_value(fn msg ->
      case msg do
        %{role: :assistant, metadata: %{response_id: id}} when is_binary(id) ->
          id

        _ ->
          nil
      end
    end)
  end

  # Find tool_call_ids that need their outputs sent.
  # A tool output needs to be sent if:
  # 1. There's a tool message with that call_id
  # 2. AND there's no assistant message AFTER that tool message (meaning the output hasn't been consumed yet)
  #
  # Flow: assistant(tool_calls) → tool(result) → [assistant(answer)] OR [no response yet]
  # If the assistant(answer) exists, the tool output was already sent.
  # If it doesn't exist, we need to send the tool output.
  defp find_pending_tool_call_ids(messages) do
    # Process messages in reverse order to find:
    # 1. All tool messages that appear AFTER the last assistant message
    # These are tool outputs that haven't been sent yet
    messages
    |> Enum.reverse()
    |> Enum.reduce_while([], fn msg, acc ->
      case msg.role do
        :tool when is_binary(msg.tool_call_id) ->
          # This tool message appears before any assistant response
          # (in reverse order means it's after all assistants in forward order)
          {:cont, [msg.tool_call_id | acc]}

        :assistant ->
          # We hit an assistant message - any tool messages before this (in reverse)
          # have already been sent, so stop collecting
          {:halt, acc}

        _ ->
          {:cont, acc}
      end
    end)
  end

  defp extract_tool_outputs_from_messages(tool_messages) do
    Enum.map(tool_messages, fn msg ->
      output_text =
        msg.content
        |> Enum.find_value(fn part ->
          if part.type == :text, do: part.text
        end) || ""

      %{
        call_id: msg.tool_call_id,
        output: output_text
      }
    end)
  end

  defp encode_tool_outputs(outputs) when is_list(outputs) do
    Enum.map(outputs, fn output ->
      call_id = output[:call_id] || output["call_id"]
      raw_output = output[:output] || output["output"]

      output_string =
        cond do
          is_binary(raw_output) -> raw_output
          is_map(raw_output) or is_list(raw_output) -> Jason.encode!(raw_output)
          true -> to_string(raw_output)
        end

      %{
        "type" => "function_call_output",
        "call_id" => call_id,
        "output" => output_string
      }
    end)
  end

  defp encode_tool_outputs(_), do: []

  defp encode_tools_if_any(request) do
    case request.options[:tools] do
      nil -> nil
      [] -> nil
      tools -> Enum.map(tools, &encode_tool_for_responses_api/1)
    end
  end

  defp ensure_deep_research_tools(tools, request) do
    model_name = request.options[:model]

    case ReqLLM.model("openai:#{model_name}") do
      {:ok, model} ->
        category = get_in(model, [Access.key(:extra, %{}), :category])

        case category do
          "deep_research" ->
            ensure_deep_research_tool_present(tools)

          _ ->
            tools
        end

      _ ->
        tools
    end
  end

  defp ensure_deep_research_tool_present(nil) do
    require Logger

    Logger.info(
      "Auto-injecting web_search_preview tool for deep research model (no tools provided)"
    )

    [%{"type" => "web_search_preview"}]
  end

  defp ensure_deep_research_tool_present(tools) when is_list(tools) do
    deep_tools = ["web_search_preview", "mcp", "file_search"]

    has_deep_tool? =
      Enum.any?(tools, fn t ->
        t["type"] in deep_tools or (is_map(t) and Map.get(t, :type) in deep_tools)
      end)

    if has_deep_tool? do
      tools
    else
      require Logger

      Logger.info(
        "Auto-injecting web_search_preview tool for deep research model (tools: #{inspect(Enum.map(tools, & &1["type"]))})"
      )

      [%{"type" => "web_search_preview"} | tools]
    end
  end

  defp encode_tool_for_responses_api(%ReqLLM.Tool{} = tool) do
    schema = ReqLLM.Tool.to_schema(tool)
    function_def = schema["function"]
    params = normalize_parameters_for_strict(function_def["parameters"])

    %{
      "type" => "function",
      "name" => function_def["name"],
      "description" => function_def["description"],
      "parameters" => params,
      "strict" => true
    }
  end

  defp encode_tool_for_responses_api(tool_schema) when is_map(tool_schema) do
    function_def = tool_schema["function"] || tool_schema[:function]

    if function_def do
      name = function_def["name"] || function_def[:name]
      description = function_def["description"] || function_def[:description]
      raw_params = function_def["parameters"] || function_def[:parameters]
      params = normalize_parameters_for_strict(raw_params)

      %{
        "type" => "function",
        "name" => name,
        "description" => description,
        "parameters" => params,
        "strict" => true
      }
    else
      name = tool_schema["name"] || tool_schema[:name]
      description = tool_schema["description"] || tool_schema[:description]
      raw_params = tool_schema["parameters"] || tool_schema[:parameters]
      params = normalize_parameters_for_strict(raw_params)

      %{
        "type" => "function",
        "name" => name,
        "description" => description,
        "parameters" => params,
        "strict" => true
      }
    end
  end

  defp normalize_parameters_for_strict(nil) do
    %{
      "type" => "object",
      "properties" => %{},
      "required" => [],
      "additionalProperties" => false
    }
  end

  defp normalize_parameters_for_strict(params) when is_map(params) do
    properties = params[:properties] || params["properties"] || %{}

    all_property_names =
      properties
      |> Map.keys()
      |> Enum.map(&to_string/1)

    %{
      "type" => "object",
      "properties" => stringify_keys(properties),
      "required" => all_property_names,
      "additionalProperties" => false
    }
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      key = if is_atom(k), do: Atom.to_string(k), else: k
      value = if is_map(v), do: stringify_keys(v), else: v
      {key, value}
    end)
  end

  defp encode_tool_choice(nil), do: nil

  defp encode_tool_choice(%{type: "function", function: %{name: name}}) do
    %{"type" => "function", "name" => name}
  end

  defp encode_tool_choice(%{"type" => "function", "function" => %{"name" => name}}) do
    %{"type" => "function", "name" => name}
  end

  defp encode_tool_choice(:auto), do: "auto"
  defp encode_tool_choice(:none), do: "none"
  defp encode_tool_choice(:required), do: "required"
  defp encode_tool_choice("auto"), do: "auto"
  defp encode_tool_choice("none"), do: "none"
  defp encode_tool_choice("required"), do: "required"
  defp encode_tool_choice(_), do: nil

  defp encode_reasoning_effort(nil), do: nil

  defp encode_reasoning_effort(effort) when is_atom(effort),
    do: %{"effort" => Atom.to_string(effort)}

  defp encode_reasoning_effort(effort) when is_binary(effort), do: %{"effort" => effort}
  defp encode_reasoning_effort(_), do: nil

  @doc false
  def encode_text_format(nil), do: nil

  def encode_text_format(response_format) when is_map(response_format) do
    # Extract type - could be atom or string key
    type = response_format[:type] || response_format["type"]

    case type do
      "json_schema" ->
        json_schema = response_format[:json_schema] || response_format["json_schema"]
        # Schema.to_json handles both keyword lists (converts) and maps (pass-through)
        schema = ReqLLM.Schema.to_json(json_schema[:schema] || json_schema["schema"])

        # ResponsesAPI expects a flattened structure:
        # text.format.{type, name, strict, schema} instead of text.format.json_schema.{name, strict, schema}
        %{
          "format" => %{
            "type" => "json_schema",
            "name" => json_schema[:name] || json_schema["name"],
            "strict" => json_schema[:strict] || json_schema["strict"],
            "schema" => schema
          }
        }

      _ ->
        nil
    end
  end

  defp decode_responses_success({req, resp}) do
    body = ReqLLM.Provider.Utils.ensure_parsed_body(resp.body)

    output_segments = body["output"] || []

    text = aggregate_output_segments(body, output_segments)
    thinking = aggregate_reasoning_segments(output_segments)
    tool_calls = extract_tool_calls_from_segments(output_segments)

    base_usage = %{
      input_tokens: get_in(body, ["usage", "input_tokens"]) || 0,
      output_tokens: get_in(body, ["usage", "output_tokens"]) || 0,
      total_tokens:
        (get_in(body, ["usage", "input_tokens"]) || 0) +
          (get_in(body, ["usage", "output_tokens"]) || 0)
    }

    usage = normalize_responses_usage(base_usage, body)

    # Determine finish_reason, accounting for tool calls
    # The Responses API returns "completed" status even when tool calls are present
    finish_reason = determine_finish_reason(body, tool_calls)

    content_parts = build_content_parts(text, thinking)

    msg = %ReqLLM.Message{
      role: :assistant,
      content: content_parts,
      tool_calls: if(tool_calls != [], do: tool_calls),
      metadata: %{response_id: body["id"]}
    }

    {object, object_meta} = maybe_extract_object(req, text) || {nil, %{}}

    base_provider_meta = Map.drop(body, ["id", "model", "output_text", "output", "usage"])
    provider_meta = Map.merge(base_provider_meta, object_meta)

    response = %ReqLLM.Response{
      id: body["id"] || "unknown",
      model: body["model"] || req.options[:model],
      context: %ReqLLM.Context{
        messages: if(content_parts == [] and is_nil(msg.tool_calls), do: [], else: [msg])
      },
      message: msg,
      object: object,
      stream?: false,
      stream: nil,
      usage: usage,
      finish_reason: finish_reason,
      provider_meta: provider_meta
    }

    ctx = req.options[:context] || %ReqLLM.Context{messages: []}
    merged_response = %{response | context: ReqLLM.Context.append(ctx, msg)}

    {req, %{resp | body: merged_response}}
  end

  # Extract and validate structured object from json_schema responses
  defp maybe_extract_object(req, text) do
    case {req.options[:operation], text} do
      {:object, text} when is_binary(text) and text != "" ->
        compiled_schema = req.options[:compiled_schema]

        case Jason.decode(text) do
          {:ok, parsed_object} when is_map(parsed_object) ->
            case validate_object(parsed_object, compiled_schema) do
              {:ok, _} -> {parsed_object, %{}}
              {:error, reason} -> {nil, %{object_parse_error: reason}}
            end

          {:error, _} ->
            {nil, %{object_parse_error: :invalid_json}}

          _ ->
            {nil, %{object_parse_error: :not_an_object}}
        end

      {:object, _} ->
        {nil, %{}}

      _ ->
        nil
    end
  end

  defp validate_object(object, compiled_schema_result) when not is_nil(compiled_schema_result) do
    # compiled_schema_result is from Schema.compile/1 which returns %{schema: ..., compiled: ...}
    # Extract the actual compiled NimbleOptions schema, or handle map pass-through (compiled: nil)
    case compiled_schema_result do
      %{compiled: nil} ->
        # Map-based schema (JSON Schema pass-through), no validation
        {:ok, object}

      %{compiled: compiled} when not is_nil(compiled) ->
        # Convert string keys to atoms for validation
        keyword_data =
          object
          |> Enum.map(fn {k, v} ->
            key = if is_binary(k), do: String.to_existing_atom(k), else: k
            {key, v}
          end)

        case NimbleOptions.validate(keyword_data, compiled) do
          {:ok, _validated} -> {:ok, object}
          {:error, _} -> {:error, :validation_failed}
        end

      _ ->
        {:ok, object}
    end
  rescue
    ArgumentError ->
      # String keys don't exist as atoms
      {:error, :invalid_keys}
  end

  defp validate_object(object, nil), do: {:ok, object}

  defp aggregate_output_segments(body, segments) do
    texts = [
      body["output_text"],
      extract_from_message_segments(segments),
      extract_direct_output_text(segments)
    ]

    texts
    |> Enum.reject(&is_nil/1)
    |> Enum.join("")
  end

  defp extract_from_message_segments(segments) do
    segments
    |> Enum.filter(&(&1["type"] == "message"))
    |> Enum.flat_map(fn seg ->
      (seg["content"] || [])
      |> Enum.filter(&(&1["type"] in ["output_text", "text"]))
      |> Enum.map(&extract_text_field/1)
    end)
    |> Enum.join("")
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp extract_direct_output_text(segments) do
    segments
    |> Enum.filter(&(&1["type"] == "output_text"))
    |> Enum.map_join("", &extract_text_field/1)
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp extract_text_field(%{"text" => text}) when is_binary(text), do: text
  defp extract_text_field(%{"content" => content}) when is_binary(content), do: content
  defp extract_text_field(_), do: ""

  defp aggregate_reasoning_segments(segments) do
    reasoning_parts = [
      extract_reasoning_summary(segments),
      extract_reasoning_content(segments)
    ]

    reasoning_parts
    |> Enum.reject(&is_nil/1)
    |> Enum.join("")
  end

  defp extract_reasoning_summary(segments) do
    segments
    |> Enum.filter(&(&1["type"] == "reasoning"))
    |> Enum.map(& &1["summary"])
    |> Enum.reject(&is_nil/1)
    |> Enum.join("")
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp extract_reasoning_content(segments) do
    segments
    |> Enum.filter(&(&1["type"] == "reasoning"))
    |> Enum.flat_map(fn seg ->
      (seg["content"] || [])
      |> Enum.map(& &1["text"])
      |> Enum.reject(&is_nil/1)
    end)
    |> Enum.join("")
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp extract_tool_calls_from_segments(segments) do
    segments
    |> Enum.filter(&(&1["type"] == "function_call"))
    |> Enum.map(fn seg ->
      args_json = normalize_arguments_json(seg["arguments"])
      id = seg["call_id"] || seg["id"]
      name = seg["name"] || "unknown"
      ReqLLM.ToolCall.new(id, name, args_json)
    end)
  end

  defp normalize_arguments_json(nil), do: "{}"
  defp normalize_arguments_json(""), do: "{}"

  defp normalize_arguments_json(json) when is_binary(json) do
    trimmed = String.trim(json)

    case Jason.decode(trimmed) do
      {:ok, _} -> trimmed
      {:error, _} -> trimmed
    end
  end

  defp normalize_arguments_json(_), do: "{}"

  defp build_content_parts(text, thinking) do
    parts = []

    parts =
      if thinking == "" do
        parts
      else
        [%ReqLLM.Message.ContentPart{type: :thinking, text: thinking} | parts]
      end

    parts =
      if text == "" do
        parts
      else
        [%ReqLLM.Message.ContentPart{type: :text, text: text} | parts]
      end

    Enum.reverse(parts)
  end

  defp normalize_responses_usage(usage, response_data) do
    reasoning_tokens =
      get_in(response_data, ["usage", "reasoning_tokens"]) ||
        get_in(response_data, ["usage", "output_tokens_details", "reasoning_tokens"]) ||
        get_in(response_data, ["usage", "completion_tokens_details", "reasoning_tokens"]) || 0

    cached_tokens =
      get_in(response_data, ["usage", "input_tokens_details", "cached_tokens"]) ||
        get_in(response_data, ["usage", "prompt_tokens_details", "cached_tokens"]) || 0

    usage
    |> Map.put(:cached_tokens, cached_tokens)
    |> Map.put(:reasoning_tokens, reasoning_tokens)
  end

  # The Responses API returns "completed" status even when tool calls are present.
  # We need to check for tool calls and return :tool_calls in that case.
  defp determine_finish_reason(body, tool_calls) do
    case body["status"] do
      "completed" ->
        # If tool calls are present, return :tool_calls instead of :stop
        if tool_calls == [] do
          :stop
        else
          :tool_calls
        end

      "incomplete" ->
        reason = get_in(body, ["incomplete_details", "reason"]) || "length"
        normalize_finish_reason(reason)

      _ ->
        :stop
    end
  end

  defp normalize_finish_reason("stop"), do: :stop
  defp normalize_finish_reason("length"), do: :length
  defp normalize_finish_reason("max_tokens"), do: :length
  defp normalize_finish_reason("max_output_tokens"), do: :length
  defp normalize_finish_reason("tool_calls"), do: :tool_calls
  defp normalize_finish_reason("content_filter"), do: :content_filter
  defp normalize_finish_reason(_), do: :error

  @doc false
  def build_responses_body_from_chunks(chunks, model) do
    state =
      Enum.reduce(
        chunks,
        %{
          text: "",
          reasoning: "",
          tool_calls: %{},
          tool_call_order: [],
          usage: nil,
          finish_reason: nil,
          response_id: nil
        },
        &accumulate_chunk_to_state/2
      )

    output_segments = []

    output_segments =
      if state.reasoning == "" do
        output_segments
      else
        [
          %{
            "type" => "reasoning",
            "content" => [%{"type" => "text", "text" => state.reasoning}]
          }
          | output_segments
        ]
      end

    tool_segments =
      Enum.map(state.tool_call_order, fn key ->
        tc = state.tool_calls[key]

        %{
          "type" => "function_call",
          "id" => tc.id || "call_#{key}",
          "name" => tc.name || "unknown",
          "arguments" => tc.arguments || "{}"
        }
      end)

    output_segments = output_segments ++ tool_segments

    response_id = state.response_id || "resp_stream_#{System.unique_integer([:positive])}"

    body = %{
      "id" => response_id,
      "model" => model,
      "status" => if(state.finish_reason == :stop, do: "completed", else: "incomplete"),
      "output" => output_segments
    }

    body =
      if state.text == "" do
        body
      else
        Map.put(body, "output_text", state.text)
      end

    body =
      if state.usage do
        Map.put(body, "usage", state.usage)
      else
        body
      end

    body
  end

  defp accumulate_chunk_to_state(%ReqLLM.StreamChunk{type: :content, text: text}, state) do
    %{state | text: state.text <> text}
  end

  defp accumulate_chunk_to_state(%ReqLLM.StreamChunk{type: :thinking, text: text}, state) do
    %{state | reasoning: state.reasoning <> text}
  end

  defp accumulate_chunk_to_state(%ReqLLM.StreamChunk{type: :tool_call} = chunk, state) do
    # Get tool call ID from metadata
    tool_id = chunk.metadata[:id] || chunk.metadata[:call_id]
    key = chunk.metadata[:index] || tool_id || 0

    existing = Map.get(state.tool_calls, key, %{})

    updated = %{
      id: tool_id || existing[:id],
      name: chunk.name || existing[:name],
      arguments: merge_tool_arguments(existing[:arguments], chunk.arguments)
    }

    order =
      if key in state.tool_call_order,
        do: state.tool_call_order,
        else: state.tool_call_order ++ [key]

    %{state | tool_calls: Map.put(state.tool_calls, key, updated), tool_call_order: order}
  end

  defp accumulate_chunk_to_state(%ReqLLM.StreamChunk{type: :meta, metadata: meta}, state) do
    state
    |> maybe_put_usage(meta[:usage])
    |> maybe_put_finish(meta[:finish_reason])
    |> maybe_put_response_id(meta[:response_id])
  end

  defp accumulate_chunk_to_state(_chunk, state), do: state

  defp merge_tool_arguments(nil, new), do: new
  defp merge_tool_arguments(existing, nil), do: existing

  defp merge_tool_arguments(existing, new) when is_binary(existing) and is_binary(new) do
    existing <> new
  end

  defp merge_tool_arguments(existing, new) when is_map(new) do
    merge_tool_arguments(existing, Jason.encode!(new))
  end

  defp merge_tool_arguments(existing, _new), do: existing

  defp maybe_put_usage(state, nil), do: state

  defp maybe_put_usage(state, usage) do
    normalized =
      Map.update(
        usage,
        :reasoning_tokens,
        usage[:reasoning] || usage[:thinking_tokens] || 0,
        & &1
      )

    %{state | usage: normalized}
  end

  defp maybe_put_finish(state, nil), do: state
  defp maybe_put_finish(state, reason), do: %{state | finish_reason: reason}

  defp maybe_put_response_id(state, nil), do: state
  defp maybe_put_response_id(state, id), do: %{state | response_id: id}
end
