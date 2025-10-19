defmodule ReqLLM.Streaming.HTTP2ErrorMessageTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ReqLLM.{Model, Context}

  describe "HTTP/2 error message formatting" do
    setup do
      on_exit(fn ->
        Application.put_env(:req_llm, :finch, get_original_config())
      end)

      :ok
    end

    test "logs helpful error message when large body sent to HTTP/2 pool" do
      configure_http2_pools()

      {:ok, model} = Model.from("openai:gpt-4o")
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
      configure_http1_pools()

      {:ok, model} = Model.from("openai:gpt-4o")
      large_prompt = String.duplicate("Large content ", 5000)
      {:ok, context} = Context.normalize(large_prompt)

      result = ReqLLM.Streaming.start_stream(ReqLLM.Providers.OpenAI, model, context, [])

      assert {:ok, _stream_response} = result
    end
  end

  defp configure_http2_pools do
    Application.put_env(:req_llm, :finch,
      name: ReqLLM.Finch,
      pools: %{
        default: [protocols: [:http2, :http1], size: 1, count: 8]
      }
    )
  end

  defp configure_http1_pools do
    Application.put_env(:req_llm, :finch,
      name: ReqLLM.Finch,
      pools: %{
        default: [protocols: [:http1], size: 1, count: 8]
      }
    )
  end

  defp get_original_config do
    Application.get_env(:req_llm, :finch, [])
  end
end
