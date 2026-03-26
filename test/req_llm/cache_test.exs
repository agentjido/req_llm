defmodule ReqLLM.CacheTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ReqLLM.{Cache, Context, Message, Response, StreamResponse, ToolCall}
  alias ReqLLM.Message.ContentPart

  defmodule TestBackend do
    def get(key, opts) do
      agent = Keyword.fetch!(opts, :agent)

      Agent.get(agent, fn entries ->
        case Map.fetch(entries, key) do
          {:ok, value} -> {:ok, value}
          :error -> {:error, :not_found}
        end
      end)
    end

    def put(key, value, _ttl, opts) do
      agent = Keyword.fetch!(opts, :agent)
      Agent.update(agent, &Map.put(&1, key, value))
      :ok
    end

    def delete(key, opts) do
      agent = Keyword.fetch!(opts, :agent)
      Agent.update(agent, &Map.delete(&1, key))
      :ok
    end

    def generate_key(model, request, _opts) do
      {model.id, request.operation, length(request.context.messages), request.schema}
    end
  end

  defmodule ErrorGetBackend do
    def get(_key, _opts), do: {:error, :boom}
    def put(_key, _value, _ttl, _opts), do: :ok
    def delete(_key, _opts), do: :ok
    def generate_key(_model, _request, _opts), do: :error_get
  end

  defmodule WeirdGetBackend do
    def get(_key, _opts), do: :weird
    def put(_key, _value, _ttl, _opts), do: :ok
    def delete(_key, _opts), do: :ok
    def generate_key(_model, _request, _opts), do: :weird_get
  end

  defmodule ErrorPutBackend do
    def get(_key, _opts), do: {:error, :not_found}
    def put(_key, _value, _ttl, _opts), do: {:error, :boom}
    def delete(_key, _opts), do: :ok
    def generate_key(_model, _request, _opts), do: :error_put
  end

  defmodule WeirdPutBackend do
    def get(_key, _opts), do: {:error, :not_found}
    def put(_key, _value, _ttl, _opts), do: :unexpected
    def delete(_key, _opts), do: :ok
    def generate_key(_model, _request, _opts), do: :weird_put
  end

  defmodule IncompleteBackend do
  end

  setup do
    {:ok, agent} = Agent.start_link(fn -> %{} end)
    model = ReqLLM.model!("openai:gpt-4o")
    context = Context.new([Context.user("Hello")])
    response = response_fixture(context, model)

    %{agent: agent, context: context, model: model, response: response}
  end

  describe "fetch/5" do
    test "returns a miss when caching is disabled", %{context: context, model: model} do
      assert {:miss, nil} = Cache.fetch(model, :chat, context, [])
    end

    test "returns a miss and logs when backend is not a module", %{context: context, model: model} do
      log =
        capture_log(fn ->
          assert {:miss, nil} = Cache.fetch(model, :chat, context, cache: "invalid")
        end)

      assert log =~ "ReqLLM cache disabled for this request"
      assert log =~ "invalid_backend"
    end

    test "returns a miss and logs when backend is incomplete", %{context: context, model: model} do
      log =
        capture_log(fn ->
          assert {:miss, nil} = Cache.fetch(model, :chat, context, cache: IncompleteBackend)
        end)

      assert log =~ "ReqLLM cache disabled for this request"
      assert log =~ "invalid_backend"
    end

    test "returns a cache hit for stored responses", %{
      agent: agent,
      context: context,
      model: model,
      response: response
    } do
      key = {model.id, :chat, length(context.messages), nil}
      Agent.update(agent, &Map.put(&1, key, response))

      assert {:hit, cached_response, %{backend: TestBackend, key: ^key}} =
               Cache.fetch(
                 model,
                 :chat,
                 context,
                 cache: TestBackend,
                 cache_options: [agent: agent]
               )

      assert cached_response.provider_meta.response_cache_hit == true
      assert cached_response.usage.input_tokens == 0
      assert cached_response.usage.output_tokens == 0
      assert cached_response.context.messages |> List.last() |> Map.get(:role) == :assistant
    end

    test "logs backend get errors and returns a miss", %{context: context, model: model} do
      log =
        capture_log(fn ->
          assert {:miss, %{backend: ErrorGetBackend, key: :error_get}} =
                   Cache.fetch(model, :chat, context, cache: ErrorGetBackend)
        end)

      assert log =~ "ReqLLM cache get failed"
      assert log =~ ":boom"
    end

    test "logs unexpected backend get values and returns a miss", %{
      context: context,
      model: model
    } do
      log =
        capture_log(fn ->
          assert {:miss, %{backend: WeirdGetBackend, key: :weird_get}} =
                   Cache.fetch(model, :chat, context, cache: WeirdGetBackend)
        end)

      assert log =~ "ReqLLM cache get returned unexpected value"
      assert log =~ ":weird"
    end
  end

  describe "store/3" do
    test "logs backend put errors and returns the original response", %{response: response} do
      log =
        capture_log(fn ->
          assert Cache.store(%{backend: ErrorPutBackend, key: :key}, response, []) == response
        end)

      assert log =~ "ReqLLM cache put failed"
      assert log =~ ":boom"
    end

    test "logs unexpected backend put values and returns the original response", %{
      response: response
    } do
      log =
        capture_log(fn ->
          assert Cache.store(%{backend: WeirdPutBackend, key: :key}, response, []) == response
        end)

      assert log =~ "ReqLLM cache put returned unexpected value"
      assert log =~ ":unexpected"
    end

    test "passes through cache and request options" do
      opts = [
        cache: TestBackend,
        cache_key: :custom,
        cache_ttl: 300,
        cache_options: [namespace: "chat"],
        temperature: 0.7
      ]

      assert Cache.cache_opts(opts) == [namespace: "chat"]
      assert Cache.request_opts(opts) == [temperature: 0.7]
    end
  end

  describe "stream_response/3" do
    test "replays cached responses as stream responses with metadata", %{
      context: context,
      model: model,
      response: response
    } do
      stream_response = Cache.stream_response(response, model, context)

      assert %StreamResponse{} = stream_response
      assert StreamResponse.usage(stream_response) == response.usage
      assert StreamResponse.finish_reason(stream_response) == :tool_calls

      chunks = Enum.to_list(stream_response.stream)

      assert Enum.map(chunks, & &1.type) == [:content, :thinking, :tool_call]
      assert Enum.at(chunks, 0).text == "Hello"
      assert Enum.at(chunks, 1).text == "Working"
      assert Enum.at(chunks, 2).name == "search"
      assert Enum.at(chunks, 2).arguments == %{"q" => "Hello"}
      assert Enum.at(chunks, 2).metadata == %{id: "call_1", index: 0}
      assert stream_response.cancel.() == :ok
    end
  end

  defp response_fixture(context, model) do
    %Response{
      id: "resp_123",
      model: model.id,
      context: context,
      message: %Message{
        role: :assistant,
        content: [ContentPart.text("Hello"), ContentPart.thinking("Working")],
        tool_calls: [ToolCall.new("call_1", "search", ~s({"q":"Hello"}))],
        metadata: %{}
      },
      usage: %{input_tokens: 2, output_tokens: 3, total_tokens: 5, cached_tokens: 0},
      finish_reason: "tool_use",
      provider_meta: %{source: :cache}
    }
  end
end
