defmodule Mix.Tasks.ReqLlm.ModelCompatTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.ReqLlm.ModelCompat

  describe "scenarios_for_opts/2" do
    test "parses explicit scenario lists" do
      assert ModelCompat.scenarios_for_opts([scenario: "basic,usage"], :text) == [
               "basic",
               "usage"
             ]
    end

    test "expands capability groups" do
      assert ModelCompat.scenarios_for_opts([capability: "core"], :text) == [
               "basic",
               "usage",
               "token_limit"
             ]
    end

    test "expands specialty capability groups" do
      assert ModelCompat.scenarios_for_opts([capability: "image"], :image) == ["image_basic"]
      assert ModelCompat.scenarios_for_opts([capability: "speech"], :speech) == ["speech_basic"]

      assert ModelCompat.scenarios_for_opts([capability: "transcription"], :transcription) == [
               "transcription_basic"
             ]

      assert ModelCompat.scenarios_for_opts([capability: "rerank"], :rerank) == ["rerank_basic"]
      assert ModelCompat.scenarios_for_opts([capability: "ocr"], :ocr) == ["ocr_basic"]
    end

    test "expands provider-specific capability groups" do
      assert ModelCompat.scenarios_for_opts([capability: "grounding"], :text) == [
               "grounding_basic",
               "grounding_with_context",
               "grounding_streaming"
             ]

      assert ModelCompat.scenarios_for_opts([capability: "grounding_legacy"], :text) == [
               "grounding_legacy"
             ]

      assert ModelCompat.scenarios_for_opts([capability: "web_search"], :text) == [
               "web_search_basic",
               "web_search_streaming",
               "x_search_streaming"
             ]
    end

    test "deduplicates combined scenario and capability values" do
      assert ModelCompat.scenarios_for_opts([scenario: "basic", capability: "core"], :text) == [
               "basic",
               "usage",
               "token_limit"
             ]
    end

    test "raises for unknown capabilities" do
      assert_raise Mix.Error, ~r/Unknown capability group/, fn ->
        ModelCompat.scenarios_for_opts([capability: "unknown"], :text)
      end
    end
  end

  describe "state_update?/1" do
    test "replay checks are read-only by default" do
      refute ModelCompat.state_update?([])
    end

    test "record and explicit update-state runs update state" do
      assert ModelCompat.state_update?(record: true)
      assert ModelCompat.state_update?(record_all: true)
      assert ModelCompat.state_update?(update_state: true)
    end
  end

  describe "test_args_for/3" do
    test "routes generic text scenarios to comprehensive tests" do
      assert ModelCompat.test_args_for(:google, :text, "basic") == [
               "test",
               "test/coverage/google/comprehensive_test.exs",
               "--only",
               "scenario:basic"
             ]
    end

    test "routes Google-specific scenarios to focused test files" do
      assert ModelCompat.test_args_for(:google, :text, "grounding_basic") == [
               "test",
               "test/coverage/google/grounding_test.exs",
               "--only",
               "scenario:grounding_basic"
             ]

      assert ModelCompat.test_args_for(:google, :text, "multimodal_tool_result") == [
               "test",
               "test/coverage/google/multimodal_tool_result_test.exs",
               "--only",
               "scenario:multimodal_tool_result"
             ]
    end

    test "routes xAI-specific scenarios to focused test files" do
      assert ModelCompat.test_args_for(:xai, :text, "web_search_basic") == [
               "test",
               "test/coverage/xai/web_search_test.exs",
               "--only",
               "scenario:web_search_basic"
             ]

      assert ModelCompat.test_args_for(:xai, :text, "object_streaming_json_schema") == [
               "test",
               "test/coverage/xai/streaming_structured_output_test.exs",
               "--only",
               "scenario:object_streaming_json_schema"
             ]
    end
  end

  describe "run/1" do
    test "raises clearly for unknown operation types" do
      Mix.Task.reenable("req_llm.model_compat")

      assert_raise Mix.Error, ~r/Unknown operation type: "not-real"/, fn ->
        ModelCompat.run(["--available", "--type", "not-real"])
      end
    end
  end
end
