defmodule ReqLLM.Coverage.XAI.StreamingStructuredOutputTest do
  @moduledoc """
  Streaming structured output validation for xAI native json_schema and tool_strict modes.

  Tests streaming object generation with both:
  - Native json_schema mode (grok-4+, grok-2-1212+, grok-3+)
  - Tool strict fallback mode (grok-2 legacy)

  Run with REQ_LLM_FIXTURES_MODE=record to test against live API and record fixtures.
  Otherwise uses fixtures for fast, reliable testing.
  """

  use ExUnit.Case, async: false

  import ExUnit.Case
  import ReqLLM.Test.Helpers

  @moduletag :coverage
  @moduletag provider: "xai"
  @moduletag timeout: 180_000

  @schema [
    name: [type: :string, required: true, doc: "Person's full name"],
    age: [type: :pos_integer, required: true, doc: "Person's age in years"],
    occupation: [type: :string, doc: "Person's job or profession"]
  ]

  setup_all do
    LLMDB.load(allow: :all, custom: %{})
    :ok
  end

  describe "streaming with json_schema mode (grok-4)" do
    @tag scenario: :object_streaming_json_schema

    test "streams object with native response_format json_schema" do
      opts =
        fixture_opts(
          "object_streaming_json_schema",
          param_bundles().deterministic
          |> Keyword.put(:max_tokens, 500)
        )

      {:ok, stream_response} =
        ReqLLM.stream_object(
          "xai:grok-4",
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
      assert object["name"] != ""
      assert is_integer(object["age"])
      assert object["age"] > 0
    end
  end

  describe "streaming with tool_strict mode (grok-2 legacy)" do
    @tag scenario: :object_streaming_tool_strict

    test "streams object with strict tool calling fallback" do
      opts =
        fixture_opts(
          "object_streaming_tool_strict",
          param_bundles().deterministic
          |> Keyword.put(:max_tokens, 500)
          |> Keyword.put(:provider_options, xai_structured_output_mode: :tool_strict)
        )

      {:ok, stream_response} =
        ReqLLM.stream_object(
          "xai:grok-2",
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
      assert object["name"] != ""
      assert is_integer(object["age"])
      assert object["age"] > 0

      tool_calls = ReqLLM.Response.tool_calls(response)
      assert is_list(tool_calls)
      assert Enum.any?(tool_calls, fn tc -> tc.name == "structured_output" end)
    end
  end

  describe "streaming with auto mode selection" do
    @tag scenario: :object_streaming_auto

    test "auto-selects json_schema for grok-2-1212+" do
      opts =
        fixture_opts(
          "object_streaming_auto",
          param_bundles().deterministic
          |> Keyword.put(:max_tokens, 500)
        )

      {:ok, stream_response} =
        ReqLLM.stream_object(
          "xai:grok-2-1212",
          "Generate a software engineer profile",
          @schema,
          opts
        )

      {:ok, response} = ReqLLM.StreamResponse.to_response(stream_response)

      object = ReqLLM.Response.object(response)
      assert is_map(object) and map_size(object) > 0
      assert Map.has_key?(object, "name")
      assert Map.has_key?(object, "age")
    end
  end

  describe "error handling in streaming" do
    @tag scenario: :streaming_error_handling

    test "handles interrupted stream gracefully" do
      opts =
        fixture_opts(
          "streaming_truncated",
          param_bundles().deterministic
          |> Keyword.put(:max_tokens, 10)
        )

      result =
        ReqLLM.stream_object(
          "xai:grok-4",
          "Generate a very detailed software engineer profile with extensive background",
          @schema,
          opts
        )

      case result do
        {:ok, stream_response} ->
          {:ok, response} = ReqLLM.StreamResponse.to_response(stream_response)
          rt = ReqLLM.Response.reasoning_tokens(response)

          if truncated?(response) do
            assert is_number(rt) and rt >= 0
          else
            object = ReqLLM.Response.object(response)
            assert is_map(object) or (is_number(rt) and rt > 0)
          end

        {:error, _error} ->
          :ok
      end
    end
  end
end
