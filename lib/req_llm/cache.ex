defmodule ReqLLM.Cache do
  @moduledoc """
  Application-layer response cache hooks for generation requests.

  ReqLLM does not ship a cache store. Instead, callers can pass a module that
  implements this behaviour to `:cache` and back it with Cachex, Nebulex, ETS,
  Redis, or any custom storage.
  """

  require Logger

  alias ReqLLM.Context
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Response
  alias ReqLLM.StreamChunk
  alias ReqLLM.StreamResponse
  alias ReqLLM.StreamResponse.MetadataHandle
  alias ReqLLM.ToolCall
  alias ReqLLM.Usage

  @type request :: %{
          operation: :chat | :object,
          context: Context.t(),
          schema: map() | nil
        }

  @callback get(key :: term(), opts :: keyword() | map()) ::
              {:ok, Response.t()} | {:error, term()}
  @callback put(
              key :: term(),
              value :: Response.t(),
              ttl :: non_neg_integer() | nil,
              opts :: keyword() | map()
            ) ::
              :ok | {:error, term()}
  @callback delete(key :: term(), opts :: keyword() | map()) :: :ok | {:error, term()}
  @callback generate_key(
              model :: LLMDB.Model.t(),
              request :: request(),
              opts :: keyword() | map()
            ) ::
              term()

  @spec fetch(LLMDB.Model.t(), :chat | :object, Context.t(), keyword(), map() | nil) ::
          {:hit, Response.t(), %{backend: module(), key: term()}}
          | {:miss, %{backend: module(), key: term()} | nil}
  def fetch(%LLMDB.Model{} = model, operation, %Context{} = context, opts, schema \\ nil) do
    with {:ok, backend} <- backend(opts),
         request = %{operation: operation, context: context, schema: schema},
         key <- cache_key(backend, model, request, opts) do
      case backend.get(key, cache_opts(opts)) do
        {:ok, %Response{} = response} ->
          {:hit, cache_hit_response(response, context, opts), %{backend: backend, key: key}}

        {:error, :not_found} ->
          {:miss, %{backend: backend, key: key}}

        {:error, reason} ->
          Logger.warning("ReqLLM cache get failed: #{inspect(reason)}")
          {:miss, %{backend: backend, key: key}}

        other ->
          Logger.warning("ReqLLM cache get returned unexpected value: #{inspect(other)}")
          {:miss, %{backend: backend, key: key}}
      end
    else
      :disabled ->
        {:miss, nil}

      {:error, reason} ->
        Logger.warning("ReqLLM cache disabled for this request: #{inspect(reason)}")
        {:miss, nil}
    end
  end

  @spec store(%{backend: module(), key: term()} | nil, Response.t(), keyword()) :: Response.t()
  def store(nil, %Response{} = response, _opts), do: response

  def store(%{backend: backend, key: key}, %Response{} = response, opts) do
    case backend.put(key, response, Keyword.get(opts, :cache_ttl), cache_opts(opts)) do
      :ok ->
        response

      {:error, reason} ->
        Logger.warning("ReqLLM cache put failed: #{inspect(reason)}")
        response

      other ->
        Logger.warning("ReqLLM cache put returned unexpected value: #{inspect(other)}")
        response
    end
  end

  @spec stream_response(Response.t(), LLMDB.Model.t(), Context.t()) :: StreamResponse.t()
  def stream_response(%Response{} = response, %LLMDB.Model{} = model, %Context{} = context) do
    metadata = %{
      response_id: response.id,
      usage: response.usage,
      finish_reason: response.finish_reason,
      provider_meta: response.provider_meta
    }

    {:ok, metadata_handle} = MetadataHandle.start_link(fn -> metadata end)

    %StreamResponse{
      stream: response_to_chunks(response),
      metadata_handle: metadata_handle,
      cancel: fn -> :ok end,
      model: model,
      context: context
    }
  end

  @spec cache_opts(keyword()) :: keyword() | map()
  def cache_opts(opts) do
    Keyword.get(opts, :cache_options, [])
  end

  @spec request_opts(keyword()) :: keyword()
  def request_opts(opts) do
    Keyword.drop(opts, [:cache, :cache_key, :cache_ttl, :cache_options])
  end

  defp backend(opts) do
    case Keyword.get(opts, :cache) do
      nil ->
        :disabled

      backend when is_atom(backend) ->
        if cache_backend?(backend) do
          {:ok, backend}
        else
          {:error, {:invalid_backend, backend}}
        end

      backend ->
        {:error, {:invalid_backend, backend}}
    end
  end

  defp cache_backend?(backend) do
    Code.ensure_loaded?(backend) and
      function_exported?(backend, :get, 2) and
      function_exported?(backend, :put, 4) and
      function_exported?(backend, :delete, 2) and
      function_exported?(backend, :generate_key, 3)
  end

  defp cache_key(backend, model, request, opts) do
    Keyword.get_lazy(opts, :cache_key, fn ->
      backend.generate_key(model, request, cache_opts(opts))
    end)
  end

  defp merge_cached_response(%Response{} = response, %Context{} = context, opts) do
    response
    |> Map.put(:context, context)
    |> then(&Context.merge_response(context, &1, tools: Keyword.get(opts, :tools)))
  end

  defp cache_hit_response(%Response{} = response, %Context{} = context, opts) do
    merged_response = merge_cached_response(response, context, opts)
    provider_meta = Map.put(merged_response.provider_meta, :response_cache_hit, true)

    %{
      merged_response
      | usage: Usage.zero(merged_response.usage),
        provider_meta: provider_meta
    }
  end

  defp response_to_chunks(%Response{message: %Message{} = message}) do
    content_chunks =
      message.content
      |> Enum.map(fn
        %ContentPart{type: :text, text: text} -> StreamChunk.text(text)
        %ContentPart{type: :thinking, text: text} -> StreamChunk.thinking(text)
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)

    tool_call_chunks =
      message.tool_calls
      |> List.wrap()
      |> Enum.with_index()
      |> Enum.map(fn {tool_call, index} ->
        StreamChunk.tool_call(ToolCall.name(tool_call), ToolCall.args_map(tool_call) || %{}, %{
          id: tool_call.id,
          index: index
        })
      end)

    content_chunks ++ tool_call_chunks
  end

  defp response_to_chunks(_response), do: []
end
