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

      assert ModelCompat.scenarios_for_opts([capability: "web_fetch"], :text) == [
               "web_fetch_basic"
             ]

      assert ModelCompat.scenarios_for_opts([capability: "logprobs"], :text) == [
               "logprobs_non_streaming"
             ]
    end

    test "deduplicates combined scenario and capability values" do
      assert ModelCompat.scenarios_for_opts([scenario: "basic", capability: "core"], :text) == [
               "basic",
               "usage",
               "token_limit"
             ]
    end

    test "preserves ordered operation-specific defaults" do
      assert ModelCompat.scenarios_for_opts([capability: "embedding"], :embedding) == [
               "embed_basic",
               "embed_usage",
               "embed_batch"
             ]

      assert ModelCompat.scenarios_for_opts([capability: "core"], :text) == [
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

  describe "scenarios_for_opts/3" do
    test "restricts focused capability scenarios to applicable providers" do
      assert ModelCompat.scenarios_for_opts([capability: "web_fetch"], :text, :anthropic) == [
               "web_fetch_basic"
             ]

      assert ModelCompat.scenarios_for_opts([capability: "web_fetch"], :text, :openai) == []
    end

    test "excludes live-only integration scenarios from per-model compatibility runs" do
      assert ModelCompat.scenarios_for_opts([capability: "tool_id_compat"], :text, :openai) ==
               []

      assert ModelCompat.scenarios_for_opts(
               [capability: "tool_id_compat"],
               :text,
               :anthropic
             ) == []
    end

    test "preserves explicit scenario selection for compatibility" do
      assert ModelCompat.scenarios_for_opts(
               [scenario: "custom_scenario", capability: "web_fetch"],
               :text,
               :openai
             ) == ["custom_scenario"]
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

    test "routes consolidated focused scenarios through the catalog" do
      assert ModelCompat.test_args_for(:openai, :text, "logprobs_non_streaming") == [
               "test",
               "test/coverage/openai/logprobs_test.exs",
               "--only",
               "scenario:logprobs_non_streaming"
             ]

      assert ModelCompat.test_args_for(:anthropic, :text, "web_fetch_basic") == [
               "test",
               "test/coverage/anthropic/web_fetch_test.exs",
               "--only",
               "scenario:web_fetch_basic"
             ]

      assert ModelCompat.test_args_for(:azure, :text, "object_streaming_claude_auto") == [
               "test",
               "test/coverage/azure/streaming_structured_output_test.exs",
               "--only",
               "scenario:object_streaming_claude_auto"
             ]
    end

    test "preserves operation-specific and unknown explicit scenario fallback routes" do
      assert ModelCompat.test_args_for(:openai, :embedding) == [
               "test",
               "test/coverage/openai/embedding_test.exs",
               "--only",
               "provider:openai"
             ]

      assert ModelCompat.test_args_for(:anthropic, :text, "custom_scenario") == [
               "test",
               "test/coverage/anthropic/comprehensive_test.exs",
               "--only",
               "scenario:custom_scenario"
             ]
    end
  end

  describe "parse_exunit_summary/1" do
    test "parses default ExUnit summaries" do
      assert ModelCompat.parse_exunit_summary("10 tests, 0 failures") == {10, 0, 10}
      assert ModelCompat.parse_exunit_summary("10 tests, 2 failures") == {8, 2, 10}
    end

    test "parses result formatter summaries" do
      assert ModelCompat.parse_exunit_summary("Result: 1 passed, 9 excluded") == {1, 0, 1}
      assert ModelCompat.parse_exunit_summary("Result: 0/1 passed, 9 excluded") == {0, 1, 1}
    end
  end

  describe "parse_test_result/5" do
    test "rejects successful ExUnit exits that execute no matching tests" do
      result =
        ModelCompat.parse_test_result(
          :openai,
          "gpt-4o-mini",
          "0 tests, 0 failures",
          0,
          "missing"
        )

      assert result.status == :fail
      assert result.total == 0
      assert result.error == "No matching compatibility tests executed"
      assert result.failure_layer == "planning"
    end

    test "accepts successful invocations that execute a matching test" do
      result =
        ModelCompat.parse_test_result(
          :openai,
          "gpt-4o-mini",
          "1 test, 0 failures",
          0,
          "basic"
        )

      assert result.status == :pass
      assert result.total == 1
      assert result.error == nil
      assert result.failure_layer == nil
      assert result.fixtures == ["basic"]
    end

    test "preserves fixture names emitted by the test run" do
      result =
        ModelCompat.parse_test_result(
          :openai,
          "gpt-4o-mini",
          "[Fixture] promoted: name=custom\n1 test, 0 failures",
          0,
          "basic"
        )

      assert result.fixtures == ["custom"]
    end
  end

  describe "support_operation/2" do
    test "normalizes inferred model types for all-operation discovery" do
      assert ModelCompat.support_operation(%{"type" => "text"}, :all) == :text
      assert ModelCompat.support_operation(%{"type" => "embedding"}, :all) == :embedding
      assert ModelCompat.support_operation(%{"type" => "unknown"}, :all) == :unknown
    end

    test "preserves an explicitly selected operation" do
      assert ModelCompat.support_operation(%{"type" => "embedding"}, :text) == :text
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
