defmodule ReqLLM.Providers.GoogleVertex.ResponseTest do
  use ExUnit.Case, async: true

  @model "google_vertex:gemini-2.5-flash"
  @provider_options [
    access_token: "test-token",
    project_id: "test-project",
    region: "us-central1"
  ]

  test "generate_text/3 returns a structured error for a plain-text 503" do
    body =
      "upstream connect error or disconnect/reset before headers. reset reason: connection termination"

    Req.Test.stub(__MODULE__.PlainTextError, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/plain")
      |> Plug.Conn.send_resp(503, body)
    end)

    assert {:error, %ReqLLM.Error.API.Request{} = error} =
             generate(__MODULE__.PlainTextError, max_retries: 0)

    assert error.status == 503
    assert error.response_body == body
    assert error.reason == "Provider response error (503): Google Vertex API error"
  end

  for {family, model, stub} <- [
        {"Anthropic", "google_vertex:claude-haiku-4-5@20251001", __MODULE__.AnthropicError},
        {"OpenAI-compatible", "google_vertex:zai-org/glm-4.7-maas", __MODULE__.OpenAICompatError}
      ] do
    test "generate_text/3 bypasses the #{family} formatter for non-2xx responses" do
      body = "temporarily unavailable"
      stub = unquote(stub)

      Req.Test.stub(stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.send_resp(503, body)
      end)

      assert {:error, %ReqLLM.Error.API.Request{status: 503, response_body: ^body}} =
               generate_for(unquote(model), stub, max_retries: 0)
    end
  end

  test "generate_text/3 preserves a JSON error body and its HTTP status" do
    body = %{
      "error" => %{
        "code" => 429,
        "message" => "Quota exceeded",
        "status" => "RESOURCE_EXHAUSTED"
      }
    }

    Req.Test.stub(__MODULE__.JSONError, fn conn ->
      conn
      |> Plug.Conn.put_status(429)
      |> Req.Test.json(body)
    end)

    assert {:error, %ReqLLM.Error.API.Request{} = error} =
             generate(__MODULE__.JSONError, max_retries: 0)

    assert error.status == 429
    assert error.response_body == body
  end

  test "generate_text/3 preserves successful Gemini response decoding" do
    Req.Test.stub(__MODULE__.Success, &Req.Test.json(&1, success_body()))

    assert {:ok, response} = generate(__MODULE__.Success)
    assert ReqLLM.Response.text(response) == "Hello from Vertex"
  end

  test "generate_text/3 still retries a transient response before decoding" do
    attempts = :atomics.new(1, [])

    Req.Test.stub(__MODULE__.Retry, fn conn ->
      case :atomics.add_get(attempts, 1, 1) do
        1 ->
          conn
          |> Plug.Conn.put_resp_header("retry-after", "0")
          |> Plug.Conn.send_resp(503, "temporarily unavailable")

        2 ->
          Req.Test.json(conn, success_body())
      end
    end)

    assert {:ok, response} = generate(__MODULE__.Retry, max_retries: 1)
    assert ReqLLM.Response.text(response) == "Hello from Vertex"
    assert :atomics.get(attempts, 1) == 2
  end

  defp generate(stub, opts \\ []) do
    generate_for(@model, stub, opts)
  end

  defp generate_for(model, stub, opts) do
    ReqLLM.generate_text(
      model,
      "hi",
      Keyword.merge(
        [provider_options: @provider_options, req_http_options: [plug: {Req.Test, stub}]],
        opts
      )
    )
  end

  defp success_body do
    %{
      "candidates" => [
        %{
          "content" => %{
            "role" => "model",
            "parts" => [%{"text" => "Hello from Vertex"}]
          },
          "finishReason" => "STOP"
        }
      ],
      "usageMetadata" => %{
        "promptTokenCount" => 1,
        "candidatesTokenCount" => 3,
        "totalTokenCount" => 4
      }
    }
  end
end
