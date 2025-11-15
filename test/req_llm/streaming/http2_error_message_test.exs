defmodule ReqLLM.Streaming.HTTP2ErrorMessageTest do
  use ReqLLM.StreamingCase

  import ExUnit.CaptureLog

  alias ReqLLM.Context

  describe "HTTP/2 error message formatting" do
    test "logs helpful error message when large body sent to HTTP/2 pool" do
      configure_http2_pools!()

      {:ok, model} = ReqLLM.model("openai:gpt-4o")
      large_prompt = String.duplicate("Large content ", 5000)
      {:ok, context} = Context.normalize(large_prompt)

      log =
        capture_log(fn ->
          result = ReqLLM.Streaming.start_stream(ReqLLM.Providers.OpenAI, model, context, [])

          assert {:error, {:http2_body_too_large, message}} = result
          assert message =~ "Request body"
          assert message =~ "exceeds safe limit for HTTP/2 connections (64KB)"
          assert message =~ "https://github.com/sneako/finch/issues/265"
          assert message =~ "config :req_llm"
          assert message =~ "protocols: [:http1]"
          assert message =~ "README"
        end)

      assert log =~ "Request body"
      assert log =~ "exceeds safe limit"
    end

    test "succeeds with HTTP/1-only pools (default config)" do
      configure_http1_pools!()

      {:ok, model} = ReqLLM.model("openai:gpt-4o")
      large_prompt = String.duplicate("Large content ", 5000)
      {:ok, context} = Context.normalize(large_prompt)

      result = ReqLLM.Streaming.start_stream(ReqLLM.Providers.OpenAI, model, context, [])

      assert {:ok, _stream_response} = result
    end
  end
end
