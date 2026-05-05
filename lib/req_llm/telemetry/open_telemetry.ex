defmodule ReqLLM.Telemetry.OpenTelemetry do
  @moduledoc """
  Dependency-free helpers for mapping ReqLLM telemetry metadata to
  OpenTelemetry GenAI span data.

  This module does not depend on an OpenTelemetry SDK and does not start or stop
  spans on your behalf. Instead, it translates ReqLLM's native `:telemetry`
  metadata into:

  - GenAI span names
  - GenAI span attributes
  - span status hints
  - exception event payloads

  Content capture is opt-in through `content: :attributes`. To emit
  `gen_ai.input.messages` and `gen_ai.output.messages`, ReqLLM request telemetry
  must also enable payload capture with `telemetry: [payloads: :raw]`.

  Thinking and reasoning text remain redacted even when content capture is
  enabled, so reasoning parts are intentionally omitted from OpenTelemetry
  content attributes.
  """

  alias ReqLLM.{MapAccess, Message, Response, ToolCall, ToolResult, Usage}
  alias ReqLLM.Message.ContentPart

  @type content_mode :: :none | :attributes
  @type span_status :: :ok | {:error, String.t()}
  @type otel_event :: %{name: String.t(), attributes: map()}

  @type request_start_stub :: %{
          name: String.t(),
          kind: :client,
          attributes: map()
        }

  @type request_terminal_stub :: %{
          attributes: map(),
          status: span_status(),
          events: [otel_event()]
        }

  @doc """
  Builds span creation data for a `[:req_llm, :request, :start]` event.
  """
  @spec request_start(map(), keyword()) :: request_start_stub()
  def request_start(metadata, opts \\ []) when is_map(metadata) do
    %{
      name: span_name(metadata),
      kind: :client,
      attributes:
        metadata
        |> common_attributes()
        |> Map.merge(request_content_attributes(metadata, content_mode(opts)))
        |> compact_map()
    }
  end

  @doc """
  Builds terminal span data for a `[:req_llm, :request, :stop]` event.
  """
  @spec request_stop(map(), keyword()) :: request_terminal_stub()
  def request_stop(metadata, opts \\ []) when is_map(metadata) do
    %{
      attributes:
        metadata
        |> common_attributes()
        |> Map.merge(request_content_attributes(metadata, content_mode(opts)))
        |> Map.merge(response_attributes(metadata))
        |> Map.merge(response_content_attributes(metadata, content_mode(opts)))
        |> compact_map(),
      status: span_status(metadata),
      events: []
    }
  end

  @doc """
  Builds terminal span data for a `[:req_llm, :request, :exception]` event.
  """
  @spec request_exception(map(), keyword()) :: request_terminal_stub()
  def request_exception(metadata, opts \\ []) when is_map(metadata) do
    %{
      attributes:
        metadata
        |> common_attributes()
        |> Map.merge(request_content_attributes(metadata, content_mode(opts)))
        |> Map.merge(error_attributes(metadata))
        |> compact_map(),
      status: span_status(metadata),
      events: exception_events(metadata)
    }
  end

  defp span_name(metadata) do
    operation = operation_name(MapAccess.get(metadata, :operation))
    model_id = requested_model_id(MapAccess.get(metadata, :model))
    String.trim("#{operation} #{model_id}")
  end

  defp common_attributes(metadata) do
    model = MapAccess.get(metadata, :model)

    %{
      "gen_ai.provider.name" => provider_name(metadata, model),
      "gen_ai.operation.name" => operation_name(MapAccess.get(metadata, :operation)),
      "gen_ai.request.model" => requested_model_id(model)
    }
  end

  defp response_attributes(metadata) do
    response_payload = MapAccess.get(metadata, :response_payload)
    requested_model = requested_model_id(MapAccess.get(metadata, :model))

    %{}
    |> maybe_put("gen_ai.response.id", response_id(response_payload))
    |> maybe_put("gen_ai.response.model", response_model(response_payload, requested_model))
    |> Map.merge(usage_attributes(MapAccess.get(metadata, :usage)))
    |> maybe_put(
      "gen_ai.response.finish_reasons",
      finish_reasons(MapAccess.get(metadata, :finish_reason))
    )
  end

  defp usage_attributes(nil), do: %{}

  defp usage_attributes(usage) when is_map(usage) do
    usage_source =
      case MapAccess.get(usage, :tokens) do
        tokens when is_map(tokens) -> tokens
        _ -> usage
      end

    normalized = Usage.normalize(usage_source)

    %{}
    |> maybe_put("gen_ai.usage.input_tokens", MapAccess.get(normalized, :input_tokens))
    |> maybe_put("gen_ai.usage.output_tokens", MapAccess.get(normalized, :output_tokens))
  end

  defp request_content_attributes(_metadata, :none), do: %{}

  defp request_content_attributes(metadata, :attributes) do
    case request_messages(metadata) do
      [] -> %{}
      messages -> %{"gen_ai.input.messages" => messages}
    end
  end

  defp response_content_attributes(_metadata, :none), do: %{}

  defp response_content_attributes(metadata, :attributes) do
    case response_messages(metadata) do
      [] -> %{}
      messages -> %{"gen_ai.output.messages" => messages}
    end
  end

  defp request_messages(metadata) do
    metadata
    |> MapAccess.get(:request_payload)
    |> MapAccess.get(:messages, [])
    |> List.wrap()
    |> Enum.map(&message_to_otel/1)
    |> Enum.reject(&is_nil/1)
  end

  defp response_messages(metadata) do
    response_payload = MapAccess.get(metadata, :response_payload)
    finish_reason = MapAccess.get(metadata, :finish_reason)

    response_payload
    |> extract_response_messages()
    |> Enum.map(&message_to_otel(&1, finish_reason))
    |> Enum.reject(&is_nil/1)
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
        case MapAccess.get(part, :url) do
          url when is_binary(url) and url != "" ->
            [
              %{
                "type" => "uri",
                "uri" => url,
                "modality" => "image"
              }
            ]

          _ ->
            []
        end

      _ ->
        []
    end
  end

  defp content_part_to_otel(_part), do: []

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

  defp content_mode(opts) do
    case Keyword.get(opts, :content, :none) do
      :attributes -> :attributes
      true -> :attributes
      _ -> :none
    end
  end

  defp provider_name(metadata, model) do
    metadata
    |> MapAccess.get(:provider)
    |> case do
      nil -> MapAccess.get(model || %{}, :provider)
      provider -> provider
    end
    |> atom_to_string()
  end

  defp operation_name(nil), do: ""
  defp operation_name(operation) when is_atom(operation), do: Atom.to_string(operation)
  defp operation_name(operation) when is_binary(operation), do: operation
  defp operation_name(operation), do: inspect(operation)

  defp requested_model_id(%{id: id}) when is_binary(id), do: id
  defp requested_model_id(_), do: ""

  defp response_id(%Response{id: id}) when is_binary(id), do: id

  defp response_id(response_payload) when is_map(response_payload) do
    MapAccess.get(response_payload, :id)
  end

  defp response_id(_), do: nil

  defp response_model(%Response{model: model}, _requested_model)
       when is_binary(model) and model != "" do
    model
  end

  defp response_model(response_payload, requested_model) when is_map(response_payload) do
    case MapAccess.get(response_payload, :model) do
      model when is_binary(model) and model != "" -> model
      _ -> requested_model
    end
  end

  defp response_model(_response_payload, requested_model), do: requested_model

  defp finish_reasons(nil), do: nil

  defp finish_reasons(reasons) when is_list(reasons) do
    reasons
    |> Enum.map(&finish_reason_to_string/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      values -> values
    end
  end

  defp finish_reasons(reason) do
    case finish_reason_to_string(reason) do
      nil -> nil
      value -> [value]
    end
  end

  defp finish_reason_to_string(nil), do: nil
  defp finish_reason_to_string(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp finish_reason_to_string(reason) when is_binary(reason), do: reason
  defp finish_reason_to_string(reason), do: inspect(reason)

  defp message_finish_reason(:tool_calls), do: "tool_call"
  defp message_finish_reason("tool_calls"), do: "tool_call"
  defp message_finish_reason(reason), do: finish_reason_to_string(reason)

  defp normalize_role(role) when is_atom(role), do: Atom.to_string(role)
  defp normalize_role(role) when is_binary(role), do: role
  defp normalize_role(_role), do: nil

  defp span_status(metadata) do
    error = MapAccess.get(metadata, :error)
    http_status = MapAccess.get(metadata, :http_status)
    finish_reason = MapAccess.get(metadata, :finish_reason)

    case {error, http_status, finish_reason} do
      {error, _http_status, _finish_reason} when not is_nil(error) ->
        {:error, error_message(error)}

      {_error, http_status, _finish_reason} when is_integer(http_status) and http_status >= 400 ->
        {:error, "HTTP #{http_status}"}

      {_error, _http_status, finish_reason} when finish_reason in [:error, "error"] ->
        {:error, "request failed"}

      _ ->
        :ok
    end
  end

  defp error_attributes(metadata) do
    case MapAccess.get(metadata, :error) do
      nil -> %{}
      error -> %{"error.type" => error_type(error)}
    end
  end

  defp exception_events(metadata) do
    case MapAccess.get(metadata, :error) do
      nil ->
        []

      error ->
        [
          %{
            name: "exception",
            attributes:
              %{
                "exception.type" => error_type(error),
                "exception.message" => error_message(error)
              }
              |> compact_map()
          }
        ]
    end
  end

  defp error_type(%{__struct__: module}) when is_atom(module), do: inspect(module)
  defp error_type(error) when is_atom(error), do: Atom.to_string(error)
  defp error_type(_error), do: "error"

  defp error_message(%{__exception__: true} = error), do: Exception.message(error)
  defp error_message(error) when is_binary(error), do: error
  defp error_message(error) when is_atom(error), do: Atom.to_string(error)
  defp error_message(error), do: inspect(error)

  defp decode_tool_arguments(arguments) when is_binary(arguments) do
    case Jason.decode(arguments) do
      {:ok, decoded} -> decoded
      {:error, _} -> arguments
    end
  end

  defp decode_tool_arguments(arguments), do: arguments

  defp atom_to_string(nil), do: nil
  defp atom_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp atom_to_string(value) when is_binary(value), do: value
  defp atom_to_string(value), do: inspect(value)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp compact_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
