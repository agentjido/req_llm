defmodule Mix.Tasks.ReqLlm.ModelCompatTest do
  use ExUnit.Case, async: true

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
end
