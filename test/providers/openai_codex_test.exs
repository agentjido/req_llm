defmodule ReqLLM.Providers.OpenAICodexTest do
  @moduledoc """
  Provider-level tests for the OpenAI Codex backend implementation.
  """

  use ReqLLM.ProviderCase, provider: ReqLLM.Providers.OpenAICodex

  alias ReqLLM.Providers.OpenAICodex

  describe "provider contract" do
    test "provider identity and configuration" do
      assert OpenAICodex.provider_id() == :openai_codex
      assert OpenAICodex.oauth_provider_id() == "openai-codex"
      assert OpenAICodex.base_url() == "https://chatgpt.com/backend-api"
    end
  end

  describe "request preparation" do
    test "prepare_request routes to codex responses endpoint with oauth headers" do
      {:ok, model} = ReqLLM.model("openai_codex:gpt-5.3-codex-spark")

      {:ok, request} =
        OpenAICodex.prepare_request(:chat, model, "Summarize BHP",
          provider_options: [
            auth_mode: :oauth,
            access_token: jwt_with_account_id("acct_123"),
            codex_originator: "pi"
          ]
        )

      assert request.url.path == "/codex/responses"
      assert request.headers["authorization"] == ["Bearer #{jwt_with_account_id("acct_123")}"]
      assert request.headers["chatgpt-account-id"] == ["acct_123"]
      assert request.headers["originator"] == ["pi"]
    end

    test "prepare_request loads oauth_file without explicit auth_mode" do
      {:ok, model} = ReqLLM.model("openai_codex:gpt-5.3-codex-spark")
      path = oauth_file_path("prepare")

      on_exit(fn -> File.rm_rf(Path.dirname(path)) end)

      write_oauth_file(path, %{
        "openai-codex" => %{
          "type" => "oauth",
          "access" => jwt_with_account_id("acct_file_prepare"),
          "refresh" => "refresh-token-prepare",
          "expires" => future_expiry(),
          "accountId" => "acct_file_prepare"
        }
      })

      {:ok, request} =
        OpenAICodex.prepare_request(:chat, model, "Summarize BHP",
          provider_options: [oauth_file: path]
        )

      assert request.headers["authorization"] == [
               "Bearer #{jwt_with_account_id("acct_file_prepare")}"
             ]

      assert request.headers["chatgpt-account-id"] == ["acct_file_prepare"]
    end

    test "prepare_request rejects api_key auth mode" do
      {:ok, model} = ReqLLM.model("openai_codex:gpt-5.3-codex-spark")

      assert_raise ReqLLM.Error.Invalid.Parameter, fn ->
        OpenAICodex.prepare_request(:chat, model, "Hello",
          provider_options: [auth_mode: :api_key]
        )
      end
    end
  end

  describe "attach_stream/4" do
    test "builds SSE request against codex backend with instructions" do
      {:ok, model} = ReqLLM.model("openai_codex:gpt-5.3-codex-spark")

      context =
        ReqLLM.context([
          ReqLLM.Context.system("You are a mining analyst."),
          ReqLLM.Context.user("Tell me about FMG")
        ])

      {:ok, request} =
        OpenAICodex.attach_stream(
          model,
          context,
          [
            provider_options: [
              auth_mode: :oauth,
              access_token: jwt_with_account_id("acct_stream")
            ]
          ],
          nil
        )

      assert request.scheme == :https
      assert request.host == "chatgpt.com"
      assert request.path == "/backend-api/codex/responses"
      assert {"accept", "text/event-stream"} in request.headers
      assert {"openai-beta", "responses=experimental"} in request.headers

      body = Jason.decode!(request.body)

      assert body["instructions"] == "You are a mining analyst."
      assert body["model"] == "gpt-5.3-codex-spark"
      assert body["store"] == false
      assert body["include"] == ["reasoning.encrypted_content"]
      assert body["text"] == %{"verbosity" => "medium"}
      refute Map.has_key?(body, "max_output_tokens")
      assert Enum.all?(body["input"], &(&1["role"] != "system"))
    end

    test "loads oauth_file without explicit auth_mode for streaming" do
      {:ok, model} = ReqLLM.model("openai_codex:gpt-5.3-codex-spark")
      path = oauth_file_path("stream")

      on_exit(fn -> File.rm_rf(Path.dirname(path)) end)

      write_oauth_file(path, %{
        "openai-codex" => %{
          "type" => "oauth",
          "access" => jwt_with_account_id("acct_file_stream"),
          "refresh" => "refresh-token-stream",
          "expires" => future_expiry(),
          "accountId" => "acct_file_stream"
        }
      })

      context = ReqLLM.context([ReqLLM.Context.user("Tell me about FMG")])

      {:ok, request} =
        OpenAICodex.attach_stream(
          model,
          context,
          [provider_options: [oauth_file: path]],
          nil
        )

      assert {"authorization", "Bearer #{jwt_with_account_id("acct_file_stream")}"} in request.headers
      assert {"chatgpt-account-id", "acct_file_stream"} in request.headers
    end
  end

  describe "decode_stream_event/3" do
    test "normalizes response.done into a terminal response.completed chunk" do
      {:ok, model} = ReqLLM.model("openai_codex:gpt-5.3-codex-spark")

      event = %{
        data: %{
          "type" => "response.done",
          "response" => %{
            "id" => "resp_123",
            "status" => "completed",
            "usage" => %{"input_tokens" => 10, "output_tokens" => 4, "total_tokens" => 14}
          }
        }
      }

      {chunks, _state} = OpenAICodex.decode_stream_event(event, model, nil)

      assert [%ReqLLM.StreamChunk{type: :meta, metadata: metadata}] = chunks
      assert metadata[:terminal?] == true
      assert metadata[:response_id] == "resp_123"
      assert metadata[:finish_reason] == :stop
    end

    test "raises on response.failed events" do
      {:ok, model} = ReqLLM.model("openai_codex:gpt-5.3-codex-spark")

      event = %{
        data: %{
          "type" => "response.failed",
          "response" => %{"error" => %{"message" => "Codex response failed"}}
        }
      }

      assert_raise RuntimeError, "Codex response failed", fn ->
        OpenAICodex.decode_stream_event(event, model, nil)
      end
    end
  end

  describe "decode_response/1" do
    test "builds a normal response from a full SSE body" do
      {:ok, model} = ReqLLM.model("openai_codex:gpt-5.3-codex-spark")

      req = %Req.Request{
        options: [
          model: model.id,
          context: ReqLLM.context("Reply with exactly OK.")
        ]
      }

      body = """
      data: {"type":"response.output_text.delta","delta":"OK"}

      data: {"type":"response.done","response":{"id":"resp_live","status":"completed","usage":{"input_tokens":4,"output_tokens":1,"total_tokens":5}}}

      """

      resp = %Req.Response{status: 200, body: body}

      {_, decoded} = OpenAICodex.decode_response({req, resp})

      assert %ReqLLM.Response{} = decoded.body
      assert ReqLLM.Response.text(decoded.body) == "OK"
      assert decoded.body.finish_reason == :stop
      assert decoded.body.usage[:input_tokens] == 4
    end
  end

  defp jwt_with_account_id(account_id) do
    header =
      %{"alg" => "none", "typ" => "JWT"} |> Jason.encode!() |> Base.url_encode64(padding: false)

    payload =
      %{
        "https://api.openai.com/auth" => %{"chatgpt_account_id" => account_id}
      }
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)

    "#{header}.#{payload}.sig"
  end

  defp oauth_file_path(label) do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "req_llm_openai_codex_#{label}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    Path.join(tmp_dir, "oauth.json")
  end

  defp write_oauth_file(path, payload) do
    File.write!(path, Jason.encode_to_iodata!(payload, pretty: true))
  end

  defp future_expiry do
    System.system_time(:millisecond) + 60_000
  end
end
