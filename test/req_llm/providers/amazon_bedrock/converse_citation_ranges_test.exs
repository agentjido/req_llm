defmodule ReqLLM.Providers.AmazonBedrock.ConverseCitationRangesTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Provider.ChunkAccumulator
  alias ReqLLM.Providers.AmazonBedrock.Converse
  alias ReqLLM.Response

  @citation %{
    "title" => "Source",
    "location" => %{"documentPage" => %{"documentIndex" => 0, "start" => 1, "end" => 2}}
  }

  defp cited(text),
    do: %{"citationsContent" => %{"content" => [%{"text" => text}], "citations" => [@citation]}}

  defp parse(blocks) do
    {:ok, response} =
      Converse.parse_response(
        %{"output" => %{"message" => %{"role" => "assistant", "content" => blocks}}},
        model: "test-model"
      )

    response
  end

  defp delta(index, value),
    do: %{"contentBlockDelta" => %{"contentBlockIndex" => index, "delta" => value}}

  defp stop(index), do: %{"contentBlockStop" => %{"contentBlockIndex" => index}}

  test "distinguishes which sentence a source supports" do
    first = parse([cited("First claim. "), %{"text" => "Second claim."}])
    second = parse([%{"text" => "First claim. "}, cited("Second claim.")])

    assert Response.text(first) == Response.text(second)
    assert [%{"start_index" => 0, "end_index" => 13}] = Response.annotations(first)
    assert [%{"start_index" => 13, "end_index" => 26}] = Response.annotations(second)
    refute first == second
  end

  test "retains repeated citations and matches streamed Unicode code point ranges" do
    buffered = parse([%{"text" => "é. "}, cited("🙂e\u0301"), cited("Again")])

    events = [
      delta(0, %{"text" => "é. "}),
      stop(0),
      delta(1, %{"citation" => @citation}),
      delta(1, %{"text" => "🙂e"}),
      delta(1, %{"text" => "\u0301"}),
      stop(1),
      delta(2, %{"text" => "Again"}),
      delta(2, %{"citation" => @citation}),
      stop(2)
    ]

    {chunks, state} =
      Enum.flat_map_reduce(events, Converse.init_stream_state(), &Converse.decode_stream_event/2)

    assert Converse.flush_stream_state(state) == {[], state}
    acc = ChunkAccumulator.reduce(ChunkAccumulator.new(), chunks)
    annotations = ChunkAccumulator.finalize_annotations(acc)

    assert ChunkAccumulator.finalize_text(acc) == Response.text(buffered)
    assert annotations == Response.annotations(buffered)
    assert [first, second] = annotations
    assert %{"start_index" => 3, "end_index" => 6, "location" => location} = first
    assert location == @citation["location"]
    assert %{"start_index" => 6, "end_index" => 11} = second
  end

  test "flushes a citation without a block stop only once" do
    events = [delta(0, %{"citation" => @citation}), delta(0, %{"text" => "Claim"})]

    {chunks, state} =
      Enum.flat_map_reduce(events, Converse.init_stream_state(), &Converse.decode_stream_event/2)

    assert [%ReqLLM.StreamChunk{type: :content, text: "Claim"}] = chunks
    {[chunk], state} = Converse.flush_stream_state(state)
    assert %{annotations: [%{"start_index" => 0, "end_index" => 5}]} = chunk.metadata
    assert Converse.flush_stream_state(state) == {[], state}
  end
end
