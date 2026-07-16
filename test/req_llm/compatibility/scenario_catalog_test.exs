defmodule ReqLLM.Compatibility.ScenarioCatalogTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Compatibility.ScenarioCatalog

  @operations [
    %{id: :text, test_file: "comprehensive_test.exs"},
    %{id: :embedding, test_file: "embedding_test.exs"},
    %{id: :image, test_file: "image_generation_test.exs"},
    %{id: :speech, test_file: "speech_test.exs"},
    %{id: :transcription, test_file: "transcription_test.exs"},
    %{id: :rerank, test_file: "rerank_test.exs"},
    %{id: :ocr, test_file: "ocr_test.exs"},
    %{id: :all, test_file: :provider_directory}
  ]

  @capability_scenarios %{
    "core" => ~w(basic usage token_limit),
    "conversation" => ~w(context_append),
    "streaming" => ~w(streaming),
    "tools" => ~w(tool_none tool_multi tool_round_trip),
    "objects" => ~w(object_basic object_streaming),
    "reasoning" => ~w(reasoning),
    "embedding" => ~w(embed_basic embed_usage embed_batch),
    "image" => ~w(image_basic),
    "speech" => ~w(speech_basic),
    "transcription" => ~w(transcription_basic),
    "rerank" => ~w(rerank_basic),
    "ocr" => ~w(ocr_basic),
    "grounding" => ~w(grounding_basic grounding_with_context grounding_streaming),
    "grounding_legacy" => ~w(grounding_legacy),
    "multimodal_tool_result" => ~w(multimodal_tool_result),
    "web_search" => ~w(web_search_basic web_search_streaming x_search_streaming),
    "streaming_structured_output" =>
      ~w(object_streaming_json_schema object_streaming_tool_strict object_streaming_auto streaming_error_handling)
  }

  describe "catalog" do
    test "represents every scenario once" do
      scenario_ids = Enum.map(ScenarioCatalog.scenarios(), & &1.id)

      assert length(scenario_ids) == 31
      assert length(scenario_ids) == MapSet.size(MapSet.new(scenario_ids))
    end

    test "represents every canonical operation and its established route" do
      assert ScenarioCatalog.operations() == @operations

      assert ScenarioCatalog.operation_test_file(:openai, :text) ==
               "test/coverage/openai/comprehensive_test.exs"

      assert ScenarioCatalog.operation_test_file(:google, :all) == "test/coverage/google"
    end

    test "preserves capability selection order and operation metadata" do
      actual =
        Map.new(ScenarioCatalog.capabilities(), fn capability ->
          {:ok, scenarios} = ScenarioCatalog.scenarios_for_capability(capability.id)
          {capability.id, scenarios}
        end)

      assert actual == @capability_scenarios

      assert %{operation: :embedding} =
               Enum.find(ScenarioCatalog.capabilities(), &(&1.id == "embedding"))
    end

    test "preserves provider-specific routes" do
      assert ScenarioCatalog.scenario_test_file(:google, "grounding_basic") ==
               "test/coverage/google/grounding_test.exs"

      assert ScenarioCatalog.scenario_test_file(:xai, :object_streaming_auto) ==
               "test/coverage/xai/streaming_structured_output_test.exs"

      assert ScenarioCatalog.scenario_test_file(:google, "basic") == nil
    end
  end

  describe "validation" do
    test "rejects duplicate scenario IDs" do
      capabilities = [%{id: "core", operation: :text}]
      scenarios = [%{id: "basic", capability: "core"}, %{id: "basic", capability: "core"}]

      assert_raise ArgumentError, ~r/duplicate scenario IDs/, fn ->
        ScenarioCatalog.validate!(@operations, capabilities, scenarios, [])
      end
    end

    test "rejects unknown capabilities" do
      capabilities = [%{id: "core", operation: :text}]
      scenarios = [%{id: "basic", capability: "missing"}]

      assert_raise ArgumentError, ~r/references unknown capability/, fn ->
        ScenarioCatalog.validate!(@operations, capabilities, scenarios, [])
      end
    end

    test "rejects invalid routes" do
      capabilities = [%{id: "core", operation: :text}]
      scenarios = [%{id: "basic", capability: "core"}]
      routes = [%{provider: :openai, scenario: "unknown", test_file: "test/coverage/openai.exs"}]

      assert_raise ArgumentError, ~r/invalid scenario route/, fn ->
        ScenarioCatalog.validate!(@operations, capabilities, scenarios, routes)
      end
    end
  end
end
