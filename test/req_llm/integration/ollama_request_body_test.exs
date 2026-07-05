defmodule ReqLLM.Integration.OllamaRequestBodyTest do
  @moduledoc """
  Live integration test that round-trips a real request against a local Ollama.

  Regression coverage for the empty-request-body bug: the built-in `:ollama`
  provider used to send `Content-Length: 0` (the encoded JSON body never reached
  the outgoing request), so Ollama rejected every call with
  `400 {"error":{"message":"EOF","type":"invalid_request_error"}}`.

  This test is gated on a reachable Ollama instance and skipped otherwise, so it
  never breaks CI where no Ollama is running.

  Run with:

      mix test test/req_llm/integration/ollama_request_body_test.exs --include integration
  """

  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: 120_000

  @model "ollama:llama3.1"
  @base_url "http://localhost:11434"

  @ollama_up? match?(
                {:ok, %{status: 200}},
                Req.get(@base_url <> "/api/tags", retry: false, receive_timeout: 1_000)
              )

  if not @ollama_up? do
    @moduletag skip: "Local Ollama not reachable at #{@base_url}"
  end

  test "generate_text round-trips against live Ollama with a non-empty body" do
    case ReqLLM.generate_text(@model, "Reply with the single word: pong") do
      {:ok, response} ->
        assert %ReqLLM.Response{} = response
        text = ReqLLM.Response.text(response)
        assert is_binary(text)
        assert String.trim(text) != ""

      {:error, error} ->
        flunk("""
        Ollama rejected the request — likely an empty request body regression:
        #{inspect(error, pretty: true)}
        """)
    end
  end

  test "stream_text round-trips against live Ollama with a non-empty body" do
    case ReqLLM.stream_text(@model, "Reply with the single word: pong") do
      {:ok, stream_response} ->
        text = stream_response |> ReqLLM.StreamResponse.tokens() |> Enum.to_list() |> Enum.join()
        assert String.trim(text) != ""

      {:error, error} ->
        flunk("""
        Ollama rejected the streaming request — likely an empty request body regression
        in encode_stream_body/3 (missing Req.Steps.encode_body/1 materialization step):
        #{inspect(error, pretty: true)}
        """)
    end
  end
end
