defmodule ReqLLM.Providers.AmazonBedrock.Converse do
  @moduledoc """
  AWS Bedrock Converse API support for unified tool calling across models.

  The Converse API provides a standardized interface for tool calling that works
  across all Bedrock models (Anthropic, OpenAI, Meta, etc.) with consistent
  request/response formats.

  ## Advantages

  - Unified tool calling across all Bedrock models
  - Simpler, cleaner API compared to model-specific endpoints
  - Better multi-turn conversation handling

  ## Disadvantages

  - May lag behind model-specific endpoints for cutting-edge features
  - Adds small translation overhead (typically low milliseconds)

  ## API Format

  Request:
  ```json
  {
    "messages": [
      {"role": "user", "content": [{"text": "Hello"}]}
    ],
    "system": [{"text": "You are a helpful assistant"}],
    "inferenceConfig": {
      "maxTokens": 1000,
      "temperature": 0.7
    },
    "toolConfig": {
      "tools": [
        {
          "toolSpec": {
            "name": "get_weather",
            "description": "Get weather",
            "inputSchema": {
              "json": {
                "type": "object",
                "properties": {...},
                "required": [...]
              }
            }
          }
        }
      ]
    }
  }
  ```

  Response:
  ```json
  {
    "output": {
      "message": {
        "role": "assistant",
        "content": [
          {"text": "Let me check the weather"},
          {
            "toolUse": {
              "toolUseId": "id123",
              "name": "get_weather",
              "input": {"location": "SF"}
            }
          }
        ]
      }
    },
    "stopReason": "tool_use",
    "usage": {
      "inputTokens": 100,
      "outputTokens": 50,
      "totalTokens": 150
    }
  }
  ```
  """

  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Message.ReasoningDetails
  alias ReqLLM.ToolCall

  @reasoning_format "bedrock-converse-v1"
  @replayable_reasoning_providers [:amazon_bedrock, :anthropic]

  @image_formats ~w(png jpeg gif webp)
  @video_formats ~w(mkv mov mp4 webm flv mpeg mpg wmv three_gp)
  @format_aliases %{
    "jpg" => "jpeg",
    "quicktime" => "mov",
    "x-matroska" => "mkv",
    "matroska" => "mkv",
    "x-flv" => "flv",
    "x-ms-wmv" => "wmv",
    "3gpp" => "three_gp",
    "3gp" => "three_gp",
    "plain" => "txt",
    "markdown" => "md",
    "htm" => "html",
    "msword" => "doc",
    "vnd.openxmlformats-officedocument.wordprocessingml.document" => "docx",
    "vnd.ms-excel" => "xls",
    "vnd.openxmlformats-officedocument.spreadsheetml.sheet" => "xlsx"
  }

  @doc """
  Format a ReqLLM context into Bedrock Converse API format.

  Converts ReqLLM messages and tools into the Converse API request structure.

  For :object operations, creates a synthetic "structured_output" tool to
  leverage unified tool calling for structured JSON output across all models.
  """
  def format_request(_model_id, context, opts) do
    operation = opts[:operation]

    # For :object operation, inject the structured_output tool
    {context, opts} =
      if operation == :object do
        prepare_structured_output_context(context, opts)
      else
        {context, opts}
      end

    context =
      ReqLLM.ToolCallIdCompat.apply_context_with_policy(
        context,
        %{
          mode: :sanitize,
          invalid_chars_regex: ~r/[^A-Za-z0-9_-]/,
          max_length: 64,
          enforce_turn_boundary: true
        },
        opts
      )

    request = %{}

    # Add messages
    request = add_messages(request, context.messages)

    # Add tools if present (tools are in opts, not context)
    # Add tools from opts or persisted from context
    request =
      case opts[:tools] do
        nil ->
          # Use persisted tools from context if available
          case Map.get(context, :tools) do
            tools when is_list(tools) and tools != [] ->
              add_tools(request, tools, opts[:formatter_module])

            _ ->
              # No tools
              request
          end

        tools when is_list(tools) ->
          add_tools(request, tools, opts[:formatter_module])
      end

    # Add tool choice if specified
    # Note: Only some model families support toolChoice in Converse API
    request =
      if tool_choice = opts[:tool_choice] do
        add_tool_choice(request, tool_choice, opts[:model_family], opts[:formatter_module])
      else
        request
      end

    # Add inference config
    request = add_inference_config(request, opts)

    # Add additionalModelRequestFields for model-specific features (e.g., Claude extended thinking)
    request = add_additional_fields(request, opts)

    add_guardrail_config(request, opts)
  end

  # Create the synthetic structured_output tool for :object operations
  defp prepare_structured_output_context(context, opts) do
    compiled_schema = Keyword.fetch!(opts, :compiled_schema)

    # Create the structured_output tool (same as native Anthropic provider)
    structured_output_tool =
      ReqLLM.Tool.new!(
        name: "structured_output",
        description: "Generate structured output matching the provided schema",
        parameter_schema: compiled_schema.schema,
        callback: fn _args -> {:ok, "structured output generated"} end
      )

    # Add tool to context - Context may or may not have a tools field
    existing_tools = Map.get(context, :tools, [])
    updated_context = Map.put(context, :tools, [structured_output_tool | existing_tools])

    # Update opts to force tool choice
    # Handle case where opts[:tools] is explicitly nil (Keyword.get returns nil, not default)
    existing_tools = Keyword.get(opts, :tools) || []

    updated_opts =
      opts
      |> Keyword.put(:tools, [structured_output_tool | existing_tools])
      |> Keyword.put(:tool_choice, %{type: "tool", name: "structured_output"})

    {updated_context, updated_opts}
  end

  @doc """
  Parse a Converse API response into ReqLLM format.

  Converts Converse API response structure back to ReqLLM.Response with
  proper Message and ContentPart structures.

  For :object operations, extracts the structured output from the tool call.
  """
  def parse_response(response_body, opts) do
    message_data = get_in(response_body, ["output", "message"])
    stop_reason = response_body["stopReason"]
    usage = response_body["usage"]

    # Parse message (includes reasoning content if present)
    message = parse_message(message_data)

    # Build initial response with minimal context
    initial_response = %ReqLLM.Response{
      id: get_in(response_body, ["output", "messageId"]) || "unknown",
      model: opts[:model] || "bedrock-converse",
      context: %ReqLLM.Context{messages: []},
      message: message,
      finish_reason: map_stop_reason(stop_reason),
      usage: parse_usage(usage),
      provider_meta: response_provider_meta(response_body),
      stream?: false
    }

    # Merge with original context, persisting tools
    original_context = opts[:context] || %ReqLLM.Context{messages: []}
    merge_opts = [tools: opts[:tools]]
    response = ReqLLM.Context.merge_response(original_context, initial_response, merge_opts)

    # For :object operation, extract structured output from tool call
    final_response =
      if opts[:operation] == :object do
        extract_and_set_object(response, opts)
      else
        response
      end

    {:ok, final_response}
  end

  # Extract structured output from tool call (same logic as native Anthropic provider)
  defp extract_and_set_object(response, opts) do
    extracted_object =
      response
      |> ReqLLM.Response.tool_calls()
      |> ReqLLM.ToolCall.find_args("structured_output", opts)

    %{response | object: extracted_object}
  end

  def init_stream_state, do: %{reasoning_blocks: %{}, next_reasoning_index: 0}

  @doc "Emits `reasoning_details` when a reasoning block receives `contentBlockStop`."
  def decode_stream_event(event, nil), do: decode_stream_event(event, init_stream_state())

  def decode_stream_event(%{"contentBlockDelta" => delta_data} = event, state) do
    index = delta_data["contentBlockIndex"]

    case get_in(delta_data, ["delta", "reasoningContent"]) do
      %{"text" => text} when is_binary(text) ->
        chunks = if text == "", do: [], else: [ReqLLM.StreamChunk.thinking(text)]
        {chunks, append_reasoning(state, index, :text, text)}

      %{"signature" => signature} when is_binary(signature) ->
        {[], append_reasoning(state, index, :signature, signature)}

      %{"redactedContent" => data} when is_binary(data) ->
        {[], append_reasoning(state, index, :redacted, data)}

      _ ->
        {stateless_chunks(event), state}
    end
  end

  def decode_stream_event(%{"contentBlockStop" => %{"contentBlockIndex" => index}}, state) do
    case Map.pop(state.reasoning_blocks, index) do
      {nil, _blocks} ->
        {[], state}

      {block, blocks} ->
        detail = reasoning_detail(block, state.next_reasoning_index)

        {[ReqLLM.StreamChunk.meta(%{reasoning_details: [detail]})],
         %{state | reasoning_blocks: blocks, next_reasoning_index: state.next_reasoning_index + 1}}
    end
  end

  def decode_stream_event(event, state), do: {stateless_chunks(event), state}

  @doc "Emit reasoning details for blocks that never received a `contentBlockStop`."
  def flush_stream_state(nil), do: {[], init_stream_state()}

  def flush_stream_state(state) do
    state.reasoning_blocks
    |> Enum.sort_by(fn {index, _block} -> index end)
    |> Enum.map_reduce(%{state | reasoning_blocks: %{}}, fn {_index, block}, acc ->
      {reasoning_detail(block, acc.next_reasoning_index),
       %{acc | next_reasoning_index: acc.next_reasoning_index + 1}}
    end)
    |> case do
      {[], state} -> {[], state}
      {details, state} -> {[ReqLLM.StreamChunk.meta(%{reasoning_details: details})], state}
    end
  end

  defp stateless_chunks(event) do
    case parse_stream_chunk(event, %{}) do
      {:ok, nil} -> []
      {:ok, chunk} -> [chunk]
      {:error, _} -> []
    end
  end

  defp append_reasoning(state, index, key, value) do
    block = Map.get(state.reasoning_blocks, index, %{text: "", signature: nil, redacted: nil})

    block =
      case key do
        :text -> %{block | text: block.text <> value}
        :signature -> %{block | signature: append_fragment(block.signature, value)}
        :redacted -> %{block | redacted: append_redacted_fragment(block.redacted, value)}
      end

    %{state | reasoning_blocks: Map.put(state.reasoning_blocks, index, block)}
  end

  defp append_fragment(nil, value), do: value
  defp append_fragment(existing, value), do: existing <> value

  defp append_redacted_fragment(nil, value), do: value

  defp append_redacted_fragment(existing, value) do
    case {Base.decode64(existing), Base.decode64(value)} do
      {{:ok, existing_bytes}, {:ok, value_bytes}} ->
        Base.encode64(existing_bytes <> value_bytes)

      _ ->
        existing <> value
    end
  end

  defp reasoning_detail(%{redacted: data}, index) when is_binary(data) do
    %ReasoningDetails{
      encrypted?: true,
      provider: :amazon_bedrock,
      format: @reasoning_format,
      index: index,
      provider_data: %{"redactedContent" => data}
    }
  end

  defp reasoning_detail(%{text: text, signature: signature}, index) do
    %ReasoningDetails{
      text: text,
      signature: signature,
      encrypted?: signature != nil,
      provider: :amazon_bedrock,
      format: @reasoning_format,
      index: index
    }
  end

  @doc """
  Parse a Converse API streaming chunk.

  Handles different event types from the Converse stream.
  Events are already decoded by AWSEventStream.parse_binary before reaching this function.
  """
  def parse_stream_chunk(chunk, _model_id) do
    case chunk do
      %{"contentBlockStart" => start_data} ->
        # Start of a new content block
        # For tool use blocks, emit tool_call chunk with empty arguments
        if tool_use_start = get_in(start_data, ["start", "toolUse"]) do
          tool_name = tool_use_start["name"]
          tool_use_id = tool_use_start["toolUseId"]
          content_block_index = start_data["contentBlockIndex"]

          # Send empty tool_call that will be filled by deltas
          {:ok,
           ReqLLM.StreamChunk.tool_call(tool_name, %{}, %{
             id: tool_use_id,
             index: content_block_index,
             start: true
           })}
        else
          {:ok, nil}
        end

      %{"contentBlockDelta" => delta_data} ->
        # Handle text, reasoning, and tool use deltas
        cond do
          delta = get_in(delta_data, ["delta", "text"]) ->
            {:ok, ReqLLM.StreamChunk.text(delta)}

          reasoning_delta = get_in(delta_data, ["delta", "reasoningContent"]) ->
            # Claude extended thinking reasoning delta
            # reasoningContent is a map with "text" key, extract it
            case reasoning_delta["text"] do
              text when is_binary(text) and text != "" ->
                {:ok, ReqLLM.StreamChunk.thinking(text)}

              _ ->
                # Empty or missing text, skip this chunk
                {:ok, nil}
            end

          tool_use_delta = get_in(delta_data, ["delta", "toolUse"]) ->
            # Tool use delta for object generation
            # The input field contains the streaming JSON fragment
            if input = tool_use_delta["input"] do
              content_block_index = delta_data["contentBlockIndex"]
              # Emit metadata chunk with JSON fragment to be accumulated
              {:ok,
               ReqLLM.StreamChunk.meta(%{
                 tool_call_args: %{index: content_block_index, fragment: input}
               })}
            else
              {:ok, nil}
            end

          true ->
            {:ok, nil}
        end

      %{"contentBlockStop" => _data} ->
        # End of content block
        {:ok, nil}

      %{"messageStart" => _data} ->
        # Start of message
        {:ok, nil}

      %{"messageStop" => stop_data} ->
        # End of message with stop reason
        stop_reason = stop_data["stopReason"]
        {:ok, ReqLLM.StreamChunk.meta(%{finish_reason: map_stop_reason(stop_reason)})}

      %{"metadata" => metadata} ->
        meta =
          %{}
          |> maybe_put_usage(metadata["usage"])
          |> maybe_put_trace(metadata["trace"])

        if meta == %{}, do: {:ok, nil}, else: {:ok, ReqLLM.StreamChunk.meta(meta)}

      _ ->
        {:error, :unknown_chunk_type}
    end
  end

  # Private functions

  defp response_provider_meta(%{"trace" => trace}) when is_map(trace), do: %{trace: trace}
  defp response_provider_meta(_response_body), do: %{}

  defp maybe_put_usage(meta, nil), do: meta
  defp maybe_put_usage(meta, usage), do: Map.put(meta, :usage, parse_usage(usage))

  defp maybe_put_trace(meta, trace) when is_map(trace),
    do: Map.put(meta, :provider_meta, %{trace: trace})

  defp maybe_put_trace(meta, _trace), do: meta

  defp add_messages(request, messages) do
    {system_messages, non_system_messages} =
      Enum.split_with(messages, fn %Message{role: role} -> role == :system end)

    request =
      case encode_system_messages(system_messages) do
        [] ->
          request

        encoded_system ->
          Map.put(request, "system", encoded_system)
      end

    encoded_messages =
      non_system_messages
      |> Enum.map(&encode_message/1)
      |> Enum.reject(&is_nil/1)
      |> merge_consecutive_tool_results()

    Map.put(request, "messages", encoded_messages)
  end

  defp encode_system_messages(messages) do
    messages
    |> Enum.map(&encode_system_message/1)
    |> Enum.reject(&(&1 == []))
    |> Enum.intersperse([%{"text" => "\n\n"}])
    |> List.flatten()
  end

  defp encode_system_message(%Message{content: content}) when is_binary(content) do
    encode_content(content)
  end

  defp encode_system_message(%Message{content: content}) when is_list(content) do
    encode_content(content)
  end

  defp encode_system_message(_message), do: []

  defp merge_consecutive_tool_results(messages) do
    messages
    |> Enum.reduce([], fn msg, acc ->
      case {acc, msg} do
        {[%{"role" => "user", "content" => prev_content} = prev | rest],
         %{"role" => "user", "content" => curr_content}}
        when is_list(prev_content) and is_list(curr_content) ->
          if all_tool_results?(prev_content) and all_tool_results?(curr_content) do
            [%{prev | "content" => prev_content ++ curr_content} | rest]
          else
            [msg | acc]
          end

        _ ->
          [msg | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp all_tool_results?(content) when is_list(content) do
    Enum.all?(content, fn
      %{"toolResult" => _} -> true
      _ -> false
    end)
  end

  defp add_tools(request, [], _formatter_module), do: request

  defp add_tools(request, tools, formatter_module) when is_list(tools) do
    tool_specs =
      tools
      |> Enum.reject(&is_nil/1)
      |> Enum.map(fn tool ->
        bedrock_tool = ReqLLM.Schema.to_bedrock_converse_format(tool)

        # Some model families need to normalize tool schemas
        # Check if formatter module provides normalization
        if formatter_module &&
             function_exported?(formatter_module, :normalize_tool_schema, 1) do
          # Normalize the inputSchema.json field
          update_in(
            bedrock_tool,
            ["toolSpec", "inputSchema", "json"],
            &formatter_module.normalize_tool_schema/1
          )
        else
          bedrock_tool
        end
      end)

    Map.put(request, "toolConfig", %{
      "tools" => tool_specs
    })
  end

  # Add tool choice configuration to force specific tool usage
  # Only supported by some model families - check with the formatter module
  defp add_tool_choice(request, tool_choice, _model_family, formatter_module) do
    # Ask the model family formatter if it supports toolChoice in Converse API
    supports_tool_choice =
      formatter_module &&
        function_exported?(formatter_module, :supports_converse_tool_choice?, 0) &&
        formatter_module.supports_converse_tool_choice?()

    if supports_tool_choice do
      # Converse API uses toolChoice in toolConfig
      existing_tool_config = Map.get(request, "toolConfig", %{})

      # Convert from Anthropic format to Converse format
      tool_choice_config =
        case tool_choice do
          %{type: "tool", name: name} ->
            # Force specific tool
            %{"tool" => %{"name" => name}}

          %{type: "any"} ->
            # Force any tool (must use a tool)
            %{"any" => %{}}

          %{type: "auto"} ->
            # Auto decide (default)
            %{"auto" => %{}}

          _ ->
            # Unknown format, use auto
            %{"auto" => %{}}
        end

      updated_tool_config = Map.put(existing_tool_config, "toolChoice", tool_choice_config)
      Map.put(request, "toolConfig", updated_tool_config)
    else
      # For non-Anthropic models, skip toolChoice entirely
      request
    end
  end

  defp add_inference_config(request, opts) do
    config = %{}

    config =
      if max_tokens = opts[:max_tokens] do
        Map.put(config, "maxTokens", max_tokens)
      else
        config
      end

    config =
      if temperature = opts[:temperature] do
        Map.put(config, "temperature", temperature)
      else
        config
      end

    config =
      if top_p = opts[:top_p] do
        Map.put(config, "topP", top_p)
      else
        config
      end

    config =
      if stop_sequences = opts[:stop_sequences] do
        Map.put(config, "stopSequences", stop_sequences)
      else
        config
      end

    if config == %{} do
      request
    else
      Map.put(request, "inferenceConfig", config)
    end
  end

  defp add_additional_fields(request, opts) do
    # Check both locations: top-level opts and provider_options
    # (after Options.process, fields are in provider_options)
    fields =
      opts[:additional_model_request_fields] ||
        get_in(opts, [:provider_options, :additional_model_request_fields])

    case fields do
      nil -> request
      fields when is_map(fields) -> Map.put(request, "additionalModelRequestFields", fields)
      _ -> request
    end
  end

  defp add_guardrail_config(request, opts) do
    opts = Keyword.merge(opts, opts[:provider_options] || [])

    case opts[:guardrail_identifier] do
      nil ->
        request

      identifier ->
        version =
          opts[:guardrail_version] ||
            raise ArgumentError, "guardrail_version is required when guardrail_identifier is set"

        config = %{"guardrailIdentifier" => identifier, "guardrailVersion" => version}

        config =
          case opts[:guardrail_trace] do
            nil -> config
            trace -> Map.put(config, "trace", trace)
          end

        Map.put(request, "guardrailConfig", config)
    end
  end

  # Assistant message with tool calls (new ToolCall pattern)
  defp encode_message(%Message{role: :assistant, tool_calls: tool_calls, content: content} = msg)
       when is_list(tool_calls) and tool_calls != [] do
    tool_blocks = Enum.map(tool_calls, &encode_tool_call_to_tool_use/1)

    %{
      "role" => "assistant",
      "content" => encode_reasoning_details(msg) ++ encode_content(content) ++ tool_blocks
    }
  end

  # Tool result message (new ToolCall pattern)
  defp encode_message(%Message{role: :tool, tool_call_id: id} = msg) do
    %{
      "role" => "user",
      "content" => [
        %{
          "toolResult" => %{
            "toolUseId" => id,
            "content" => encode_tool_result_content(msg)
          }
        }
      ]
    }
  end

  # Regular message (user, assistant, system) — returns nil if content is
  # empty after filtering, so the caller can reject it like empty ContentParts.
  defp encode_message(%Message{role: role, content: content} = msg) do
    case encode_reasoning_details(msg) ++ encode_content(content) do
      [] -> nil
      encoded -> %{"role" => Atom.to_string(role), "content" => encoded}
    end
  end

  defp encode_reasoning_details(%Message{role: :assistant, reasoning_details: details})
       when is_list(details) do
    details
    |> Enum.filter(&(&1.provider in @replayable_reasoning_providers))
    |> Enum.sort_by(& &1.index)
    |> Enum.flat_map(&encode_reasoning_detail/1)
  end

  defp encode_reasoning_details(_msg), do: []

  defp encode_reasoning_detail(%{provider_data: %{"redactedContent" => data}})
       when is_binary(data),
       do: [%{"reasoningContent" => %{"redactedContent" => data}}]

  defp encode_reasoning_detail(%{text: text, signature: signature})
       when is_binary(text) and is_binary(signature),
       do: [
         %{
           "reasoningContent" => %{"reasoningText" => %{"text" => text, "signature" => signature}}
         }
       ]

  defp encode_reasoning_detail(_detail), do: []

  defp encode_content(content) when is_binary(content) do
    [%{"text" => content}]
  end

  defp encode_content(content) when is_list(content) do
    content
    |> Enum.map(&encode_content_part/1)
    |> Enum.reject(&is_nil/1)
  end

  defp encode_content_part(%ContentPart{type: :text, text: ""}), do: nil

  defp encode_content_part(%ContentPart{type: :text, text: text}) do
    %{"text" => text}
  end

  defp encode_content_part(%ContentPart{type: :thinking}), do: nil

  defp encode_content_part(%ContentPart{} = part) do
    format = media_format(part)
    block = block_type(format)
    %{block => media_block(block, part, format)}
  end

  defp block_type(format) when format in @image_formats, do: "image"
  defp block_type(format) when format in @video_formats, do: "video"
  defp block_type(_format), do: "document"

  defp media_block("document", part, format) do
    source = encode_source(part)

    %{"name" => document_name(part), "format" => format, "source" => source}
    |> put_document_context(part)
  end

  defp media_block(_block, part, format),
    do: %{"format" => format, "source" => encode_source(part)}

  defp media_format(%ContentPart{media_type: media_type, filename: filename, url: url})
       when media_type in [nil, "application/octet-stream"] do
    (filename || url || "")
    |> Path.extname()
    |> String.trim_leading(".")
    |> String.downcase()
    |> canonical_format()
  end

  defp media_format(%ContentPart{media_type: media_type}) do
    [mime | _params] = String.split(media_type, ";")
    [_type, subtype] = mime |> String.trim() |> String.split("/", parts: 2)
    canonical_format(subtype)
  end

  defp canonical_format(format), do: Map.get(@format_aliases, format, format)

  defp encode_source(%ContentPart{data: data}) when is_binary(data),
    do: %{"bytes" => Base.encode64(data)}

  defp encode_source(%ContentPart{url: "s3://" <> _ = uri, metadata: metadata}) do
    case metadata_value(metadata, :bucket_owner) do
      nil -> %{"s3Location" => %{"uri" => uri}}
      owner -> %{"s3Location" => %{"uri" => uri, "bucketOwner" => owner}}
    end
  end

  defp encode_source(%ContentPart{url: url}) when is_binary(url),
    do: invalid_part("Converse reads s3:// URLs only, got #{url}")

  defp encode_source(%ContentPart{file_id: file_id}) when is_binary(file_id),
    do: invalid_part("Converse cannot read provider file ids")

  defp document_name(%ContentPart{filename: filename, metadata: metadata}) do
    (metadata_value(metadata, :title) || filename_stem(filename))
    |> String.replace(~r/[^A-Za-z0-9 \-()\[\]]+/, " ")
    |> String.replace(~r/ +/, " ")
    |> String.slice(0, 200)
    |> String.trim()
  end

  defp filename_stem(nil), do: ""
  defp filename_stem(filename), do: filename |> Path.basename() |> Path.rootname()

  defp put_document_context(block, %ContentPart{metadata: metadata}) do
    case metadata_value(metadata, :context) do
      nil -> block
      context -> Map.put(block, "context", context)
    end
  end

  defp metadata_value(metadata, key) when is_map(metadata),
    do: Map.get(metadata, key, Map.get(metadata, Atom.to_string(key)))

  defp invalid_part(parameter), do: raise(ReqLLM.Error.Invalid.Parameter, parameter: parameter)

  # Helper to encode ToolCall struct to Converse API toolUse format
  defp encode_tool_call_to_tool_use(%ToolCall{id: id, function: %{name: name, arguments: args}}) do
    %{
      "toolUse" => %{
        "toolUseId" => id,
        "name" => name,
        "input" => Jason.decode!(args)
      }
    }
  end

  defp encode_tool_call_to_tool_use(%{id: id, name: name, arguments: args}) do
    %{
      "toolUse" => %{
        "toolUseId" => id,
        "name" => name,
        "input" => decode_tool_arguments(args)
      }
    }
  end

  defp encode_tool_call_to_tool_use(%{"id" => id, "name" => name, "arguments" => args}) do
    %{
      "toolUse" => %{
        "toolUseId" => id,
        "name" => name,
        "input" => decode_tool_arguments(args)
      }
    }
  end

  defp decode_tool_arguments(args) when is_binary(args), do: Jason.decode!(args)
  defp decode_tool_arguments(args) when is_map(args), do: args
  defp decode_tool_arguments(nil), do: %{}

  # Helper to extract text content from content parts
  defp extract_text_content(content) when is_binary(content), do: content

  defp extract_text_content(content) when is_list(content) do
    content
    |> Enum.find_value(fn
      %ContentPart{type: :text, text: text} -> text
      _ -> nil
    end)
    |> case do
      nil -> ""
      text -> text
    end
  end

  defp extract_text_content(_), do: ""

  defp encode_tool_result_content(%Message{content: content})
       when is_list(content) and content != [] do
    encode_content(content)
  end

  defp encode_tool_result_content(%Message{} = msg) do
    text = extract_tool_result_text(msg)
    [%{"text" => text}]
  end

  defp extract_tool_result_text(%Message{content: content} = msg) do
    text = extract_text_content(content)
    output = ReqLLM.ToolResult.output_from_message(msg)

    cond do
      text != "" -> text
      output == nil -> ""
      true -> encode_tool_output(output)
    end
  end

  defp encode_tool_output(output) when is_binary(output), do: output

  defp encode_tool_output(output) when is_map(output) or is_list(output),
    do: Jason.encode!(output)

  defp encode_tool_output(output), do: to_string(output)

  defp parse_message(nil), do: nil

  defp parse_message(message_data) do
    role = parse_role(message_data["role"])
    content_blocks = message_data["content"] || []

    # Separate tool calls from regular content
    {tool_calls, content_parts} = parse_content_with_tool_calls(content_blocks)

    message = %Message{
      role: role,
      content: content_parts,
      reasoning_details: parse_reasoning_details(content_blocks)
    }

    if tool_calls == [] do
      message
    else
      %{message | tool_calls: tool_calls}
    end
  end

  defp parse_reasoning_details(content_blocks) do
    content_blocks
    |> Enum.flat_map(fn
      %{"reasoningContent" => %{"reasoningText" => %{"text" => text} = reasoning}} ->
        [%{text: text, signature: reasoning["signature"], redacted: nil}]

      %{"reasoningContent" => %{"redactedContent" => data}} ->
        [%{text: nil, signature: nil, redacted: data}]

      _ ->
        []
    end)
    |> Enum.with_index(&reasoning_detail/2)
    |> case do
      [] -> nil
      details -> details
    end
  end

  defp parse_role("user"), do: :user
  defp parse_role("assistant"), do: :assistant
  defp parse_role("system"), do: :system
  defp parse_role("tool"), do: :tool
  defp parse_role(_), do: :assistant

  # Parse content and separate tool calls from regular content
  defp parse_content_with_tool_calls(content_blocks) when is_list(content_blocks) do
    Enum.reduce(content_blocks, {[], []}, fn block, {tool_calls, content_parts} ->
      case block do
        %{"toolUse" => tool_use} ->
          # Convert to ToolCall struct
          tool_call =
            ToolCall.new(
              tool_use["toolUseId"],
              tool_use["name"],
              Jason.encode!(tool_use["input"])
            )

          {[tool_call | tool_calls], content_parts}

        _ ->
          # Parse as regular content part
          if part = parse_content_block(block) do
            {tool_calls, [part | content_parts]}
          else
            {tool_calls, content_parts}
          end
      end
    end)
    |> then(fn {tool_calls, content_parts} ->
      # Deduplicate tool calls by (name, arguments) pair
      #
      # WORKAROUND: Meta Llama models on AWS Bedrock return duplicate tool calls
      # with identical parameters but different toolUseIds. This is a known issue
      # with Meta Llama tool calling behavior across multiple platforms.
      #
      # References:
      # - https://stackoverflow.com/questions/79247654/inconsistent-tool-calling-behavior-with-llama-3-1-70b-model-on-aws-bedrock
      # - https://github.com/meta-llama/llama-models/issues/229
      #
      # This deduplication keeps the first occurrence of each unique (name, arguments)
      # pair and discards duplicates. If this workaround becomes unnecessary, it can
      # be safely removed without affecting other models.
      deduplicated_tool_calls =
        tool_calls
        |> Enum.reverse()
        |> Enum.uniq_by(fn tool_call ->
          {tool_call.function.name, tool_call.function.arguments}
        end)

      # Log warning if duplicates were removed
      duplicates_removed = length(tool_calls) - length(deduplicated_tool_calls)

      if duplicates_removed > 0 do
        require Logger

        Logger.warning(
          "[ReqLLM] Removed #{duplicates_removed} duplicate tool call(s). " <>
            "This is a known issue with Meta Llama models on AWS Bedrock. " <>
            "See: https://github.com/meta-llama/llama-models/issues/229"
        )
      end

      {deduplicated_tool_calls, Enum.reverse(content_parts)}
    end)
  end

  defp parse_content_with_tool_calls(_), do: {[], []}

  # Parse individual content blocks (excluding tool calls which are handled separately)
  defp parse_content_block(%{"text" => text}) do
    # WORKAROUND: Meta Llama models output malformed JSON when confused about tool usage
    # Strip patterns like {"name": null, "parameters": null}
    #
    # Instead of generating proper text responses, Meta Llama models sometimes output
    # malformed JSON structures with null values when tools are available but shouldn't
    # be used. This is part of broader tool calling issues with Meta Llama models.
    #
    # References:
    # - https://github.com/ggml-org/llama.cpp/issues/14697 (tool calls as JSON strings)
    # - Multiple reports of Llama 3/4 returning null/malformed JSON in tool contexts
    #
    # This workaround strips the malformed JSON. If this becomes unnecessary, it can
    # be safely removed without affecting other models.
    cleaned_text = strip_malformed_tool_json(text)

    if cleaned_text != "" do
      ContentPart.text(cleaned_text)
    end
  end

  defp parse_content_block(%{"reasoningContent" => %{"reasoningText" => %{"text" => text}}}) do
    ContentPart.thinking(text)
  end

  defp parse_content_block(%{"reasoningContent" => _redacted}), do: nil

  defp parse_content_block(%{"image" => _image}) do
    # Image in response - for now skip
    nil
  end

  defp parse_content_block(_), do: nil

  # Strip malformed tool call JSON that some models output when confused about tool usage
  defp strip_malformed_tool_json(text) when is_binary(text) do
    trimmed = String.trim(text)

    case trimmed do
      # Match {"name": null, "parameters": null} or similar variations
      "{\"name\":" <> rest ->
        if String.contains?(rest, "null") and String.contains?(rest, "}") do
          require Logger

          Logger.warning(
            "[ReqLLM] Stripped malformed tool JSON from response: #{inspect(trimmed)}. " <>
              "This is a known issue with Meta Llama models outputting null JSON when confused about tool usage. " <>
              "See: https://github.com/ggml-org/llama.cpp/issues/14697"
          )

          ""
        else
          text
        end

      _ ->
        text
    end
  end

  defp strip_malformed_tool_json(text), do: text

  defp parse_usage(nil), do: nil

  defp parse_usage(usage) do
    input = usage["inputTokens"] || 0
    output = usage["outputTokens"] || 0
    cached = (usage["cacheReadInputTokens"] || 0) + (usage["cacheWriteInputTokens"] || 0)

    %{
      input_tokens: input,
      output_tokens: output,
      total_tokens: input + output,
      cached_tokens: cached,
      reasoning_tokens: 0
    }
  end

  defp map_stop_reason("end_turn"), do: :stop
  defp map_stop_reason("tool_use"), do: :tool_calls
  defp map_stop_reason("max_tokens"), do: :length
  defp map_stop_reason("stop_sequence"), do: :stop
  defp map_stop_reason("content_filtered"), do: :content_filter
  defp map_stop_reason("guardrail_intervened"), do: :content_filter
  defp map_stop_reason(_), do: :stop
end
