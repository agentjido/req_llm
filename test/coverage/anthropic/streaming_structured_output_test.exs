defmodule ReqLLM.Coverage.Anthropic.StreamingStructuredOutputTest do
  @moduledoc """
  Streaming structured output validation for Anthropic native json_schema and tool_strict modes.

  Tests streaming object generation with both:
  - Native output_format json_schema mode
  - Tool strict fallback mode

  Run with REQ_LLM_FIXTURES_MODE=record to test against live API and record fixtures.
  Otherwise uses fixtures for fast, reliable testing.
  """

  use ExUnit.Case, async: false

  import ExUnit.Case
  import ReqLLM.Test.Helpers

  @moduletag :coverage
  @moduletag provider: "anthropic"
  @moduletag timeout: 180_000

  @schema [
    name: [type: :string, required: true, doc: "Person's full name"],
    # Anthropic json_schema does not support 'minimum' keyword for integers
    age: [type: :integer, required: true, doc: "Person's age in years"],
    occupation: [type: :string, doc: "Person's job or profession"]
  ]

  # Use the latest Sonnet model which supports structured outputs
  @model "anthropic:claude-sonnet-4-5-20250929"

  setup_all do
    LLMDB.load(allow: :all, custom: %{})
    :ok
  end

  describe "streaming with json_schema mode" do
    @tag scenario: :object_streaming_json_schema

    test "streams object with native output_format json_schema" do
      opts =
        fixture_opts(
          "object_streaming_json_schema",
          param_bundles().deterministic
          |> Keyword.put(:max_tokens, 1000)
          |> Keyword.put(:provider_options, anthropic_structured_output_mode: :json_schema)
        )

      {:ok, stream_response} =
        ReqLLM.stream_object(
          @model,
          "Generate a software engineer profile",
          @schema,
          opts
        )

      assert %ReqLLM.StreamResponse{} = stream_response
      assert stream_response.stream
      assert stream_response.metadata_handle

      {:ok, response} = ReqLLM.StreamResponse.to_response(stream_response)

      assert %ReqLLM.Response{} = response
      object = ReqLLM.Response.object(response)

      assert is_map(object) and map_size(object) > 0
      assert Map.has_key?(object, "name")
      assert Map.has_key?(object, "age")
      assert is_binary(object["name"])
      assert is_integer(object["age"])
    end
  end

  describe "streaming with tool_strict mode" do
    @tag scenario: :object_streaming_tool_strict

    test "streams object with strict tool calling" do
      opts =
        fixture_opts(
          "object_streaming_tool_strict",
          param_bundles().deterministic
          |> Keyword.put(:max_tokens, 1000)
          |> Keyword.put(:provider_options, anthropic_structured_output_mode: :tool_strict)
        )

      {:ok, stream_response} =
        ReqLLM.stream_object(
          @model,
          "Generate a software engineer profile",
          @schema,
          opts
        )

      assert %ReqLLM.StreamResponse{} = stream_response
      {:ok, response} = ReqLLM.StreamResponse.to_response(stream_response)

      object = ReqLLM.Response.object(response)
      assert is_map(object)
      assert Map.has_key?(object, "name")

      # Verify it used a tool call
      assert response.message.tool_calls != nil
      assert Enum.any?(response.message.tool_calls, fn tc -> tc.name == "structured_output" end)
    end
  end

  describe "streaming with auto mode" do
    @tag scenario: :object_streaming_auto

    test "auto-selects json_schema when no other tools present" do
      opts =
        fixture_opts(
          "object_streaming_auto",
          param_bundles().deterministic
          |> Keyword.put(:max_tokens, 1000)
          # Default mode is auto
        )

      {:ok, stream_response} =
        ReqLLM.stream_object(
          @model,
          "Generate a software engineer profile",
          @schema,
          opts
        )

      {:ok, response} = ReqLLM.StreamResponse.to_response(stream_response)
      object = ReqLLM.Response.object(response)
      assert is_map(object)

      # Should prefer json_schema (so NO tool calls expected if strictly following plan)
      # But let's just assert object validity for now, or check if tool_calls is nil/empty
      # logic: :auto -> if has_other_tools? -> tool_strict else json_schema
      # Here no tools -> json_schema

      assert response.message.tool_calls == nil or response.message.tool_calls == []
    end

    test "auto-selects tool_strict when other tools present" do
      other_tool =
        ReqLLM.tool(name: "other_tool", description: "desc", callback: fn _ -> {:ok, "ok"} end)

      opts =
        fixture_opts(
          "object_streaming_auto_with_tools",
          param_bundles().deterministic
          |> Keyword.put(:max_tokens, 1000)
          |> Keyword.put(:tools, [other_tool])
        )

      {:ok, stream_response} =
        ReqLLM.stream_object(
          @model,
          "Generate a software engineer profile",
          @schema,
          opts
        )

      {:ok, response} = ReqLLM.StreamResponse.to_response(stream_response)
      object = ReqLLM.Response.object(response)
      assert is_map(object)

      # Should have used tool_strict because other tools exist
      assert response.message.tool_calls != nil
      assert Enum.any?(response.message.tool_calls, fn tc -> tc.name == "structured_output" end)
    end
  end
end
