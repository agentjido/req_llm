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
    "web_fetch" => ~w(web_fetch_basic),
    "logprobs" => ~w(logprobs_non_streaming),
    "request_metadata" => ~w(labels_basic),
    "tool_id_compat" =>
      ~w(tool_id_compat_openai_passthrough tool_id_compat_openai_to_anthropic tool_id_compat_turn_boundary),
    "streaming_structured_output" =>
      ~w(object_streaming_json_schema object_streaming_tool_strict object_streaming_auto streaming_error_handling),
    "azure_streaming_structured_output" =>
      ~w(object_streaming_claude_tool object_streaming_claude_auto)
  }

  describe "catalog" do
    test "represents every scenario once" do
      scenario_ids = Enum.map(ScenarioCatalog.scenarios(), & &1.id)

      assert length(scenario_ids) == 39
      assert length(scenario_ids) == MapSet.size(MapSet.new(scenario_ids))
    end

    test "exposes exact fixture contracts and applicability metadata" do
      assert ScenarioCatalog.fixtures(:context_append) == [
               "context_append_1",
               "context_append_2"
             ]

      assert ScenarioCatalog.fixture!(:embed_usage) == "embed_basic"
      assert ScenarioCatalog.fixture!(:multimodal_tool_result, 1) == "multimodal_tool_result_2"

      assert %{
               operation: :text,
               requirements: [:tool_calling],
               applicability: :model_features,
               proof: :fixture_replay
             } = ScenarioCatalog.fetch_scenario!(:tool_multi)

      assert %{
               input_modalities: [:audio],
               output_modalities: [:text],
               providers: :all
             } = ScenarioCatalog.fetch_scenario!(:transcription_basic)
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

    test "limits per-model capability scenarios to applicable providers and proof" do
      assert ScenarioCatalog.model_compat_scenarios_for_capability("web_fetch", :anthropic) ==
               {:ok, ["web_fetch_basic"]}

      assert ScenarioCatalog.model_compat_scenarios_for_capability("web_fetch", :openai) ==
               {:ok, []}

      assert ScenarioCatalog.model_compat_scenarios_for_capability("tool_id_compat", :openai) ==
               {:ok, []}

      assert ScenarioCatalog.model_compat_scenarios_for_capability(
               "tool_id_compat",
               :anthropic
             ) == {:ok, []}
    end

    test "preserves provider-specific routes" do
      assert ScenarioCatalog.scenario_test_file(:google, "grounding_basic") ==
               "test/coverage/google/grounding_test.exs"

      assert ScenarioCatalog.scenario_test_file(:xai, :object_streaming_auto) ==
               "test/coverage/xai/streaming_structured_output_test.exs"

      assert ScenarioCatalog.scenario_test_file(:google, "basic") == nil

      assert ScenarioCatalog.scenario_test_file(:openai, :logprobs_non_streaming) ==
               "test/coverage/openai/logprobs_test.exs"

      assert ScenarioCatalog.scenario_test_file(:azure, :object_streaming_claude_auto) ==
               "test/coverage/azure/streaming_structured_output_test.exs"
    end

    test "fixture-backed contracts have evidence and focused routes exist" do
      fixture_files =
        Path.expand("../../support/fixtures", __DIR__)
        |> Path.join("**/*.json")
        |> Path.wildcard()
        |> Enum.map(&Path.basename(&1, ".json"))
        |> MapSet.new()

      for scenario <- ScenarioCatalog.scenarios(),
          scenario.proof == :fixture_replay,
          fixture <- scenario.fixtures do
        assert MapSet.member?(fixture_files, fixture),
               "missing fixture evidence for scenario #{scenario.id} fixture #{fixture}"
      end

      for route <- ScenarioCatalog.routes() do
        assert File.exists?(route.test_file),
               "missing focused coverage route for scenario #{route.scenario}: #{route.test_file}"
      end
    end

    test "every current coverage scenario tag resolves through the catalog" do
      sources =
        Path.wildcard("test/coverage/**/*.exs") ++
          Path.wildcard("test/support/provider_test/*.ex")

      source = Enum.map_join(sources, "\n", &File.read!/1)
      refute source =~ "@tag scenario:"

      tagged_ids =
        ~r/CompatibilityScenario\.tag!\(:(?<id>[a-z0-9_]+)\)/
        |> Regex.scan(source, capture: :all_names)
        |> List.flatten()
        |> MapSet.new()

      catalog_ids = ScenarioCatalog.scenarios() |> Enum.map(& &1.id) |> MapSet.new()

      assert tagged_ids == catalog_ids
    end
  end

  describe "validation" do
    test "rejects duplicate scenario IDs" do
      capabilities = [%{id: "core", operation: :text}]
      scenarios = [scenario("basic"), scenario("basic")]

      assert_raise ArgumentError, ~r/duplicate scenario IDs/, fn ->
        ScenarioCatalog.validate!(@operations, capabilities, scenarios, [])
      end
    end

    test "rejects unknown capabilities" do
      capabilities = [%{id: "core", operation: :text}]
      scenarios = [scenario("basic", capability: "missing")]

      assert_raise ArgumentError, ~r/references unknown capability/, fn ->
        ScenarioCatalog.validate!(@operations, capabilities, scenarios, [])
      end
    end

    test "rejects invalid routes" do
      capabilities = [%{id: "core", operation: :text}]
      scenarios = [scenario("basic")]
      routes = [%{provider: :openai, scenario: "unknown", test_file: "test/coverage/openai.exs"}]

      assert_raise ArgumentError, ~r/invalid scenario route/, fn ->
        ScenarioCatalog.validate!(@operations, capabilities, scenarios, routes)
      end
    end

    test "identifies missing fixture contracts and unknown requirement tags" do
      capabilities = [%{id: "core", operation: :text}]

      assert_raise ArgumentError, ~r/scenario "basic" is missing its fixture contract/, fn ->
        ScenarioCatalog.validate!(
          @operations,
          capabilities,
          [scenario("basic", fixtures: [])],
          []
        )
      end

      assert_raise ArgumentError,
                   ~r/scenario "basic" has invalid requirements: \[:unknown\]/,
                   fn ->
                     ScenarioCatalog.validate!(
                       @operations,
                       capabilities,
                       [scenario("basic", requirements: [:unknown])],
                       []
                     )
                   end
    end
  end

  defp scenario(id, overrides \\ []) do
    Map.merge(
      %{
        id: id,
        capability: "core",
        operation: :text,
        input_modalities: [:text],
        output_modalities: [:text],
        requirements: [],
        transports: [:request_response],
        fixtures: [id],
        proof: :fixture_replay,
        applicability: :operation,
        providers: :all
      },
      Map.new(overrides)
    )
  end
end
