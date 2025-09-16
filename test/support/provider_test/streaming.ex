defmodule ReqLLM.ProviderTest.Streaming do
  @moduledoc """
  Streaming text generation tests.

  Tests stream-based generation features:
  - Basic streaming with text chunks
  - Stream interruption and error handling
  - Chunk validation and parsing
  - Stream completion and termination
  """

  defmacro __using__(opts) do
    provider = Keyword.fetch!(opts, :provider)
    model = Keyword.fetch!(opts, :model)

    quote bind_quoted: [provider: provider, model: model] do
      use ExUnit.Case, async: false

      @moduletag :capture_log
      @moduletag :coverage
      @moduletag category: :streaming
      @moduletag provider: provider

      describe "streaming text generation" do
        test "basic streaming completion returns chunks" do
          {:ok, response} =
            ReqLLM.stream_text(
              unquote(model),
              "Say hello briefly",
              max_tokens: 10,
              fixture: "#{unquote(provider)}_streaming_test"
            )

          # In both LIVE and REPLAY modes, we should get a streaming response
          assert response.stream?
          assert response.stream

          # Collect all chunks from the stream
          chunks = Enum.to_list(response.stream)

          # Basic validations
          assert is_list(chunks)
          refute Enum.empty?(chunks)

          # Verify chunks are proper StreamChunk structs
          assert Enum.all?(chunks, fn chunk ->
                   match?(%ReqLLM.StreamChunk{}, chunk)
                 end)

          # Verify at least one chunk has text content (including thinking for reasoning models)
          assert Enum.any?(chunks, fn chunk ->
                   chunk.type in [:text, :content, :thinking] and is_binary(chunk.text) and
                     chunk.text != ""
                 end)

          # Test that we can join the stream to get final response
          {:ok, joined_response} = ReqLLM.Response.join_stream(response)
          assert joined_response.message
          assert joined_response.message.content

          # Verify we have some text content
          text = ReqLLM.Response.text(joined_response)
          assert is_binary(text)
          assert String.length(text) > 0
        end

        test "longer streaming response with many chunks" do
          {:ok, response} =
            ReqLLM.stream_text(
              unquote(model),
              "Write a brief explanation of how machine learning works. Include supervised learning and neural networks.",
              max_tokens: 200,
              fixture: "#{unquote(provider)}_long_streaming_test"
            )

          # In both LIVE and REPLAY modes, we should get a streaming response
          assert response.stream?
          assert response.stream

          # Collect all chunks from the stream
          chunks = Enum.to_list(response.stream)

          # Basic validations - expect more chunks for longer response
          assert is_list(chunks)
          refute Enum.empty?(chunks)

          # For a longer response, we should have multiple chunks
          if System.get_env("LIVE") do
            # In LIVE mode, we might get many chunks
            IO.puts("LIVE mode: Got #{length(chunks)} chunks from long streaming response")
          else
            # In replay mode, we should have the same number
            assert length(chunks) > 1,
                   "Expected more than 1 chunk for long response, got #{length(chunks)}"
          end

          # Verify chunks are proper StreamChunk structs
          assert Enum.all?(chunks, fn chunk ->
                   match?(%ReqLLM.StreamChunk{}, chunk)
                 end)

          # Verify multiple chunks have text content (not just the first one)
          text_chunks =
            Enum.filter(chunks, fn chunk ->
              chunk.type in [:text, :content, :thinking] and is_binary(chunk.text) and
                chunk.text != ""
            end)

          assert not Enum.empty?(text_chunks),
                 "Expected at least one text chunk for long response"

          # Test that we can join the stream to get final response
          {:ok, joined_response} = ReqLLM.Response.join_stream(response)
          assert joined_response.message
          assert joined_response.message.content

          # Verify we have substantial text content for the longer response
          text = ReqLLM.Response.text(joined_response)
          assert is_binary(text)

          assert String.length(text) > 20,
                 "Expected substantial content for long response, got #{String.length(text)} characters"
        end

        test "stream_text! returns immediately (LIVE timing test)" do
          # Test timing in LIVE mode or when replay timing is enabled
          timing_enabled =
            System.get_env("LIVE") ||
              System.get_env("REPLAY_STREAM_DELAY_MS", "0") |> String.to_integer() > 0 ||
              System.get_env("REPLAY_STREAM_ACCEL", "0.0") |> String.to_float() > 0.0

          if timing_enabled do
            # Test the bang variant with timing to ensure it returns a true stream
            start = System.monotonic_time(:millisecond)

            stream =
              ReqLLM.stream_text!(
                unquote(model),
                "Write a detailed explanation of quantum computing, including qubits, superposition, and quantum algorithms. Make it comprehensive.",
                max_tokens: 400,
                fixture: "#{unquote(provider)}_timing_test"
              )

            elapsed = System.monotonic_time(:millisecond) - start

            # The function should return immediately, not block until completion
            assert elapsed < 500,
                   "stream_text! should return immediately, took #{elapsed}ms (likely blocking until full response)"

            # Verify we got a stream
            assert match?(%Stream{}, stream)

            # Verify stream is actually lazy by consuming just the first chunk
            first_chunk = stream |> Stream.take(1) |> Enum.to_list()
            assert first_chunk != [], "Expected at least one chunk in stream"
            assert is_binary(first_chunk |> hd()), "First chunk should be text"

            IO.puts("LIVE timing test: stream_text! returned in #{elapsed}ms")
          else
            # In replay mode, just test basic functionality (timing is meaningless)
            stream =
              ReqLLM.stream_text!(
                unquote(model),
                "Write a detailed explanation of quantum computing.",
                max_tokens: 400,
                fixture: "#{unquote(provider)}_timing_test"
              )

            assert match?(%Stream{}, stream)

            # Verify we can consume the stream
            chunks = stream |> Stream.take(5) |> Enum.to_list()
            assert is_list(chunks)
            refute Enum.empty?(chunks)
            assert Enum.all?(chunks, &is_binary/1), "All chunks should be text strings"
          end
        end
      end
    end
  end
end
