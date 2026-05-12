defmodule ReqLLM.OpenTelemetry.Attributes do
  @moduledoc """
  Builds the scalar `gen_ai.*` / `server.*` / `error.*` attribute maps
  emitted on GenAI client spans, from ReqLLM request lifecycle metadata.

  Shared between the live bridge (`ReqLLM.OpenTelemetry`) and the
  dependency-free mapper (`ReqLLM.Telemetry.OpenTelemetry`) so both emit
  identical payloads. See `ReqLLM.OpenTelemetry` for the end-to-end flow.

  `start/1` runs on `[:req_llm, :request, :start]` and returns roughly:

      %{
        "gen_ai.provider.name" => "openai",
        "gen_ai.operation.name" => "chat",
        "gen_ai.request.model" => "gpt-5",
        "gen_ai.request.temperature" => 0.7,
        "server.address" => "api.openai.com",
        "server.port" => 443,
        "req_llm.request_id" => "2184"
      }

  `terminal/1` is merged on top at `:stop` (response id, finish reasons,
  usage, embedding dims, OpenAI extension fields, streaming TTFC).
  `exception/1` and `exception_event/1` cover the error path.

  Keys are binary spec names; the live bridge atomizes them at the adapter
  boundary. `nil` and empty-list values are dropped so OTel backends never
  see blank-but-present attributes.
  """

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
    |> Map.merge(request_reasoning(MapAccess.get(metadata, :reasoning)))
    |> Map.merge(server(MapAccess.get(metadata, :server)))
    |> Map.merge(openai_request_extensions(metadata))
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
    |> Map.merge(openai_response_extensions(metadata))
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

  defp request_reasoning(nil), do: %{}

  defp request_reasoning(reasoning) when is_map(reasoning) do
    %{
      "gen_ai.request.reasoning.effort" =>
        reasoning_effort_to_string(MapAccess.get(reasoning, :requested_effort)),
      "gen_ai.request.reasoning.budget_tokens" =>
        MapAccess.get(reasoning, :requested_budget_tokens)
    }
  end

  defp reasoning_effort_to_string(nil), do: nil
  defp reasoning_effort_to_string(effort) when is_atom(effort), do: Atom.to_string(effort)
  defp reasoning_effort_to_string(effort) when is_binary(effort), do: effort
  defp reasoning_effort_to_string(_), do: nil

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
      "gen_ai.usage.reasoning.output_tokens" => reasoning_tokens(usage),
      "gen_ai.usage.cost" => total_cost(usage)
    }
  end

  @doc """
  Returns the normalized cost breakdown map for `langfuse.observation.cost_details`,
  or `nil` when no cost info is present. Result is suitable for `Jason.encode!/1`.
  """
  @spec cost_breakdown(map()) :: %{optional(String.t()) => number()} | nil
  def cost_breakdown(metadata) when is_map(metadata) do
    case MapAccess.get(metadata, :usage) do
      usage when is_map(usage) -> cost_breakdown_from_usage(usage)
      _ -> nil
    end
  end

  def cost_breakdown(_), do: nil

  defp cost_breakdown_from_usage(usage) do
    [
      {"input", MapAccess.get(usage, :input_cost)},
      {"output", MapAccess.get(usage, :output_cost)},
      {"reasoning", MapAccess.get(usage, :reasoning_cost)},
      {"total", total_cost(usage)}
    ]
    |> Enum.reduce(%{}, fn
      {key, value}, acc when is_number(value) -> Map.put(acc, key, value)
      _, acc -> acc
    end)
    |> case do
      empty when map_size(empty) == 0 -> nil
      breakdown -> breakdown
    end
  end

  defp total_cost(usage) when is_map(usage) do
    case MapAccess.get(usage, :total_cost) do
      value when is_number(value) -> value
      _ -> nil
    end
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

  defp response(nil, _model), do: %{}

  defp response(%Response{id: id, model: response_model}, model) do
    %{
      "gen_ai.response.id" => present(id),
      "gen_ai.response.model" => present(response_model) || request_model_for(model)
    }
  end

  defp response(payload, model) when is_map(payload) do
    %{
      "gen_ai.response.id" =>
        present(MapAccess.get(payload, :id)) || present(MapAccess.get(payload, :response_id)),
      "gen_ai.response.model" =>
        present(MapAccess.get(payload, :model)) || request_model_for(model)
    }
  end

  defp response(_, _), do: %{}

  @doc """
  Returns `nil` for empty strings and `nil`, otherwise returns the value.
  Used by metric and attribute builders to drop blank-but-present fields.
  """
  @spec present(any()) :: any()
  def present(nil), do: nil
  def present(""), do: nil
  def present(value), do: value

  defp embeddings(metadata) do
    with :embedding <- MapAccess.get(metadata, :operation),
         summary when is_map(summary) <- MapAccess.get(metadata, :response_summary),
         dim when is_integer(dim) <- MapAccess.get(summary, :dimensions) do
      %{"gen_ai.embeddings.dimension.count" => dim}
    else
      _ -> %{}
    end
  end

  @openai_providers [:openai, :openai_codex, :azure]

  defp openai_request_extensions(metadata) do
    if openai_family?(metadata) do
      service_tier =
        case MapAccess.get(metadata, :request_options) do
          options when is_map(options) -> MapAccess.get(options, :service_tier)
          _ -> nil
        end

      %{
        "openai.api.type" => openai_api_type(metadata),
        "openai.request.service_tier" => service_tier
      }
    else
      %{}
    end
  end

  defp openai_response_extensions(metadata) do
    if openai_family?(metadata) do
      meta = response_provider_meta(metadata)

      %{
        "openai.response.service_tier" => present(MapAccess.get(meta, :service_tier)),
        "openai.response.system_fingerprint" => present(MapAccess.get(meta, :system_fingerprint))
      }
    else
      %{}
    end
  end

  defp openai_family?(metadata) do
    case raw_provider(metadata) do
      provider when is_atom(provider) -> provider in @openai_providers
      _ -> false
    end
  end

  defp raw_provider(metadata) do
    case MapAccess.get(metadata, :provider) do
      nil ->
        case MapAccess.get(metadata, :model) do
          %{provider: provider} -> provider
          _ -> nil
        end

      provider ->
        provider
    end
  end

  # Prefers an explicit `api_type` hint stamped on the response's
  # `provider_meta` by the OpenAI provider dispatcher. Falls back to URL-path
  # inference when the hint is absent (e.g. providers we haven't wired yet,
  # or response payload not promoted via `telemetry: [payloads: :raw]`).
  defp openai_api_type(metadata) do
    case provider_meta_api_type(metadata) do
      type when is_binary(type) and type != "" -> type
      _ -> openai_api_type_from_server(MapAccess.get(metadata, :server))
    end
  end

  defp provider_meta_api_type(metadata) do
    meta = response_provider_meta(metadata)
    MapAccess.get(meta, :api_type) || MapAccess.get(meta, "api_type")
  end

  defp openai_api_type_from_server(server) when is_map(server) do
    case MapAccess.get(server, :path) do
      path when is_binary(path) ->
        cond do
          String.contains?(path, "/responses") -> "responses"
          String.contains?(path, "/chat/completions") -> "chat_completions"
          String.contains?(path, "/embeddings") -> "embeddings"
          true -> nil
        end

      _ ->
        nil
    end
  end

  defp openai_api_type_from_server(_), do: nil

  defp response_provider_meta(metadata) do
    case MapAccess.get(metadata, :response_payload) do
      %{provider_meta: meta} when is_map(meta) -> meta
      %{"provider_meta" => meta} when is_map(meta) -> meta
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
  defp finish_reason_to_string(:unknown), do: nil
  defp finish_reason_to_string("unknown"), do: nil
  defp finish_reason_to_string(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp finish_reason_to_string(reason) when is_binary(reason), do: reason
  defp finish_reason_to_string(reason), do: inspect(reason)

  defp request_model_for(%LLMDB.Model{id: id}) when is_binary(id), do: id
  defp request_model_for(model) when is_map(model), do: MapAccess.get(model, :id)
  defp request_model_for(_), do: nil

  @doc """
  Resolves a `error.type` string from request metadata. Falls back to
  `"_OTHER"` when nothing is recognizable.
  """
  @spec error_type(map()) :: String.t()
  def error_type(metadata) do
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
