defmodule ReqLLM.Providers.Anthropic.ResponseDecodingTest do
  @moduledoc """
  Tests Anthropic non-streaming response normalization and usage extraction.
  """

  use ReqLLM.ProviderCase, provider: ReqLLM.Providers.Anthropic, async: true

  alias ReqLLM.Providers.Anthropic

  describe "response decoding & normalization" do
    test "malformed token counters survive decoding and remain unpriced" do
      model = ReqLLM.model!("anthropic:claude-haiku-4-5-20251001")

      for key <- ["input_tokens", "output_tokens"],
          invalid <- [nil, false, -1, "invalid", [], %{}] do
        body = %{
          "id" => "msg_invalid_usage",
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => "OK"}],
          "stop_reason" => "end_turn",
          "usage" => Map.put(%{"input_tokens" => 11, "output_tokens" => 4}, key, invalid)
        }

        assert {:ok, response} = ReqLLM.Providers.Anthropic.Response.decode_response(body, model)
        assert response.usage[String.to_existing_atom(key)] == invalid
        assert response.usage.total_tokens == nil

        usage = ReqLLM.Usage.normalize(response.usage)

        priced =
          ReqLLM.Usage.Cost.apply(usage, model,
            pricing_context: %{api: "chat", inference_geo: "global"}
          )

        assert priced.pricing.status == :unknown
        refute Map.has_key?(priced, :total_cost)
      end
    end

    test "decode_response handles non-streaming responses" do
      # Create a mock Anthropic-format response
      mock_json_response = anthropic_format_json_fixture()

      # Create a mock Req response
      mock_resp = %Req.Response{
        status: 200,
        body: mock_json_response
      }

      # Create a mock request with context
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")
      context = context_fixture()

      mock_req = %Req.Request{
        options: [context: context, stream: false, id: "anthropic:claude-sonnet-4-5-20250929"]
      }

      # Test decode_response directly
      {req, resp} = Anthropic.decode_response({mock_req, mock_resp})

      assert req == mock_req
      assert %ReqLLM.Response{} = resp.body

      response = resp.body
      assert is_binary(response.id)
      assert response.model == model.model
      assert response.stream? == false

      # Verify message normalization
      assert response.message.role == :assistant
      text = ReqLLM.Response.text(response)
      assert is_binary(text)
      assert String.length(text) > 0
      assert response.finish_reason in [:stop, :length]

      # Verify usage normalization
      assert is_integer(response.usage.input_tokens)
      assert is_integer(response.usage.output_tokens)
      assert is_integer(response.usage.total_tokens)

      # Verify context advancement (original + assistant)
      assert length(response.context.messages) == 3
      assert List.last(response.context.messages).role == :assistant
    end

    test "decode_response normalizes the full set of Anthropic stop_reasons" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      decode = fn stop_reason ->
        data = %{
          "id" => "msg_01ABC123",
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => "ok"}],
          "stop_reason" => stop_reason,
          "usage" => %{"input_tokens" => 5, "output_tokens" => 2}
        }

        {:ok, response} = ReqLLM.Providers.Anthropic.Response.decode_response(data, model)
        response.finish_reason
      end

      assert decode.("end_turn") == :stop
      assert decode.("stop_sequence") == :stop
      assert decode.("max_tokens") == :length
      assert decode.("model_context_window_exceeded") == :length
      assert decode.("tool_use") == :tool_calls
      assert decode.("pause_turn") == :incomplete
      assert decode.("refusal") == :content_filter
      assert decode.("some_future_reason") == :unknown
    end

    test "decode_response keeps the provider's stop_reason in provider_meta" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      data = %{
        "id" => "msg_01ABC123",
        "type" => "message",
        "role" => "assistant",
        "content" => [
          %{
            "type" => "server_tool_use",
            "id" => "srvtoolu_1",
            "name" => "web_search",
            "input" => %{"query" => "weather"}
          }
        ],
        "stop_reason" => "pause_turn",
        "usage" => %{"input_tokens" => 5, "output_tokens" => 2}
      }

      {:ok, response} = ReqLLM.Providers.Anthropic.Response.decode_response(data, model)

      assert response.finish_reason == :incomplete
      assert response.provider_meta["stop_reason"] == "pause_turn"
    end

    test "decode_response reads thinking tokens from output_tokens_details" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      decode = fn usage ->
        data = %{
          "id" => "msg_01ABC123",
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => "ok"}],
          "stop_reason" => "end_turn",
          "usage" => usage
        }

        {:ok, response} = ReqLLM.Providers.Anthropic.Response.decode_response(data, model)
        response.usage.reasoning_tokens
      end

      # The shape the Messages API actually returns for adaptive thinking.
      assert decode.(%{
               "input_tokens" => 5,
               "output_tokens" => 210,
               "output_tokens_details" => %{"thinking_tokens" => 192}
             }) == 192

      # The pre-existing top-level field keeps working.
      assert decode.(%{
               "input_tokens" => 5,
               "output_tokens" => 210,
               "reasoning_output_tokens" => 192
             }) == 192

      # Absent from both places: zero rather than nil.
      assert decode.(%{"input_tokens" => 5, "output_tokens" => 2}) == 0
    end

    test "decode_response handles API errors with non-200 status" do
      # Create error response
      error_body = %{
        "type" => "error",
        "error" => %{
          "type" => "authentication_error",
          "message" => "Invalid API key"
        }
      }

      mock_resp = %Req.Response{
        status: 401,
        body: error_body
      }

      context = context_fixture()

      mock_req = %Req.Request{
        options: [context: context, id: "claude-sonnet-4-5-20250929"]
      }

      # Test decode_response error handling
      {req, error} = Anthropic.decode_response({mock_req, mock_resp})

      assert req == mock_req
      assert %ReqLLM.Error.API.Response{} = error
      assert error.status == 401
      assert error.reason =~ "Anthropic API error"
      assert error.response_body == error_body
    end
  end

  describe "usage extraction" do
    test "extract_usage with valid usage data" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      body_with_usage = %{
        "usage" => %{
          "input_tokens" => 10,
          "output_tokens" => 20
        }
      }

      {:ok, usage} = Anthropic.extract_usage(body_with_usage, model)
      assert usage["input_tokens"] == 10
      assert usage["output_tokens"] == 20
    end

    test "extract_usage includes web_fetch tool usage" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      body_with_usage = %{
        "usage" => %{
          "input_tokens" => 10,
          "output_tokens" => 20,
          "server_tool_use" => %{"web_fetch_requests" => 2}
        }
      }

      {:ok, usage} = Anthropic.extract_usage(body_with_usage, model)
      assert usage[:tool_usage][:web_fetch][:count] == 2
      assert usage[:tool_usage][:web_fetch][:unit] == :call
    end

    test "extract_usage with missing usage data" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")
      body_without_usage = %{"content" => []}

      {:error, :no_usage_found} = Anthropic.extract_usage(body_without_usage, model)
    end

    test "extract_usage with invalid body type" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      {:error, :invalid_body} = Anthropic.extract_usage("invalid", model)
      {:error, :invalid_body} = Anthropic.extract_usage(nil, model)
      {:error, :invalid_body} = Anthropic.extract_usage(123, model)
    end
  end

  # Helper functions for Anthropic-specific fixtures

  defp anthropic_format_json_fixture(opts \\ []) do
    %{
      "id" => Keyword.get(opts, :id, "msg_01XFDUDYJgAACzvnptvVoYEL"),
      "type" => "message",
      "role" => "assistant",
      "model" => Keyword.get(opts, :model, "claude-sonnet-4-5-20250929"),
      "content" => [
        %{
          "type" => "text",
          "text" => Keyword.get(opts, :content, "Hello! I'm doing well, thank you for asking.")
        }
      ],
      "stop_reason" => Keyword.get(opts, :stop_reason, "stop"),
      "stop_sequence" => nil,
      "usage" => %{
        "input_tokens" => Keyword.get(opts, :input_tokens, 12),
        "output_tokens" => Keyword.get(opts, :output_tokens, 15)
      }
    }
  end
end
