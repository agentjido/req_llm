defmodule ReqLLM.Streaming.HTTP2ValidationTest do
  use ReqLLM.StreamingCase

  alias ReqLLM.Context
  alias ReqLLM.Streaming.FinchClient

  @pool_match_base_url "https://pool-match.example.com/v1"
  @pool_match_origin "https://pool-match.example.com"

  describe "HTTP/2 body size validation" do
    test "allows small request bodies with HTTP/2 pools" do
      configure_http2_pools!()

      {:ok, model} = ReqLLM.model("openai:gpt-4o")
      small_prompt = "Hello, this is a small prompt"
      {:ok, context} = Context.normalize(small_prompt)

      result = start_mock_stream(model, context)

      assert {:ok, _task_pid, _http_context, _canonical_json} = result
    end

    test "allows large request bodies (>64KB) with HTTP/2-only pools" do
      configure_http2_only_pools!()

      {:ok, model} = ReqLLM.model("openai:gpt-4o")
      large_prompt = String.duplicate("This is a large prompt. ", 3000)
      {:ok, context} = Context.normalize(large_prompt)

      result = start_mock_stream(model, context)

      assert {:ok, _task_pid, _http_context, _canonical_json} = result
    end

    test "blocks large request bodies (>64KB) with mixed HTTP/1 and HTTP/2 pools" do
      configure_http2_pools!()

      {:ok, model} = ReqLLM.model("openai:gpt-4o")
      large_prompt = String.duplicate("This is a large prompt. ", 3000)
      {:ok, context} = Context.normalize(large_prompt)

      result = start_mock_stream(model, context)

      assert {:error, {:provider_build_failed, {:http2_body_too_large, body_size, protocols}}} =
               result

      assert body_size > 65_535
      assert :http2 in protocols
    end

    test "blocks large request bodies with mixed protocol origin-specific Finch pool" do
      configure_pools!(%{
        :default => [protocols: [:http1], size: 1, count: 8],
        Finch.Pool.new(@pool_match_origin) => [
          protocols: [:http2, :http1],
          size: 1,
          count: 8
        ]
      })

      {:ok, model} = ReqLLM.model("openai:gpt-4o")
      large_prompt = String.duplicate("This is a large prompt. ", 3000)
      {:ok, context} = Context.normalize(large_prompt)

      result = start_mock_stream(model, context, base_url: @pool_match_base_url)

      assert {:error, {:provider_build_failed, {:http2_body_too_large, _body_size, protocols}}} =
               result

      assert protocols == [:http2, :http1]
    end

    test "blocks large request bodies with mixed protocol URL string Finch pool" do
      configure_pools!(%{
        :default => [protocols: [:http1], size: 1, count: 8],
        @pool_match_origin => [protocols: [:http1, :http2], size: 1, count: 8]
      })

      {:ok, model} = ReqLLM.model("openai:gpt-4o")
      large_prompt = String.duplicate("This is a large prompt. ", 3000)
      {:ok, context} = Context.normalize(large_prompt)

      result = start_mock_stream(model, context, base_url: @pool_match_base_url)

      assert {:error, {:provider_build_failed, {:http2_body_too_large, _body_size, protocols}}} =
               result

      assert protocols == [:http1, :http2]
    end

    test "allows large request bodies when origin-specific pool is HTTP/2-only" do
      configure_pools!(%{
        :default => [protocols: [:http2, :http1], size: 1, count: 8],
        Finch.Pool.new(@pool_match_origin) => [protocols: [:http2], size: 1, count: 8]
      })

      {:ok, model} = ReqLLM.model("openai:gpt-4o")
      large_prompt = String.duplicate("This is a large prompt. ", 3000)
      {:ok, context} = Context.normalize(large_prompt)

      result = start_mock_stream(model, context, base_url: @pool_match_base_url)

      assert {:ok, _task_pid, _http_context, _canonical_json} = result
    end

    test "allows large request bodies with HTTP/1-only pools (default)" do
      configure_http1_pools!()

      {:ok, model} = ReqLLM.model("openai:gpt-4o")
      large_prompt = String.duplicate("This is a large prompt. ", 3000)
      {:ok, context} = Context.normalize(large_prompt)

      result = start_mock_stream(model, context)

      assert {:ok, _task_pid, _http_context, _canonical_json} = result
    end

    test "error is caught by streaming module and logged" do
      configure_http2_pools!()

      {:ok, model} = ReqLLM.model("openai:gpt-4o")
      large_prompt = String.duplicate("Large content ", 5000)
      {:ok, context} = Context.normalize(large_prompt)

      result = start_mock_stream(model, context)

      assert {:error, {:provider_build_failed, {:http2_body_too_large, _body_size, _protocols}}} =
               result
    end
  end

  defmodule MockStreamServer do
    use GenServer

    def start_link do
      GenServer.start_link(__MODULE__, [])
    end

    def init(_), do: {:ok, []}

    def handle_call({:http_event, _event}, _from, state) do
      {:reply, :ok, state}
    end
  end

  defp start_mock_stream(model, context, opts \\ []) do
    {:ok, stream_server} = MockStreamServer.start_link()

    FinchClient.start_stream(
      ReqLLM.Providers.OpenAI,
      model,
      context,
      opts,
      stream_server
    )
  end
end
