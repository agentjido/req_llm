defmodule ReqLLM.Images.ImageStreamServerTest do
  use ExUnit.Case, async: true

  alias ReqLLM.{Context, Response, StreamResponse, StreamServer}
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Providers.{Azure, OpenAI}
  alias ReqLLM.StreamResponse.MetadataHandle

  @png_bytes <<137, 80, 78, 71, 13, 10, 26, 10>>
  @openai_model LLMDB.Model.new!(%{id: "gpt-image-1.5", provider: :openai})
  @azure_model LLMDB.Model.new!(%{id: "gpt-image-2", provider: :azure})

  describe "OpenAI image SSE through the stream server" do
    test "processes previews and builds a response in one stream read" do
      sse = [sse_event(partial_payload(0)), sse_event(completed_payload())]
      {_server, stream_response} = start_stream(OpenAI, @openai_model, sse)
      consumer = self()

      chunks =
        Stream.each(stream_response.stream, fn
          %ReqLLM.StreamChunk{type: :content_part, content_part: part} ->
            send(consumer, {:image, part})

          _chunk ->
            :ok
        end)

      refute_received {:image, _part}

      assert {:ok, response} = StreamResponse.to_response(%{stream_response | stream: chunks})
      assert_received {:image, %ContentPart{metadata: %{partial?: true}}}
      assert_received {:image, %ContentPart{metadata: %{partial?: false}} = final}
      refute_received {:image, _part}
      assert Response.images(response) == [final]
      assert response.usage.image_usage.generated.count == 1
    end

    test "delivers previews live and assembles only the final image" do
      sse = [
        sse_event(partial_payload(0)),
        sse_event(partial_payload(1)),
        sse_event(completed_payload())
      ]

      {_server, stream_response} = start_stream(OpenAI, @openai_model, sse)

      chunks = Enum.to_list(stream_response.stream)

      assert [
               %ReqLLM.StreamChunk{type: :content_part, metadata: %{stream_only?: true}},
               %ReqLLM.StreamChunk{type: :content_part, metadata: %{stream_only?: true}},
               %ReqLLM.StreamChunk{type: :content_part} = final_chunk,
               %ReqLLM.StreamChunk{type: :meta, metadata: %{terminal?: true}}
             ] = chunks

      assert final_chunk.content_part.metadata.partial? == false
      assert final_chunk.content_part.data == @png_bytes

      {:ok, response} = StreamResponse.to_response(%{stream_response | stream: chunks})

      assert [%ContentPart{type: :image, metadata: %{partial?: false}}] =
               Response.images(response)

      assert response.finish_reason == :stop
      assert response.usage.image_usage.generated.count == 1
      assert response.usage.input_tokens == 20
      assert response.provider_meta["openai"]["type"] == "image_generation.completed"
      refute Map.has_key?(response.provider_meta["openai"], "b64_json")
    end

    test "a completed event without image data terminates with an error instead of hanging" do
      sse = [
        sse_event(partial_payload(0)),
        sse_event(Map.delete(completed_payload(), "b64_json"))
      ]

      {_server, stream_response} = start_stream(OpenAI, @openai_model, sse)

      chunks = Enum.to_list(stream_response.stream)

      assert [
               %ReqLLM.StreamChunk{type: :content_part},
               %ReqLLM.StreamChunk{
                 type: :meta,
                 metadata: %{terminal?: true, finish_reason: :error}
               }
             ] = chunks

      assert {:error, message} = StreamResponse.to_response(%{stream_response | stream: chunks})
      assert message =~ "image_generation.completed"
    end

    test "an SSE error event terminates with the provider message" do
      sse = [
        sse_event(%{"type" => "error", "error" => %{"message" => "content policy violation"}})
      ]

      {_server, stream_response} = start_stream(OpenAI, @openai_model, sse)

      chunks = Enum.to_list(stream_response.stream)

      assert {:error, "content policy violation"} =
               StreamResponse.to_response(%{stream_response | stream: chunks})
    end
  end

  describe "Azure image SSE through the stream server" do
    test "routes gpt-image deployments to the image decoder and keys provider_meta by azure" do
      sse = [sse_event(partial_payload(0)), sse_event(completed_payload())]

      {_server, stream_response} = start_stream(Azure, @azure_model, sse)

      chunks = Enum.to_list(stream_response.stream)
      assert length(chunks) == 3

      {:ok, response} = StreamResponse.to_response(%{stream_response | stream: chunks})

      assert [%ContentPart{type: :image}] = Response.images(response)
      assert Map.has_key?(response.provider_meta, "azure")
      refute Map.has_key?(response.provider_meta, "openai")
    end
  end

  defp start_stream(provider_mod, model, sse_events) do
    {:ok, server} = StreamServer.start_link(provider_mod: provider_mod, model: model)

    :ok = StreamServer.http_event(server, {:status, 200})
    :ok = StreamServer.http_event(server, {:headers, [{"content-type", "text/event-stream"}]})
    :ok = StreamServer.http_event(server, {:data, IO.iodata_to_binary(sse_events)})

    {:ok, handle} =
      MetadataHandle.start_link(fn ->
        {:ok, metadata} = StreamServer.await_metadata(server, 1_000)
        metadata
      end)

    stream_response = %StreamResponse{
      stream: Stream.unfold(server, &next_chunk/1),
      metadata_handle: handle,
      cancel: fn -> :ok end,
      model: model,
      context: Context.new([Context.user("A red square")])
    }

    {server, stream_response}
  end

  defp next_chunk(server) do
    case StreamServer.next(server, 1_000) do
      {:ok, chunk} -> {chunk, server}
      :halt -> nil
    end
  end

  defp sse_event(payload), do: "data: #{Jason.encode!(payload)}\n\n"

  defp partial_payload(index) do
    %{
      "type" => "image_generation.partial_image",
      "b64_json" => Base.encode64(@png_bytes),
      "partial_image_index" => index,
      "created_at" => 1_700_000_000,
      "size" => "1024x1024",
      "quality" => "low",
      "background" => "opaque",
      "output_format" => "png"
    }
  end

  defp completed_payload do
    %{
      "type" => "image_generation.completed",
      "b64_json" => Base.encode64(@png_bytes),
      "created_at" => 1_700_000_000,
      "size" => "1024x1024",
      "quality" => "low",
      "background" => "opaque",
      "output_format" => "png",
      "usage" => %{
        "total_tokens" => 120,
        "input_tokens" => 20,
        "output_tokens" => 100,
        "input_tokens_details" => %{"text_tokens" => 20, "image_tokens" => 0}
      }
    }
  end
end
