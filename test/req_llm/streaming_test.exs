defmodule ReqLLM.StreamingTest do
  use ExUnit.Case, async: true

  alias ReqLLM.{Context, Streaming}
  alias ReqLLM.Providers.{Anthropic, OpenAI}

  defmodule FailingHttpProvider do
    def attach_stream(_model, _context, _opts, _finch_name), do: {:error, :boom}
  end

  defmodule FailingWebSocketProvider do
    def stream_transport(_model, _opts), do: :websocket
    def attach_websocket_stream(_model, _context, _opts), do: {:error, :boom}
  end

  defmodule CustomOperationProvider do
    def attach_stream(_model, _context, opts, _finch_name) do
      {:error, {:provider_operation, opts[:operation]}}
    end
  end

  test "wraps HTTP transport startup failures" do
    {:ok, context} = Context.normalize("Hello")
    model = %LLMDB.Model{provider: :test, id: "test"}

    assert {:error, {:http_streaming_failed, {:provider_build_failed, :boom}}} =
             Streaming.start_stream(FailingHttpProvider, model, context, [])
  end

  test "wraps websocket transport startup failures" do
    {:ok, context} = Context.normalize("Hello")
    model = %LLMDB.Model{provider: :test, id: "test"}

    assert {:error, {:websocket_streaming_failed, {:provider_build_failed, :boom}}} =
             Streaming.start_stream(FailingWebSocketProvider, model, context, [])
  end

  test "retains the provider-owned OpenAI Chat WebSocket error" do
    model = %LLMDB.Model{
      provider: :openai,
      id: "gpt-4o",
      extra: %{wire: %{protocol: "openai_chat"}}
    }

    assert {:error, {:websocket_streaming_failed, {:provider_build_failed, error}}} =
             Streaming.start_stream(OpenAI, model, Context.new([Context.user("Hello")]),
               provider_options: [openai_stream_transport: :websocket]
             )

    assert %ReqLLM.Error.API.Request{} = error

    assert error.reason ==
             "OpenAI WebSocket mode is only supported for Responses models. " <>
               "openai:gpt-4o routes to ReqLLM.Providers.OpenAI.ChatAPI."
  end

  for {provider_id, provider} <- [openai: OpenAI, anthropic: Anthropic] do
    @provider_id provider_id
    @provider provider

    test "retains the provider-owned #{@provider_id} invalid wire error" do
      model = %LLMDB.Model{
        provider: @provider_id,
        id: "invalid-wire",
        extra: %{wire: %{protocol: "unsupported"}}
      }

      assert {:error, {:http_streaming_failed, {:provider_build_failed, error}}} =
               Streaming.start_stream(
                 @provider,
                 model,
                 Context.new([Context.user("Hello")])
               )

      assert %ReqLLM.Error.Invalid.Parameter{} = error

      assert error.parameter ==
               "wire protocol \"unsupported\" is invalid for provider #{inspect(@provider_id)}"
    end
  end

  test "passes a custom operation to the provider" do
    model = %LLMDB.Model{provider: :custom_operation, id: "model"}

    assert {:error,
            {:http_streaming_failed,
             {:provider_build_failed, {:provider_operation, :custom_operation}}}} =
             Streaming.start_stream(
               CustomOperationProvider,
               model,
               Context.new([Context.user("Hello")]),
               operation: :custom_operation
             )
  end

  test "retains the OpenAI Chat WebSocket error through public stream functions" do
    model = %LLMDB.Model{
      provider: :openai,
      id: "gpt-4o",
      extra: %{wire: %{protocol: "openai_chat"}}
    }

    opts = [api_key: "test-key", provider_options: [openai_stream_transport: :websocket]]

    results = [
      ReqLLM.stream_text(model, "Hello", opts),
      ReqLLM.stream_object(model, "Hello", [answer: [type: :string, required: true]], opts)
    ]

    for result <- results do
      assert {:error, {:websocket_streaming_failed, {:provider_build_failed, error}}} = result
      assert %ReqLLM.Error.API.Request{} = error
    end
  end
end
