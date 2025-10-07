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

  @impl true
  def path, do: "/responses"

  @impl true
  def encode_body(request) do
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

    tools = encode_tools_if_any(request) |> ensure_deep_research_tools(request)
    tool_choice = encode_tool_choice(request.options[:tool_choice])
    reasoning = encode_reasoning_effort(provider_opts[:reasoning_effort])

    body =
      Map.new()
      |> Map.put("model", request.options[:model])
      |> Map.put("input", input)
      |> maybe_put_string("stream", request.options[:stream])
      |> maybe_put_string("max_output_tokens", max_output_tokens)
      |> maybe_put_string("tools", tools)
      |> maybe_put_string("tool_choice", tool_choice)
      |> maybe_put_string("reasoning", reasoning)

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
  def decode_sse_event(%{data: "[DONE]"}, _model) do
    [ReqLLM.StreamChunk.meta(%{terminal?: true})]
  end

  def decode_sse_event(%{data: data} = event, model) when is_map(data) do
    event_type =
      Map.get(event, :event) || Map.get(event, "event") || data["event"] || data["type"]

    if System.get_env("REQ_LLM_DEBUG") do
      require Logger

      Logger.debug(
        "ResponsesAPI decode_sse_event: event=#{inspect(Map.keys(event))}, event_type=#{inspect(event_type)}"
      )
    end

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

        [ReqLLM.StreamChunk.meta(%{usage: usage, model: model.model})]

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

        meta = %{terminal?: true, finish_reason: :stop}

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

  def decode_sse_event(_event, _model), do: []

  @impl true
  def attach_stream(model, context, opts, _finch_name) do
    api_key = ReqLLM.Keys.get!(model, opts)

    headers = [
      {"Authorization", "Bearer " <> api_key},
      {"Content-Type", "application/json"},
      {"Accept", "text/event-stream"}
    ]

    url =
      case Keyword.get(opts, :base_url) do
        nil -> ReqLLM.Providers.OpenAI.default_base_url() <> path()
        base_url -> "#{base_url}#{path()}"
      end

    provider_opts = opts |> Keyword.get(:provider_options, []) |> Map.new()

    cleaned_opts =
      opts
      |> Keyword.delete(:finch_name)
      |> Keyword.delete(:compiled_schema)
      |> Keyword.delete(:provider_options)

    req_opts =
      [
        model: model.model,
        context: context,
        stream: true,
        responses_api: true,
        provider_options: provider_opts
      ] ++ cleaned_opts

    options =
      req_opts
      |> Enum.reduce(%{}, fn
        {key, value}, acc when is_list(value) ->
          Map.put(acc, key, Map.new(value))

        {key, value}, acc ->
          Map.put(acc, key, value)
      end)

    temp_request = %Req.Request{
      method: :post,
      url: URI.parse("https://example.com/temp"),
      headers: %{},
      body: {:json, %{}},
      options: options
    }

    encoded_request = encode_body(temp_request)
    body = encoded_request.body

    {:ok, Finch.build(:post, url, headers, body)}
  rescue
    error ->
      {:error,
       ReqLLM.Error.API.Request.exception(
         reason: "Failed to build Responses API streaming request: #{Exception.message(error)}"
       )}
  end

  defp handle_function_call_delta(%{"delta" => delta} = data) when is_map(delta) do
    index = data["index"] || 0
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
    index = data["index"] || 0

    [
      ReqLLM.StreamChunk.meta(%{
        tool_call_args: %{index: index, fragment: fragment}
      })
    ]
  end

  defp handle_function_call_arguments_delta(_), do: []

  defp handle_function_call_name_delta(%{"delta" => name} = data)
       when is_binary(name) and name != "" do
    index = data["index"] || 0
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

  defp encode_tools_if_any(request) do
    case request.options[:tools] do
      nil -> nil
      [] -> nil
      tools -> Enum.map(tools, &encode_tool_for_responses_api/1)
    end
  end

  defp ensure_deep_research_tools(tools, request) do
    model_name = request.options[:model]

    case ReqLLM.Model.from("openai:#{model_name}") do
      {:ok, model} ->
        category = get_in(model, [Access.key(:_metadata, %{}), "category"])

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

    %{
      "name" => function_def["name"],
      "type" => "function",
      "function" => function_def
    }
  end

  defp encode_tool_for_responses_api(tool_schema) when is_map(tool_schema) do
    function_def = tool_schema["function"] || tool_schema[:function]

    %{
      "name" => function_def["name"] || function_def[:name],
      "type" => "function",
      "function" => function_def
    }
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

    finish_reason = determine_finish_reason(body)

    content_parts = build_content_parts(text, thinking, tool_calls)

    msg = %ReqLLM.Message{
      role: :assistant,
      content: content_parts
    }

    response = %ReqLLM.Response{
      id: body["id"] || "unknown",
      model: body["model"] || req.options[:model],
      context: %ReqLLM.Context{messages: if(content_parts == [], do: [], else: [msg])},
      message: msg,
      stream?: false,
      stream: nil,
      usage: usage,
      finish_reason: finish_reason,
      provider_meta: Map.drop(body, ["id", "model", "output_text", "output", "usage"])
    }

    ctx = req.options[:context] || %ReqLLM.Context{messages: []}
    merged_response = %{response | context: ReqLLM.Context.append(ctx, msg)}

    {req, %{resp | body: merged_response}}
  end

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
      args =
        case Jason.decode(seg["arguments"] || "{}") do
          {:ok, decoded} -> decoded
          {:error, _} -> %{}
        end

      %ReqLLM.Message.ContentPart{
        type: :tool_call,
        tool_call_id: seg["call_id"] || "unknown",
        tool_name: seg["name"] || "unknown",
        input: args
      }
    end)
  end

  defp build_content_parts(text, thinking, tool_calls) do
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

    Enum.reverse(parts, tool_calls)
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

  defp determine_finish_reason(body) do
    case body["status"] do
      "completed" ->
        :stop

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
end
