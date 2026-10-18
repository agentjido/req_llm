defmodule ReqLLM.Provider.ResponseBuilderJSONTest do
  use ExUnit.Case, async: true

  @moduletag contract: :provider_boundary

  alias ReqLLM.Context
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Output
  alias ReqLLM.Output.Validation
  alias ReqLLM.Provider.Defaults
  alias ReqLLM.Providers.OpenAI.ResponsesAPI
  alias ReqLLM.Response
  alias ReqLLM.StreamChunk
  alias ReqLLM.StreamResponse
  alias ReqLLM.StreamResponse.MetadataHandle

  for api <- [:responses, :chat], conversion <- [:process_stream, :to_response] do
    @api api
    @conversion conversion

    test "#{api} #{@conversion} retains JSON text and thinking parts" do
      for text <- [~s({"a": 1}), "{}", " \n{\"a\": 1}\n "] do
        chunks = [StreamChunk.thinking("Plan") | text_chunks(@api, text)]
        stream = stream_response(@api, chunks)

        assert {:ok, response} = apply(StreamResponse, @conversion, [stream])
        assert Response.text(response) == text
        assert Response.thinking(response) == "Plan"

        assert response.message.content == [ContentPart.text(text), ContentPart.thinking("Plan")]
        assert List.last(response.context.messages) == response.message
      end
    end
  end

  test "JSON text callbacks match the final response" do
    text = ~s({"a": 1})
    fragments = String.graphemes(text)
    stream = stream_response(:responses, text_chunks(:responses, text))

    assert {:ok, response} =
             StreamResponse.process_stream(stream, on_result: &send(self(), {:text, &1}))

    for fragment <- fragments do
      assert_receive {:text, ^fragment}
    end

    assert Response.text(response) == text
  end

  test "non-object text remains unchanged" do
    for text <- ["hello", "[1,2]", "{invalid}", "```json\n{\"a\": 1}\n```"] do
      stream = stream_response(:responses, text_chunks(:responses, text))

      assert {:ok, response} = StreamResponse.to_response(stream)
      assert Response.text(response) == text
      assert response.object == nil
    end
  end

  test "native structured output keeps raw text under strict validation" do
    outputs = [
      {Output.object(a: [type: :integer, required: true]), ~s({"a": 1}), %{"a" => 1}},
      {Output.array(a: [type: :integer, required: true]), ~s({"value":[{"a":1}]}), [%{"a" => 1}]},
      {Output.choice(["yes", "no"]), ~s({"value":"yes"}), "yes"},
      {Output.json(), ~s({"value":[1,null]}), [1, nil]}
    ]

    for api <- [:responses, :chat], {output, text, value} <- outputs do
      stream = stream_response(api, [StreamChunk.thinking("Plan") | text_chunks(api, text)])
      assert {:ok, contract} = Output.compile(output)
      assert {:ok, config, []} = Validation.take_runtime_options(output_validation: :strict)
      assert {:ok, stream} = Validation.attach_stream_result({:ok, stream}, contract, config)

      assert {:ok, response} = StreamResponse.to_response(stream)
      assert Response.text(response) == text
      assert Response.thinking(response) == "Plan"
      assert Response.output(response, output) == value
      assert response.object == Jason.decode!(text)
      assert %{valid?: true, raw: ^text, source: :text} = Response.output_result(response, output)
    end
  end

  test "structured tool output takes priority over JSON text" do
    text = ~s({"a": 1})

    chunks = [
      StreamChunk.thinking("Plan"),
      StreamChunk.text(text),
      StreamChunk.tool_call("structured_output", %{"a" => 2}, %{id: "call_1", index: 0})
    ]

    assert {:ok, response} = StreamResponse.to_response(stream_response(:chat, chunks))
    assert Response.text(response) == text
    assert Response.thinking(response) == "Plan"
    assert response.object == %{"a" => 2}
  end

  test "other tool calls do not turn JSON text into structured output" do
    text = ~s({"a": 1})

    chunks = [
      StreamChunk.text(text),
      StreamChunk.tool_call("lookup", %{}, %{id: "call_1", index: 0})
    ]

    assert {:ok, response} = StreamResponse.to_response(stream_response(:chat, chunks))
    assert Response.text(response) == text
    assert response.object == nil
  end

  defp text_chunks(api, text) do
    Enum.flat_map(String.graphemes(text), fn fragment ->
      case api do
        :responses ->
          ResponsesAPI.decode_stream_event(
            %{data: %{"type" => "response.output_text.delta", "delta" => fragment}},
            model(api)
          )

        :chat ->
          Defaults.default_decode_stream_event(
            %{data: %{"choices" => [%{"delta" => %{"content" => fragment}}]}},
            model(api)
          )
      end
    end)
  end

  defp stream_response(api, chunks) do
    {:ok, handle} = MetadataHandle.start_link(fn -> %{finish_reason: :stop} end)

    %StreamResponse{
      stream: chunks,
      metadata_handle: handle,
      cancel: fn -> :ok end,
      model: model(api),
      context: Context.new([Context.user("Reply with JSON")])
    }
  end

  defp model(:responses) do
    %LLMDB.Model{
      provider: :openai,
      id: "gpt-5.1",
      extra: %{wire: %{protocol: "openai_responses"}}
    }
  end

  defp model(:chat), do: %LLMDB.Model{provider: :openai, id: "gpt-chat-test"}
end
