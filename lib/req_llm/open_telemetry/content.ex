defmodule ReqLLM.OpenTelemetry.Content do
  @moduledoc """
  Shapes ReqLLM request and response payloads into the GenAI content
  attributes — `gen_ai.input.messages`, `gen_ai.system_instructions`,
  `gen_ai.tool.definitions`, `gen_ai.output.messages`.

  Used by both `ReqLLM.OpenTelemetry` and `ReqLLM.Telemetry.OpenTelemetry`
  when content capture is opted in (`content: :attributes` or `:event` —
  default is `:none`). The caller must also have raw payload telemetry on
  (`telemetry: [payloads: :raw]`) for the request payload to be available.

  Span attribute content is JSON-encoded before being returned, so attribute
  values are `[String.t()]` (an array of primitives — what the OpenTelemetry
  attribute spec accepts and what GenAI-aware backends like Langfuse, Honeycomb,
  and Grafana decode for display). Event content remains structured for the
  `gen_ai.client.inference.operation.details` event. `request_attributes/1`
  returns roughly:

      %{
        "gen_ai.system_instructions" => [
          ~s({"type":"text","content":"You are a helpful assistant."})
        ],
        "gen_ai.input.messages" => [
          ~s({"role":"user","parts":[{"type":"text","content":"Hi"}]})
        ],
        "gen_ai.tool.definitions" => [
          ~s({"type":"function","name":"get_weather","parameters":{...}})
        ]
      }

  Reasoning text is excluded in every mode — ReqLLM's payload sanitizer
  redacts it before this module sees the messages, and content parts are
  filtered to spec-friendly types (`text`, `image`, `image_url`,
  `video_url`, `file`) so thinking output cannot leak through.
  """

  alias ReqLLM.{MapAccess, Message, Response, ToolCall, ToolResult}
  alias ReqLLM.Message.ContentPart

  @doc """
  Returns the input-message list for `gen_ai.input.messages`, excluding any
  system messages (which are exposed via `system_instructions/1`). Each
  message is JSON-encoded so the result is a primitive-array attribute
  value.
  """
  @spec input_messages(map()) :: [String.t()]
  def input_messages(metadata) do
    metadata
    |> structured_input_messages()
    |> encode_all()
  end

  @doc """
  Returns the `gen_ai.system_instructions` part list extracted from system
  messages in the request payload. Reasoning text is intentionally excluded.
  Each part is JSON-encoded so the result is a primitive-array attribute
  value.
  """
  @spec system_instructions(map()) :: [String.t()]
  def system_instructions(metadata) do
    metadata
    |> structured_system_instructions()
    |> encode_all()
  end

  @doc """
  Returns tool definitions for `gen_ai.tool.definitions` from the request
  payload. Each tool is JSON-encoded so the result is a primitive-array
  attribute value (entries decode to
  `%{"type" => "function", "name" => ..., ...}`).
  """
  @spec tool_definitions(map()) :: [String.t()]
  def tool_definitions(metadata) do
    metadata
    |> structured_tool_definitions()
    |> encode_all()
  end

  @doc """
  Returns the response message list for `gen_ai.output.messages`. Each
  message is JSON-encoded so the result is a primitive-array attribute
  value.
  """
  @spec output_messages(map()) :: [String.t()]
  def output_messages(metadata) do
    metadata
    |> structured_output_messages()
    |> encode_all()
  end

  @doc """
  Builds the request-side content-attribute map (input messages, system
  instructions, tool definitions). Empty values are dropped.
  """
  @spec request_attributes(map()) :: %{optional(String.t()) => term()}
  def request_attributes(metadata) do
    %{}
    |> maybe_put("gen_ai.input.messages", input_messages(metadata))
    |> maybe_put("gen_ai.system_instructions", system_instructions(metadata))
    |> maybe_put("gen_ai.tool.definitions", tool_definitions(metadata))
  end

  @doc """
  Builds the response-side content-attribute map (output messages).
  """
  @spec response_attributes(map()) :: %{optional(String.t()) => term()}
  def response_attributes(metadata) do
    maybe_put(%{}, "gen_ai.output.messages", output_messages(metadata))
  end

  @doc """
  Builds the request-side content-event map with structured values.
  """
  @spec request_event_attributes(map()) :: %{optional(String.t()) => term()}
  def request_event_attributes(metadata) do
    %{}
    |> maybe_put("gen_ai.input.messages", structured_input_messages(metadata))
    |> maybe_put("gen_ai.system_instructions", structured_system_instructions(metadata))
    |> maybe_put("gen_ai.tool.definitions", structured_tool_definitions(metadata))
  end

  @doc """
  Builds the response-side content-event map with structured values.
  """
  @spec response_event_attributes(map()) :: %{optional(String.t()) => term()}
  def response_event_attributes(metadata) do
    maybe_put(%{}, "gen_ai.output.messages", structured_output_messages(metadata))
  end

  defp structured_input_messages(metadata) do
    metadata
    |> request_messages()
    |> Enum.reject(&system_message?/1)
    |> Enum.map(&message_to_otel/1)
    |> Enum.reject(&is_nil/1)
  end

  defp structured_system_instructions(metadata) do
    metadata
    |> request_messages()
    |> Enum.filter(&system_message?/1)
    |> Enum.flat_map(&system_message_parts/1)
  end

  defp structured_tool_definitions(metadata) do
    metadata
    |> MapAccess.get(:request_payload)
    |> tools_from_payload()
    |> List.wrap()
    |> Enum.map(&tool_to_otel/1)
    |> Enum.reject(&is_nil/1)
  end

  defp structured_output_messages(metadata) do
    finish_reason = MapAccess.get(metadata, :finish_reason)

    metadata
    |> MapAccess.get(:response_payload)
    |> extract_response_messages()
    |> Enum.map(&message_to_otel(&1, finish_reason))
    |> Enum.reject(&is_nil/1)
  end

  defp encode_all(entries), do: Enum.map(entries, &Jason.encode!/1)

  defp request_messages(metadata) do
    metadata
    |> MapAccess.get(:request_payload)
    |> MapAccess.get(:messages, [])
    |> List.wrap()
  end

  defp system_message?(message) do
    case MapAccess.get(message, :role) do
      :system -> true
      "system" -> true
      _ -> false
    end
  end

  defp system_message_parts(message) do
    message
    |> MapAccess.get(:content, [])
    |> List.wrap()
    |> Enum.flat_map(&content_part_to_otel/1)
    |> Enum.filter(fn part -> Map.get(part, "type") == "text" end)
  end

  defp tools_from_payload(payload) when is_map(payload) do
    MapAccess.get(payload, :tools, [])
  end

  defp tools_from_payload(_), do: []

  defp tool_to_otel(tool) when is_map(tool) do
    name = fetch_field(tool, :name)
    type = fetch_field(tool, :type)

    cond do
      is_binary(name) and name != "" ->
        %{"type" => "function", "name" => name}
        |> maybe_put("description", fetch_field(tool, :description))
        |> maybe_put("strict", fetch_field(tool, :strict))
        |> maybe_put("parameters", fetch_field(tool, :parameter_schema))

      is_binary(type) and type != "" ->
        %{"type" => type}

      is_atom(type) and not is_nil(type) ->
        %{"type" => Atom.to_string(type)}

      true ->
        nil
    end
  end

  defp tool_to_otel(_), do: nil

  defp fetch_field(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp extract_response_messages(%Response{message: %Message{} = message}), do: [message]

  defp extract_response_messages(response_payload) when is_map(response_payload) do
    case {MapAccess.get(response_payload, :message), MapAccess.get(response_payload, :context)} do
      {message, _context} when is_map(message) ->
        [message]

      {_message, context} when is_map(context) ->
        context
        |> MapAccess.get(:messages, [])
        |> List.wrap()
        |> Enum.take(-1)

      _ ->
        []
    end
  end

  defp extract_response_messages(_), do: []

  defp message_to_otel(message, finish_reason \\ nil)

  defp message_to_otel(%Message{} = message, finish_reason) do
    message
    |> Map.from_struct()
    |> message_to_otel(finish_reason)
  end

  defp message_to_otel(message, finish_reason) when is_map(message) do
    role = normalize_role(MapAccess.get(message, :role))
    parts = message_parts(role, message)

    case {role, parts} do
      {nil, _parts} ->
        nil

      {_role, []} ->
        nil

      {role, parts} ->
        %{"role" => role, "parts" => parts}
        |> maybe_put("finish_reason", message_finish_reason(finish_reason))
    end
  end

  defp message_to_otel(_message, _finish_reason), do: nil

  defp message_parts("tool", message) do
    case tool_response_part(message) do
      nil -> content_parts(message)
      part -> [part]
    end
  end

  defp message_parts(_role, message) do
    content_parts(message) ++ tool_call_parts(message)
  end

  defp content_parts(message) do
    message
    |> MapAccess.get(:content, [])
    |> List.wrap()
    |> Enum.flat_map(&content_part_to_otel/1)
  end

  defp content_part_to_otel(%ContentPart{} = part) do
    part
    |> Map.from_struct()
    |> content_part_to_otel()
  end

  defp content_part_to_otel(part) when is_map(part) do
    case MapAccess.get(part, :type) do
      :text ->
        case MapAccess.get(part, :text) do
          text when is_binary(text) and text != "" -> [%{"type" => "text", "content" => text}]
          _ -> []
        end

      :image_url ->
        uri_part(part, "image")

      :video_url ->
        uri_part(part, "video")

      :image ->
        media_descriptor_part("image", "image", part)

      :file ->
        file_descriptor_part(part)

      _ ->
        []
    end
  end

  defp content_part_to_otel(_part), do: []

  defp uri_part(part, modality) do
    case MapAccess.get(part, :url) do
      url when is_binary(url) and url != "" ->
        [%{"type" => "uri", "uri" => url, "modality" => modality}]

      _ ->
        []
    end
  end

  defp media_descriptor_part(type, modality, part) do
    [
      %{"type" => type, "modality" => modality}
      |> maybe_put("media_type", MapAccess.get(part, :media_type))
      |> maybe_put("bytes", MapAccess.get(part, :bytes))
    ]
  end

  defp file_descriptor_part(part) do
    [
      %{"type" => "file"}
      |> maybe_put("file_id", MapAccess.get(part, :file_id))
      |> maybe_put("filename", MapAccess.get(part, :filename))
      |> maybe_put("media_type", MapAccess.get(part, :media_type))
      |> maybe_put("bytes", MapAccess.get(part, :bytes))
    ]
  end

  defp tool_call_parts(message) do
    message
    |> MapAccess.get(:tool_calls, [])
    |> List.wrap()
    |> Enum.flat_map(&tool_call_part/1)
  end

  defp tool_call_part(%ToolCall{} = tool_call) do
    [
      %{
        "type" => "tool_call",
        "id" => tool_call.id,
        "name" => tool_call.function.name,
        "arguments" => decode_tool_arguments(tool_call.function.arguments)
      }
    ]
  end

  defp tool_call_part(tool_call) when is_map(tool_call) do
    case tool_call_identity(tool_call) do
      {id, name, arguments} when is_binary(id) and is_binary(name) ->
        [
          %{
            "type" => "tool_call",
            "id" => id,
            "name" => name,
            "arguments" => decode_tool_arguments(arguments)
          }
        ]

      _ ->
        []
    end
  end

  defp tool_call_part(_tool_call), do: []

  defp tool_call_identity(tool_call) do
    case MapAccess.get(tool_call, :function) do
      function when is_map(function) ->
        {
          MapAccess.get(tool_call, :id),
          MapAccess.get(function, :name),
          MapAccess.get(function, :arguments)
        }

      _ ->
        {
          MapAccess.get(tool_call, :id),
          MapAccess.get(tool_call, :name),
          MapAccess.get(tool_call, :arguments)
        }
    end
  end

  defp tool_response_part(message) do
    tool_call_id = MapAccess.get(message, :tool_call_id)
    structured_output = ToolResult.output_from_message(message)
    text_output = message_text(message)

    response =
      case {structured_output, text_output} do
        {structured_output, _text_output} when not is_nil(structured_output) ->
          structured_output

        {_structured_output, text_output} when is_binary(text_output) and text_output != "" ->
          text_output

        _ ->
          nil
      end

    case {tool_call_id, response} do
      {tool_call_id, response}
      when is_binary(tool_call_id) and tool_call_id != "" and not is_nil(response) ->
        %{
          "type" => "tool_call_response",
          "id" => tool_call_id,
          "response" => response
        }

      _ ->
        nil
    end
  end

  defp message_text(message) do
    message
    |> MapAccess.get(:content, [])
    |> List.wrap()
    |> Enum.reduce([], fn part, acc ->
      case part do
        %ContentPart{type: :text, text: text} when is_binary(text) and text != "" ->
          [text | acc]

        %{type: :text} = map ->
          case MapAccess.get(map, :text) do
            text when is_binary(text) and text != "" -> [text | acc]
            _ -> acc
          end

        _ ->
          acc
      end
    end)
    |> Enum.reverse()
    |> Enum.join()
  end

  defp normalize_role(role) when is_atom(role), do: Atom.to_string(role)
  defp normalize_role(role) when is_binary(role), do: role
  defp normalize_role(_role), do: nil

  defp message_finish_reason(:tool_calls), do: "tool_call"
  defp message_finish_reason("tool_calls"), do: "tool_call"
  defp message_finish_reason(nil), do: nil
  defp message_finish_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp message_finish_reason(reason) when is_binary(reason), do: reason
  defp message_finish_reason(reason), do: inspect(reason)

  defp decode_tool_arguments(arguments) when is_binary(arguments) do
    case Jason.decode(arguments) do
      {:ok, decoded} -> decoded
      {:error, _} -> arguments
    end
  end

  defp decode_tool_arguments(arguments), do: arguments

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
