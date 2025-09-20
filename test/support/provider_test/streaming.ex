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
      end
    end
  end
end
