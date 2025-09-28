defmodule ReqLLM.Streaming.FinchClient do
  @moduledoc """
  Finch HTTP client for ReqLLM streaming operations.

  This module handles the Finch HTTP transport layer for streaming requests,
  forwarding HTTP events to StreamServer for processing. It acts as a bridge
  between Finch's HTTP streaming and the StreamServer's event processing.

  ## Responsibilities

  - Build Finch.Request using provider-specific stream attachment
  - Start supervised Task that calls Finch.stream/5 with callback
  - Forward all HTTP events to StreamServer via GenServer.call
  - Handle connection errors and forward to StreamServer
  - Return HTTPContext for fixture capture

  ## HTTPContext

  The HTTPContext struct provides minimal HTTP metadata needed for fixture
  capture and testing, replacing the more heavyweight Req.Request/Response
  structs used in non-streaming operations.

  ## Provider Integration

  Uses provider-specific `attach_stream/4` callbacks to build streaming
  requests with proper authentication, headers, and request body formatting.
  """

  require Logger

  defmodule HTTPContext do
    @moduledoc """
    Lightweight HTTP context for streaming operations.

    This struct contains the minimal HTTP metadata needed for fixture capture
    and debugging, replacing the heavier Req.Request/Response structs for
    streaming operations.
    """

    @derive Jason.Encoder
    defstruct [
      :url,
      :method,
      :req_headers,
      :status,
      :resp_headers
    ]

    @type t :: %__MODULE__{
            url: String.t(),
            method: :get | :post | :put | :patch | :delete,
            req_headers: map(),
            status: integer() | nil,
            resp_headers: map() | nil
          }

    @doc """
    Creates a new HTTPContext from request parameters.
    """
    @spec new(String.t(), :get | :post | :put | :patch | :delete, map()) :: t()
    def new(url, method, headers) do
      %__MODULE__{
        url: url,
        method: method,
        req_headers: sanitize_headers(headers),
        status: nil,
        resp_headers: nil
      }
    end

    @doc """
    Updates the context with response status and headers.
    """
    @spec update_response(t(), integer(), map()) :: t()
    def update_response(%__MODULE__{} = context, status, headers) do
      %{context | status: status, resp_headers: sanitize_headers(headers)}
    end

    # Remove sensitive headers that might contain API keys
    defp sanitize_headers(headers) when is_map(headers) do
      sensitive_keys = [
        "authorization",
        "x-api-key",
        "anthropic-api-key",
        "openai-api-key",
        "x-auth-token",
        "bearer",
        "api-key",
        "access-token"
      ]

      Enum.reduce(sensitive_keys, headers, fn key, acc ->
        case Map.get(acc, key) do
          nil -> acc
          _value -> Map.put(acc, key, "[REDACTED:#{key}]")
        end
      end)
    end

    defp sanitize_headers(headers) when is_list(headers) do
      headers
      |> Map.new()
      |> sanitize_headers()
    end

    defp sanitize_headers(headers), do: headers
  end

  @doc """
  Starts a streaming HTTP request and forwards events to StreamServer.

  ## Parameters

    * `provider_mod` - The provider module (e.g., ReqLLM.Providers.OpenAI)
    * `model` - The ReqLLM.Model struct
    * `context` - The ReqLLM.Context with messages to stream
    * `opts` - Additional options for the request
    * `stream_server_pid` - PID of the StreamServer GenServer
    * `finch_name` - Finch process name (defaults to ReqLLM.Finch)

  ## Returns

    * `{:ok, task_pid, http_context, canonical_json}` - Successfully started streaming task
    * `{:error, reason}` - Failed to start streaming

  The returned task will handle the Finch.stream/5 call and forward all HTTP events
  to the StreamServer. The HTTPContext provides minimal metadata for fixture capture.
  """
  @spec start_stream(
          module(),
          ReqLLM.Model.t(),
          ReqLLM.Context.t(),
          keyword(),
          pid(),
          atom()
        ) :: {:ok, pid(), HTTPContext.t(), any()} | {:error, term()}
  def start_stream(
        provider_mod,
        model,
        context,
        opts,
        stream_server_pid,
        finch_name \\ ReqLLM.Finch
      ) do
    with {:ok, finch_request, http_context, canonical_json} <-
           build_stream_request(provider_mod, model, context, opts, finch_name),
         {:ok, task_pid} <-
           start_streaming_task(finch_request, stream_server_pid, finch_name, http_context) do
      {:ok, task_pid, http_context, canonical_json}
    end
  end

  # Build Finch.Request using provider callback
  defp build_stream_request(provider_mod, model, context, opts, finch_name) do
    # Use provider's attach_stream/4 callback
    case provider_mod.attach_stream(model, context, opts, finch_name) do
      {:ok, finch_request} ->
        # Extract HTTP context from the request for fixture capture
        url =
          if (finch_request.scheme == :https and finch_request.port == 443) or
               (finch_request.scheme == :http and finch_request.port == 80) do
            "#{finch_request.scheme}://#{finch_request.host}#{finch_request.path}"
          else
            "#{finch_request.scheme}://#{finch_request.host}:#{finch_request.port}#{finch_request.path}"
          end

        method = String.downcase(finch_request.method) |> String.to_atom()

        http_context =
          HTTPContext.new(
            url,
            method,
            Map.new(finch_request.headers)
          )

        # Extract canonical JSON from finch request body for fixture capture
        canonical_json = extract_canonical_json(finch_request)

        {:ok, finch_request, http_context, canonical_json}

      {:error, reason} ->
        Logger.error("Provider failed to build streaming request: #{inspect(reason)}")
        {:error, {:provider_build_failed, reason}}
    end
  rescue
    error ->
      Logger.error("Failed to call provider attach_stream: #{inspect(error)}")
      {:error, {:build_request_failed, error}}
  end

  # Extract JSON from Finch request body
  defp extract_canonical_json(%Finch.Request{body: body}) do
    case body do
      nil ->
        %{}

      binary when is_binary(binary) ->
        case Jason.decode(binary) do
          {:ok, json} -> json
          {:error, _} -> %{raw_body: binary}
        end

      {:stream, _} ->
        %{streaming_body: true}

      other ->
        %{unknown_body: inspect(other)}
    end
  rescue
    _ -> %{}
  end

  # Start supervised task for Finch streaming
  defp start_streaming_task(finch_request, stream_server_pid, finch_name, http_context) do
    parent_pid = self()

    task_pid =
      Task.Supervisor.async_nolink(ReqLLM.TaskSupervisor, fn ->
        finch_stream_callback = fn
          {:status, status}, acc ->
            updated_context = HTTPContext.update_response(acc, status, %{})
            GenServer.call(stream_server_pid, {:http_event, {:status, status}})
            updated_context

          {:headers, headers}, acc ->
            # Update context with response headers
            current_status = acc.status || 200

            updated_context =
              HTTPContext.update_response(acc, current_status, Map.new(headers))

            GenServer.call(stream_server_pid, {:http_event, {:headers, headers}})
            updated_context

          {:data, chunk}, acc ->
            GenServer.call(stream_server_pid, {:http_event, {:data, chunk}})
            acc

          :done, acc ->
            GenServer.call(stream_server_pid, {:http_event, :done})
            acc
        end

        try do
          case Finch.stream(finch_request, finch_name, http_context, finch_stream_callback) do
            {:ok, final_context} ->
              Logger.debug("Finch streaming completed successfully")
              send(parent_pid, {:stream_task_completed, final_context})
              :ok

            {:error, reason, _partial_acc} ->
              Logger.error("Finch streaming failed: #{inspect(reason)}")
              GenServer.call(stream_server_pid, {:http_event, {:error, reason}})
              send(parent_pid, {:stream_task_failed, reason})
              {:error, reason}
          end
        catch
          :exit, reason ->
            Logger.error("Finch streaming task exited: #{inspect(reason)}")
            GenServer.call(stream_server_pid, {:http_event, {:error, {:exit, reason}}})
            send(parent_pid, {:stream_task_failed, {:exit, reason}})
            {:error, {:exit, reason}}

          kind, reason ->
            Logger.error("Finch streaming task crashed: #{kind} #{inspect(reason)}")
            GenServer.call(stream_server_pid, {:http_event, {:error, {kind, reason}}})
            send(parent_pid, {:stream_task_failed, {kind, reason}})
            {:error, {kind, reason}}
        end
      end)

    {:ok, task_pid.pid}
  rescue
    error ->
      Logger.error("Failed to start streaming task: #{inspect(error)}")
      {:error, {:task_start_failed, error}}
  end
end
