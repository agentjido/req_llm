defmodule ReqLLM.OpenTelemetry.Attributes do
  @moduledoc false

  alias ReqLLM.MapAccess
  alias ReqLLM.OpenTelemetry.SemConv
  alias ReqLLM.Response

  @doc """
  Builds GenAI span start attributes from request lifecycle metadata.

  The returned map uses binary attribute names as defined by the OpenTelemetry
  GenAI semantic conventions. Callers that need atom-keyed maps (e.g. the live
  bridge) atomize at the adapter boundary.
  """
  @spec start(map()) :: %{optional(String.t()) => term()}
  def start(metadata) do
    operation = MapAccess.get(metadata, :operation)

    %{
      "gen_ai.provider.name" => provider_name(metadata),
      "gen_ai.operation.name" => SemConv.operation_name(operation),
      "gen_ai.request.model" => request_model(metadata),
      "gen_ai.output.type" => SemConv.output_type(operation),
      "req_llm.request_id" => MapAccess.get(metadata, :request_id)
    }
    |> Map.merge(request_options(MapAccess.get(metadata, :request_options)))
    |> Map.merge(server(MapAccess.get(metadata, :server)))
    |> compact()
  end

  @doc """
  Builds the additional attributes that become available at request stop.

  These are merged on top of the start attributes already on the span.
  """
  @spec terminal(map()) :: %{optional(String.t()) => term()}
  def terminal(metadata) do
    %{
      "gen_ai.response.finish_reasons" => finish_reasons(MapAccess.get(metadata, :finish_reason)),
      "gen_ai.response.time_to_first_chunk" => streaming_ttfc_seconds(metadata)
    }
    |> Map.merge(usage(MapAccess.get(metadata, :usage)))
    |> Map.merge(
      response(
        MapAccess.get(metadata, :response_payload),
        MapAccess.get(metadata, :model)
      )
    )
    |> Map.merge(embeddings(metadata))
    |> Map.merge(http_error(metadata))
    |> compact()
  end

  @doc """
  Resolves the GenAI provider name from request metadata, falling back to the
  model's provider when `metadata.provider` is absent.
  """
  @spec provider_name(map()) :: String.t() | nil
  def provider_name(metadata) do
    metadata
    |> MapAccess.get(:provider)
    |> case do
      nil -> MapAccess.get(MapAccess.get(metadata, :model) || %{}, :provider)
      provider -> provider
    end
    |> SemConv.provider_name()
  end

  @doc """
  Returns the requested model id, e.g. `"gpt-5"`.
  """
  @spec request_model(map()) :: String.t() | nil
  def request_model(metadata) do
    request_model_for(MapAccess.get(metadata, :model))
  end

  @doc """
  Returns `gen_ai.response.time_to_first_chunk` as seconds, or `nil` for
  non-streaming requests or streams that never observed a content chunk.
  """
  @spec streaming_ttfc_seconds(map()) :: float() | nil
  def streaming_ttfc_seconds(metadata) do
    with :stream <- MapAccess.get(metadata, :mode),
         streaming when is_map(streaming) <- MapAccess.get(metadata, :streaming),
         native when is_integer(native) <- MapAccess.get(streaming, :time_to_first_chunk) do
      System.convert_time_unit(native, :native, :microsecond) / 1_000_000
    else
      _ -> nil
    end
  end

  @doc """
  Builds attributes added on `:exception` events. Includes `error.type`.
  """
  @spec exception(map()) :: %{optional(String.t()) => term()}
  def exception(metadata) do
    %{
      "error.type" => error_type(metadata),
      "req_llm.request_id" => MapAccess.get(metadata, :request_id)
    }
    |> compact()
  end

  @doc """
  Returns the exception event payload (`exception.type`, `exception.message`).
  """
  @spec exception_event(map()) :: %{optional(String.t()) => term()}
  def exception_event(metadata) do
    %{
      "exception.type" => error_type(metadata),
      "exception.message" => error_message(MapAccess.get(metadata, :error))
    }
    |> compact()
  end

  @doc """
  Returns the span error-status hint for stop events. `nil` for success.
  """
  @spec error_status(map()) :: nil | {String.t(), String.t()}
  def error_status(metadata) do
    case MapAccess.get(metadata, :http_status) do
      status when is_integer(status) and status >= 400 ->
        {Integer.to_string(status), "HTTP #{status}"}

      _ ->
        nil
    end
  end

  defp request_options(nil), do: %{}

  defp request_options(options) when is_map(options) do
    %{
      "gen_ai.request.temperature" => option(options, :temperature),
      "gen_ai.request.top_p" => option(options, :top_p),
      "gen_ai.request.top_k" => option(options, :top_k),
      "gen_ai.request.max_tokens" => option(options, :max_tokens),
      "gen_ai.request.frequency_penalty" => option(options, :frequency_penalty),
      "gen_ai.request.presence_penalty" => option(options, :presence_penalty),
      "gen_ai.request.stop_sequences" => option(options, :stop_sequences),
      "gen_ai.request.seed" => option(options, :seed),
      "gen_ai.request.choice.count" => option(options, :n),
      "gen_ai.request.stream" => option(options, :stream?),
      "gen_ai.request.encoding_formats" => option(options, :encoding_formats),
      "gen_ai.conversation.id" => option(options, :conversation_id)
    }
  end

  defp server(nil), do: %{}

  defp server(server) when is_map(server) do
    %{
      "server.address" => option(server, :address),
      "server.port" => option(server, :port)
    }
  end

  defp option(map, key) when is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp usage(nil), do: %{}

  defp usage(usage) when is_map(usage) do
    tokens =
      case MapAccess.get(usage, :tokens) do
        tokens when is_map(tokens) -> tokens
        _ -> usage
      end

    %{
      "gen_ai.usage.input_tokens" => token_value(tokens, [:input, :input_tokens]),
      "gen_ai.usage.output_tokens" => token_value(tokens, [:output, :output_tokens]),
      "gen_ai.usage.cache_read.input_tokens" =>
        token_value(tokens, [:cached_input, :cache_read_input_tokens]),
      "gen_ai.usage.cache_creation.input_tokens" =>
        token_value(tokens, [:cache_creation, :cache_creation_input_tokens]),
      "gen_ai.usage.reasoning.output_tokens" => reasoning_tokens(usage)
    }
  end

  defp token_value(tokens, keys) do
    Enum.find_value(keys, fn key -> MapAccess.get(tokens, key) end)
  end

  defp reasoning_tokens(usage) when is_map(usage) do
    case MapAccess.get(usage, :reasoning_tokens) do
      nil ->
        case MapAccess.get(usage, :tokens) do
          tokens when is_map(tokens) -> MapAccess.get(tokens, :reasoning)
          _ -> nil
        end

      value ->
        value
    end
  end

  defp reasoning_tokens(_), do: nil

  defp response(nil, _model), do: %{}

  defp response(%Response{id: id, model: response_model}, model) do
    %{
      "gen_ai.response.id" => present(id),
      "gen_ai.response.model" => present(response_model) || request_model_for(model)
    }
  end

  defp response(payload, model) when is_map(payload) do
    %{
      "gen_ai.response.id" => present(MapAccess.get(payload, :id)),
      "gen_ai.response.model" =>
        present(MapAccess.get(payload, :model)) || request_model_for(model)
    }
  end

  defp response(_, _), do: %{}

  defp present(nil), do: nil
  defp present(""), do: nil
  defp present(value), do: value

  defp embeddings(metadata) do
    with :embedding <- MapAccess.get(metadata, :operation),
         summary when is_map(summary) <- MapAccess.get(metadata, :response_summary),
         dim when is_integer(dim) <- MapAccess.get(summary, :dimensions) do
      %{"gen_ai.embeddings.dimension.count" => dim}
    else
      _ -> %{}
    end
  end

  defp http_error(metadata) do
    case MapAccess.get(metadata, :http_status) do
      status when is_integer(status) and status >= 400 ->
        %{"error.type" => Integer.to_string(status)}

      _ ->
        %{}
    end
  end

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

  defp request_model_for(%LLMDB.Model{id: id}) when is_binary(id), do: id
  defp request_model_for(model) when is_map(model), do: MapAccess.get(model, :id)
  defp request_model_for(_), do: nil

  defp error_type(metadata) do
    case {MapAccess.get(metadata, :error), MapAccess.get(metadata, :http_status)} do
      {%{__struct__: module}, _} when is_atom(module) ->
        inspect(module)

      {error, _} when is_atom(error) and not is_nil(error) ->
        Atom.to_string(error)

      {{kind, _reason}, _} when is_atom(kind) ->
        Atom.to_string(kind)

      {_, status} when is_integer(status) ->
        Integer.to_string(status)

      _ ->
        "_OTHER"
    end
  end

  defp error_message(nil), do: nil
  defp error_message(%{__exception__: true} = error), do: Exception.message(error)
  defp error_message(error) when is_binary(error), do: error
  defp error_message(error) when is_atom(error), do: Atom.to_string(error)
  defp error_message(error), do: inspect(error)

  defp compact(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == [] end)
    |> Map.new()
  end
end
