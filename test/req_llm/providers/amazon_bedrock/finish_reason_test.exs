defmodule ReqLLM.Providers.AmazonBedrock.FinishReasonTest do
  use ExUnit.Case, async: true

  alias ReqLLM.{Context, Error, Response, StreamResponse, StreamServer}
  alias ReqLLM.Providers.AmazonBedrock
  alias ReqLLM.Providers.AmazonBedrock.{AWSAuthAdapter, Converse}
  alias ReqLLM.StreamResponse.MetadataHandle

  @converse_model LLMDB.Model.new!(%{id: "amazon.nova-lite-v1:0", provider: :amazon_bedrock})
  @invoke_model LLMDB.Model.new!(%{
                  id: "anthropic.claude-haiku-4-5-20251001-v1:0",
                  provider: :amazon_bedrock
                })

  describe "mid-stream exceptions" do
    test "end a Converse stream with the AWS exception" do
      frames = [
        event("contentBlockDelta", %{"contentBlockIndex" => 0, "delta" => %{"text" => "Hel"}}),
        exception("throttlingException", "Too many tokens, please wait before trying again.")
      ]

      assert {:error,
              %Error.API.Request{
                provider_code: "throttlingException",
                reason: "Too many tokens, please wait before trying again."
              }} = stream_to_response(@converse_model, frames)
    end

    test "end an InvokeModel stream with the AWS exception" do
      frames = [
        chunk(%{"type" => "message_start", "message" => %{"usage" => %{"input_tokens" => 3}}}),
        chunk(%{
          "type" => "content_block_delta",
          "index" => 0,
          "delta" => %{"type" => "text_delta", "text" => "Hel"}
        }),
        exception("modelTimeoutException", "Model has timed out.")
      ]

      assert {:error,
              %Error.API.Request{
                provider_code: "modelTimeoutException",
                reason: "Model has timed out."
              }} = stream_to_response(@invoke_model, frames)
    end

    test "end the stream with an unmodeled error message" do
      frames = [
        frame(
          [
            {":message-type", "error"},
            {":error-code", "InternalFailure"},
            {":error-message", "An internal error occurred."}
          ],
          ""
        )
      ]

      assert {:error,
              %Error.API.Request{
                provider_code: "InternalFailure",
                reason: "An internal error occurred."
              }} = stream_to_response(@converse_model, frames)
    end
  end

  describe "Converse stop reasons" do
    test "match between buffered and streamed responses" do
      for {stop_reason, finish_reason} <- [
            {"model_context_window_exceeded", :length},
            {"malformed_model_output", :error},
            {"malformed_tool_use", :error},
            {"future_stop_reason", :unknown}
          ] do
        {:ok, buffered} =
          Converse.parse_response(
            %{
              "output" => %{
                "message" => %{"role" => "assistant", "content" => [%{"text" => "Hi"}]}
              },
              "stopReason" => stop_reason
            },
            model: @converse_model.id
          )

        {:ok, streamed} =
          stream_to_response(
            @converse_model,
            [
              event("messageStart", %{"role" => "assistant"}),
              event("contentBlockDelta", %{"contentBlockIndex" => 0, "delta" => %{"text" => "Hi"}}),
              event("contentBlockStop", %{"contentBlockIndex" => 0}),
              event("messageStop", %{"stopReason" => stop_reason})
            ],
            [:done]
          )

        assert Response.finish_reason(buffered) == finish_reason
        assert Response.finish_reason(streamed) == finish_reason
      end
    end
  end

  defp stream_to_response(model, frames, trailing_http_events \\ []) do
    {:ok, server} = StreamServer.start_link(provider_mod: AmazonBedrock, model: model)

    Enum.each(
      [{:status, 200}, {:data, IO.iodata_to_binary(frames)} | trailing_http_events],
      &(:ok = StreamServer.http_event(server, &1))
    )

    {:ok, handle} =
      MetadataHandle.start_link(fn ->
        {:ok, metadata} = StreamServer.await_metadata(server, 1_000)
        metadata
      end)

    StreamResponse.to_response(%StreamResponse{
      stream: Stream.unfold(server, &next_chunk/1),
      metadata_handle: handle,
      cancel: fn -> :ok end,
      model: model,
      context: Context.new()
    })
  end

  defp next_chunk(server) do
    case StreamServer.next(server, 1_000) do
      {:ok, chunk} -> {chunk, server}
      :halt -> nil
    end
  end

  defp event(type, payload) do
    frame(
      [{":message-type", "event"}, {":event-type", type}, {":content-type", "application/json"}],
      Jason.encode!(payload)
    )
  end

  defp chunk(payload), do: event("chunk", %{"bytes" => Base.encode64(Jason.encode!(payload))})

  defp exception(type, message) do
    frame(
      [
        {":message-type", "exception"},
        {":exception-type", type},
        {":content-type", "application/json"}
      ],
      Jason.encode!(%{"message" => message})
    )
  end

  defp frame(headers, payload) do
    headers
    |> Enum.map_join(fn {name, value} ->
      AWSAuthAdapter.event_stream_encode_string_header(name, value)
    end)
    |> AWSAuthAdapter.event_stream_encode_message(payload)
  end
end
