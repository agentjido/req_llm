defmodule ReqLLM.Transport do
  @moduledoc false

  @adapter_key :req_llm_transport_adapter

  @spec attach(Req.Request.t()) :: Req.Request.t()
  def attach(%Req.Request{} = request) do
    receive_timeout = Map.get(request.options, :receive_timeout, 30_000)
    pool_timeout = if receive_timeout == :infinity, do: 30_000, else: receive_timeout
    pool_timeout = Map.get(request.options, :pool_timeout, pool_timeout)

    finch_options =
      request.options
      |> Map.to_list()
      |> Keyword.take([:finch])
      |> ReqLLM.Provider.Defaults.merge_finch_options(pool_timeout: pool_timeout)

    adapter =
      if is_function(Req.Request.new().adapter, 1), do: &__MODULE__.run/1, else: __MODULE__

    original_adapter = Req.Request.get_private(request, @adapter_key, request.adapter)

    request
    |> Req.Request.merge_options(finch_options)
    |> Req.Request.put_private(@adapter_key, original_adapter)
    |> Map.put(:adapter, adapter)
  end

  @spec run(Req.Request.t()) :: {Req.Request.t(), Req.Response.t() | Exception.t()}
  def run(%Req.Request{} = request) do
    case Req.Request.get_private(request, @adapter_key) do
      adapter when is_function(adapter, 1) -> adapter.(request)
      adapter when is_atom(adapter) -> adapter.run(request)
    end
  rescue
    exception in RuntimeError ->
      if finch_pool_timeout?(__STACKTRACE__) do
        {request,
         ReqLLM.Error.API.Request.exception(
           reason: Exception.message(exception),
           request_body: request.body,
           cause: exception
         )}
      else
        reraise exception, __STACKTRACE__
      end
  end

  defp finch_pool_timeout?([{NimblePool, :exit!, 3, _} | stacktrace]) do
    Enum.any?(stacktrace, fn
      {Finch.HTTP1.Pool, :request, 6, _} -> true
      _ -> false
    end)
  end

  defp finch_pool_timeout?(_stacktrace), do: false
end
