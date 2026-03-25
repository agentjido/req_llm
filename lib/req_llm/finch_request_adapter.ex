defmodule ReqLLM.FinchRequestAdapter do
  @moduledoc """
  Behaviour for transforming `Finch.Request` structs just before a streaming
  request is sent.

  This is the config-level counterpart to the per-request `on_finch_request`
  option. Because config files cannot hold anonymous functions, the adapter
  must be a module that implements this behaviour.

  It is particularly useful for environment-specific concerns that should apply
  globally — for example injecting trace headers in a test environment — without
  touching individual call sites.

  ## Precedence

  Both mechanisms can be combined. The config-level adapter is applied first,
  then the per-request `on_finch_request` callback (if given). Each step
  receives the output of the previous one.

  ## Configuration

      # config/test.exs
      config :req_llm, finch_request_adapter: MyApp.TestFinchAdapter

  ## Example

      defmodule MyApp.TestFinchAdapter do
        @behaviour ReqLLM.FinchRequestAdapter

        @impl true
        def call(%Finch.Request{} = request) do
          %{request | headers: request.headers ++ [{"x-test-env", "true"}]}
        end
      end

  """

  @doc """
  Transform a `Finch.Request` just before it is sent.

  The request has already been fully built by the provider (authentication,
  body encoding, base headers). Return a `Finch.Request` — either the original
  or a modified copy.
  """
  @callback call(Finch.Request.t()) :: Finch.Request.t()
end
