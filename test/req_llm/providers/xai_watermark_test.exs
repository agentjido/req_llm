defmodule ReqLLM.Providers.XAIWatermarkTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Context
  alias ReqLLM.Providers.XAI
  alias ReqLLM.Providers.XAI.ResponseBuilder
  alias ReqLLM.Response
  alias ReqLLM.StreamChunk

  describe "buffered response metadata" do
    test "normalizes the Chat Completions header and projects it to call metadata" do
      {_request, decoded} =
        XAI.decode_response({
          request(:chat),
          Req.Response.new(
            status: 200,
            headers: %{"X-Watermark" => ["true"]},
            body: chat_body()
          )
        })

      assert decoded.body.provider_meta[:watermarked] == true
      assert Response.call_metadata(decoded.body).provider_metadata[:watermarked] == true
      refute Map.has_key?(decoded.body.provider_meta, :headers)
      refute Map.has_key?(decoded.body.provider_meta, "headers")
    end

    test "normalizes the Responses API header" do
      {_request, decoded} =
        XAI.decode_response({
          request(:responses),
          Req.Response.new(
            status: 200,
            headers: [{"x-watermark", "true"}],
            body: responses_body()
          )
        })

      assert decoded.body.provider_meta[:watermarked] == true
      assert Response.call_metadata(decoded.body).provider_metadata[:watermarked] == true
    end

    test "preserves explicit false" do
      {_request, decoded} =
        XAI.decode_response({
          request(:chat),
          Req.Response.new(
            status: 200,
            headers: [{"x-watermark", " false "}],
            body: chat_body()
          )
        })

      assert Map.fetch!(decoded.body.provider_meta, :watermarked) == false

      assert Map.fetch!(Response.call_metadata(decoded.body).provider_metadata, :watermarked) ==
               false
    end

    test "omits missing, unrecognized, and conflicting values" do
      for headers <- [
            [],
            [{"x-watermark", "unknown"}],
            [{"x-watermark", "true"}, {"X-Watermark", "false"}]
          ] do
        {_request, decoded} =
          XAI.decode_response({
            request(:chat),
            Req.Response.new(status: 200, headers: headers, body: chat_body())
          })

        refute Map.has_key?(decoded.body.provider_meta, :watermarked)
      end
    end
  end

  describe "streamed response materialization" do
    test "uses the xAI adapter without exposing raw headers" do
      model = model()

      assert ReqLLM.Provider.ResponseBuilder.for_model(model) == ResponseBuilder

      assert {:ok, response} =
               ResponseBuilder.build_response(
                 [StreamChunk.text("hello")],
                 %{
                   response_id: "resp_stream",
                   response_model: model.id,
                   finish_reason: :stop,
                   headers: [{"X-Watermark", "true"}, {"x-trace", "private"}]
                 },
                 context: Context.new(),
                 model: model
               )

      assert response.provider_meta == %{watermarked: true}
      assert Response.call_metadata(response).provider_metadata == %{watermarked: true}
    end
  end

  defp request(api_type) do
    model = model()

    %{
      Req.new()
      | options: %{
          context: Context.new(),
          model: model.id,
          operation: :chat,
          stream: false,
          xai_api_type: api_type,
          req_llm_model: model
        }
    }
    |> Req.Request.put_private(:req_llm_model, model)
  end

  defp model, do: ReqLLM.model!("xai:grok-4.3")

  defp chat_body do
    %{
      "id" => "chat_123",
      "model" => "grok-4.3",
      "choices" => [
        %{
          "finish_reason" => "stop",
          "message" => %{"role" => "assistant", "content" => "hello"}
        }
      ],
      "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}
    }
  end

  defp responses_body do
    %{
      "id" => "resp_123",
      "model" => "grok-4.3",
      "status" => "completed",
      "output" => [
        %{
          "id" => "msg_123",
          "type" => "message",
          "role" => "assistant",
          "status" => "completed",
          "content" => [
            %{"type" => "output_text", "text" => "hello", "annotations" => []}
          ]
        }
      ],
      "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2}
    }
  end
end
