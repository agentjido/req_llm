defmodule ReqLLM.Provider.Adapter do
  @moduledoc false

  @doc """
  Selects the existing provider for an already resolved model. Chat, object, and
  rerank requests can use the catalog gateway fallback; all other operations retain
  the provider registry lookup. `dispatch_opts` are the existing dispatch options,
  currently `[]` for buffered requests or `[stream: true]` for streams, not the
  complete request options. Preserve each call site's dispatch options when
  migrating it; they reach ProviderDispatch unchanged.
  """
  @spec resolve(LLMDB.Model.t(), atom(), keyword()) :: {:ok, module()} | {:error, term()}
  def resolve(model, operation, dispatch_opts \\ [])

  def resolve(%LLMDB.Model{} = model, operation, dispatch_opts)
      when operation in [:chat, :object, :rerank] do
    ReqLLM.ProviderDispatch.get(model, operation, dispatch_opts)
  end

  def resolve(%LLMDB.Model{} = model, _operation, _dispatch_opts) do
    ReqLLM.provider(model.provider)
  end

  @doc """
  Calls the v1 preparation callback without resolving the model, processing
  options, or changing the provider's result. The provider still owns its Req
  pipeline, including attachment, encoding, decoding, and option translation.
  """
  @spec prepare_request(module(), atom(), term(), term(), keyword()) ::
          {:ok, Req.Request.t()} | {:error, term()}
  def prepare_request(provider_module, operation, model, input, opts) do
    provider_module.prepare_request(operation, model, input, opts)
  end

  @doc """
  Returns the provider's stream transport or the existing HTTP fallback.
  Optional callback checks deliberately do not load the provider module.
  """
  @spec stream_transport(module(), LLMDB.Model.t(), keyword()) :: :http | :websocket | :in_process
  def stream_transport(provider_module, model, opts) do
    if function_exported?(provider_module, :stream_transport, 2) do
      provider_module.stream_transport(model, opts)
    else
      :http
    end
  end

  @doc """
  Returns the request-specific protocol parser or nil, leaving the fallback to
  the existing stream decoder. This does not load the provider module.
  """
  @spec stream_protocol_parser(module(), LLMDB.Model.t(), keyword()) :: function() | nil
  def stream_protocol_parser(provider_module, model, opts) do
    if function_exported?(provider_module, :stream_protocol_parser, 2) do
      provider_module.stream_protocol_parser(model, opts)
    end
  end

  @doc """
  Calls the Finch startup callback directly, as the current Finch client does.
  A missing callback still raises UndefinedFunctionError. Provider defaults,
  including the legacy streaming_http/3 hook, remain provider-owned.
  """
  @spec attach_stream(module(), LLMDB.Model.t(), ReqLLM.Context.t(), keyword(), atom()) ::
          {:ok, Finch.Request.t()} | {:error, term()}
  def attach_stream(provider_module, model, context, opts, finch_name) do
    provider_module.attach_stream(model, context, opts, finch_name)
  end

  @doc """
  Calls the in-process startup callback without enumerating or normalizing its
  result. Missing callbacks retain the client's existing missing_callback tuple.
  Detection does not load the provider module.
  """
  @spec attach_in_process_stream(module(), LLMDB.Model.t(), ReqLLM.Context.t(), keyword()) ::
          {:ok, Enumerable.t() | ReqLLM.Provider.InProcessStream.t()} | {:error, term()}
  def attach_in_process_stream(provider_module, model, context, opts) do
    if function_exported?(provider_module, :attach_in_process_stream, 3) do
      provider_module.attach_in_process_stream(model, context, opts)
    else
      {:error, {:missing_callback, :attach_in_process_stream, 3}}
    end
  end

  @doc """
  Calls the existing WebSocket hook without changing its configuration. A missing
  hook returns false, matching the current client's callback guard; the client
  retains ownership of its model-specific error and transport error wrappers.
  Detection does not load the provider module.
  """
  @spec attach_websocket_stream(module(), LLMDB.Model.t(), ReqLLM.Context.t(), keyword()) ::
          {:ok, map()} | {:error, term()} | false
  def attach_websocket_stream(provider_module, model, context, opts) do
    with true <- function_exported?(provider_module, :attach_websocket_stream, 3) do
      provider_module.attach_websocket_stream(model, context, opts)
    end
  end
end
