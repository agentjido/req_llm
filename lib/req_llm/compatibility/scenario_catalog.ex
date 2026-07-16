defmodule ReqLLM.Compatibility.ScenarioCatalog do
  @moduledoc """
  Compiled catalog of compatibility scenarios used by ReqLLM's test tooling.

  The catalog centralizes capability membership, operation metadata, and
  provider-specific test routing while preserving the established scenario and
  command-line selection order.
  """

  alias ReqLLM.Compatibility.ScenarioCatalog.Validator

  @type operation :: %{
          required(:id) => atom(),
          required(:test_file) => binary() | :provider_directory
        }
  @type capability :: %{required(:id) => binary(), required(:operation) => atom()}
  @type scenario :: %{
          required(:id) => binary(),
          required(:capability) => binary(),
          required(:operation) => atom(),
          required(:input_modalities) => [atom()],
          required(:output_modalities) => [atom()],
          required(:requirements) => [atom()],
          required(:transports) => [atom()],
          required(:fixtures) => [binary()],
          required(:proof) => atom(),
          required(:applicability) => atom(),
          required(:providers) => :all | [atom()]
        }
  @type route :: %{
          required(:provider) => atom(),
          required(:scenario) => binary(),
          required(:test_file) => binary()
        }

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

  @capabilities [
    %{id: "core", operation: :text},
    %{id: "conversation", operation: :text},
    %{id: "streaming", operation: :text},
    %{id: "tools", operation: :text},
    %{id: "objects", operation: :text},
    %{id: "reasoning", operation: :text},
    %{id: "embedding", operation: :embedding},
    %{id: "image", operation: :image},
    %{id: "speech", operation: :speech},
    %{id: "transcription", operation: :transcription},
    %{id: "rerank", operation: :rerank},
    %{id: "ocr", operation: :ocr},
    %{id: "grounding", operation: :text},
    %{id: "grounding_legacy", operation: :text},
    %{id: "multimodal_tool_result", operation: :text},
    %{id: "web_search", operation: :text},
    %{id: "web_fetch", operation: :text},
    %{id: "logprobs", operation: :text},
    %{id: "request_metadata", operation: :text},
    %{id: "tool_id_compat", operation: :text},
    %{id: "streaming_structured_output", operation: :text},
    %{id: "azure_streaming_structured_output", operation: :text}
  ]

  @scenario_defaults %{
    input_modalities: [:text],
    output_modalities: [:text],
    requirements: [],
    transports: [:request_response],
    proof: :fixture_replay,
    applicability: :operation,
    providers: :all
  }

  @scenario_specs Enum.map(
                    [
                      {"basic", "core", []},
                      {"usage", "core", []},
                      {"token_limit", "core", []},
                      {"context_append", "conversation",
                       fixtures: ["context_append_1", "context_append_2"]},
                      {"streaming", "streaming", transports: [:server_sent_events]},
                      {"tool_none", "tools",
                       requirements: [:tool_calling],
                       applicability: :model_features,
                       fixtures: ["no_tool"]},
                      {"tool_multi", "tools",
                       output_modalities: [:text, :tool_call],
                       requirements: [:tool_calling],
                       applicability: :model_features,
                       fixtures: ["multi_tool"]},
                      {"tool_round_trip", "tools",
                       input_modalities: [:text, :tool_result],
                       output_modalities: [:text, :tool_call],
                       requirements: [:tool_calling],
                       applicability: :model_features,
                       fixtures: ["tool_round_trip_1", "tool_round_trip_2"]},
                      {"object_basic", "objects",
                       output_modalities: [:structured_object],
                       requirements: [:object_generation],
                       applicability: :model_features},
                      {"object_streaming", "objects",
                       output_modalities: [:structured_object],
                       requirements: [:streaming_object_generation],
                       transports: [:server_sent_events],
                       applicability: :model_features},
                      {"reasoning", "reasoning",
                       output_modalities: [:text, :reasoning],
                       requirements: [:reasoning],
                       transports: [:request_response, :server_sent_events],
                       applicability: :model_features,
                       fixtures: ["reasoning_basic", "reasoning_streaming"]},
                      {"embed_basic", "embedding",
                       output_modalities: [:embedding], requirements: [:embedding]},
                      {"embed_usage", "embedding",
                       output_modalities: [:embedding, :usage],
                       requirements: [:embedding],
                       fixtures: ["embed_basic"]},
                      {"embed_batch", "embedding",
                       output_modalities: [:embedding], requirements: [:embedding]},
                      {"image_basic", "image",
                       output_modalities: [:image], requirements: [:image_generation]},
                      {"speech_basic", "speech",
                       output_modalities: [:audio], requirements: [:speech_generation]},
                      {"transcription_basic", "transcription",
                       input_modalities: [:audio], requirements: [:transcription]},
                      {"rerank_basic", "rerank",
                       output_modalities: [:ranked_documents], requirements: [:reranking]},
                      {"ocr_basic", "ocr",
                       input_modalities: [:document], requirements: [:ocr], proof: :declared},
                      {"grounding_basic", "grounding",
                       requirements: [:grounding], applicability: :focused, providers: [:google]},
                      {"grounding_with_context", "grounding",
                       requirements: [:grounding],
                       applicability: :focused,
                       providers: [:google],
                       fixtures: ["grounding_context"]},
                      {"grounding_streaming", "grounding",
                       requirements: [:grounding],
                       transports: [:server_sent_events],
                       applicability: :focused,
                       providers: [:google]},
                      {"grounding_legacy", "grounding_legacy",
                       requirements: [:grounding],
                       proof: :declared,
                       applicability: :focused,
                       providers: [:google]},
                      {"multimodal_tool_result", "multimodal_tool_result",
                       input_modalities: [:text, :document, :tool_result],
                       output_modalities: [:text, :tool_call],
                       requirements: [:multimodal_tool_result],
                       applicability: :focused,
                       providers: [:google],
                       fixtures: ["multimodal_tool_result_1", "multimodal_tool_result_2"]},
                      {"web_search_basic", "web_search",
                       requirements: [:web_search],
                       applicability: :focused,
                       providers: [:anthropic, :openai, :xai]},
                      {"web_search_streaming", "web_search",
                       requirements: [:web_search],
                       transports: [:server_sent_events],
                       applicability: :focused,
                       providers: [:openai, :xai]},
                      {"x_search_streaming", "web_search",
                       requirements: [:web_search],
                       transports: [:server_sent_events],
                       applicability: :focused,
                       providers: [:xai]},
                      {"object_streaming_json_schema", "streaming_structured_output",
                       output_modalities: [:structured_object],
                       requirements: [:streaming_object_generation],
                       transports: [:server_sent_events],
                       applicability: :focused,
                       providers: [:anthropic, :azure, :xai]},
                      {"object_streaming_tool_strict", "streaming_structured_output",
                       output_modalities: [:structured_object, :tool_call],
                       requirements: [:streaming_object_generation],
                       transports: [:server_sent_events],
                       applicability: :focused,
                       providers: [:anthropic, :azure, :xai]},
                      {"object_streaming_auto", "streaming_structured_output",
                       output_modalities: [:structured_object],
                       requirements: [:streaming_object_generation],
                       transports: [:server_sent_events],
                       applicability: :focused,
                       providers: [:anthropic, :azure, :xai],
                       fixtures: ["object_streaming_auto", "object_streaming_auto_with_tools"]},
                      {"streaming_error_handling", "streaming_structured_output",
                       output_modalities: [:structured_object],
                       requirements: [:streaming_object_generation],
                       transports: [:server_sent_events],
                       applicability: :focused,
                       providers: [:azure, :xai],
                       fixtures: ["streaming_truncated"]},
                      {"web_fetch_basic", "web_fetch",
                       requirements: [:web_fetch],
                       applicability: :focused,
                       providers: [:anthropic]},
                      {"logprobs_non_streaming", "logprobs",
                       output_modalities: [:text, :token_logprobs],
                       requirements: [:logprobs],
                       proof: :declared,
                       applicability: :focused,
                       providers: [:openai]},
                      {"labels_basic", "request_metadata",
                       requirements: [:request_labels],
                       applicability: :focused,
                       providers: [:google_vertex]},
                      {"tool_id_compat_openai_passthrough", "tool_id_compat",
                       input_modalities: [:text, :tool_call, :tool_result],
                       requirements: [:cross_provider_tool_ids],
                       proof: :live_only,
                       applicability: :integration,
                       providers: [:openai],
                       fixtures: ["tool_call_id_compat_openai_passthrough"]},
                      {"tool_id_compat_openai_to_anthropic", "tool_id_compat",
                       input_modalities: [:text, :tool_call, :tool_result],
                       requirements: [:cross_provider_tool_ids],
                       proof: :live_only,
                       applicability: :integration,
                       providers: [:anthropic],
                       fixtures: ["tool_call_id_compat_openai_to_anthropic"]},
                      {"tool_id_compat_turn_boundary", "tool_id_compat",
                       input_modalities: [:text, :tool_call],
                       requirements: [:cross_provider_tool_ids],
                       proof: :live_only,
                       applicability: :integration,
                       providers: [:anthropic],
                       fixtures: []},
                      {"object_streaming_claude_tool", "azure_streaming_structured_output",
                       output_modalities: [:structured_object, :tool_call],
                       requirements: [:streaming_object_generation],
                       transports: [:server_sent_events],
                       proof: :declared,
                       applicability: :focused,
                       providers: [:azure]},
                      {"object_streaming_claude_auto", "azure_streaming_structured_output",
                       output_modalities: [:structured_object],
                       requirements: [:streaming_object_generation],
                       transports: [:server_sent_events],
                       proof: :declared,
                       applicability: :focused,
                       providers: [:azure]}
                    ],
                    fn {id, capability, attrs} ->
                      @scenario_defaults
                      |> Map.merge(Map.new(attrs))
                      |> Map.put(:id, id)
                      |> Map.put(:capability, capability)
                      |> Map.put_new(:fixtures, [id])
                    end
                  )

  @scenarios Enum.map(@scenario_specs, fn scenario ->
               capability = Enum.find(@capabilities, &(&1.id == scenario.capability))

               @scenario_defaults
               |> Map.merge(scenario)
               |> Map.put(:operation, capability.operation)
             end)

  @routes [
    %{
      provider: :openai,
      scenario: "logprobs_non_streaming",
      test_file: "test/coverage/openai/logprobs_test.exs"
    },
    %{
      provider: :openai,
      scenario: "web_search_basic",
      test_file: "test/coverage/openai/web_search_test.exs"
    },
    %{
      provider: :openai,
      scenario: "web_search_streaming",
      test_file: "test/coverage/openai/web_search_test.exs"
    },
    %{
      provider: :anthropic,
      scenario: "web_fetch_basic",
      test_file: "test/coverage/anthropic/web_fetch_test.exs"
    },
    %{
      provider: :anthropic,
      scenario: "web_search_basic",
      test_file: "test/coverage/anthropic/web_search_test.exs"
    },
    %{
      provider: :anthropic,
      scenario: "object_streaming_json_schema",
      test_file: "test/coverage/anthropic/streaming_structured_output_test.exs"
    },
    %{
      provider: :anthropic,
      scenario: "object_streaming_tool_strict",
      test_file: "test/coverage/anthropic/streaming_structured_output_test.exs"
    },
    %{
      provider: :anthropic,
      scenario: "object_streaming_auto",
      test_file: "test/coverage/anthropic/streaming_structured_output_test.exs"
    },
    %{
      provider: :azure,
      scenario: "object_streaming_json_schema",
      test_file: "test/coverage/azure/streaming_structured_output_test.exs"
    },
    %{
      provider: :azure,
      scenario: "object_streaming_tool_strict",
      test_file: "test/coverage/azure/streaming_structured_output_test.exs"
    },
    %{
      provider: :azure,
      scenario: "object_streaming_auto",
      test_file: "test/coverage/azure/streaming_structured_output_test.exs"
    },
    %{
      provider: :azure,
      scenario: "streaming_error_handling",
      test_file: "test/coverage/azure/streaming_structured_output_test.exs"
    },
    %{
      provider: :azure,
      scenario: "object_streaming_claude_tool",
      test_file: "test/coverage/azure/streaming_structured_output_test.exs"
    },
    %{
      provider: :azure,
      scenario: "object_streaming_claude_auto",
      test_file: "test/coverage/azure/streaming_structured_output_test.exs"
    },
    %{
      provider: :google_vertex,
      scenario: "labels_basic",
      test_file: "test/coverage/google_vertex_gemini/labels_test.exs"
    },
    %{
      provider: :google,
      scenario: "grounding_basic",
      test_file: "test/coverage/google/grounding_test.exs"
    },
    %{
      provider: :google,
      scenario: "grounding_with_context",
      test_file: "test/coverage/google/grounding_test.exs"
    },
    %{
      provider: :google,
      scenario: "grounding_streaming",
      test_file: "test/coverage/google/grounding_test.exs"
    },
    %{
      provider: :google,
      scenario: "grounding_legacy",
      test_file: "test/coverage/google/grounding_test.exs"
    },
    %{
      provider: :google,
      scenario: "multimodal_tool_result",
      test_file: "test/coverage/google/multimodal_tool_result_test.exs"
    },
    %{
      provider: :xai,
      scenario: "web_search_basic",
      test_file: "test/coverage/xai/web_search_test.exs"
    },
    %{
      provider: :xai,
      scenario: "web_search_streaming",
      test_file: "test/coverage/xai/web_search_test.exs"
    },
    %{
      provider: :xai,
      scenario: "x_search_streaming",
      test_file: "test/coverage/xai/web_search_test.exs"
    },
    %{
      provider: :xai,
      scenario: "object_streaming_json_schema",
      test_file: "test/coverage/xai/streaming_structured_output_test.exs"
    },
    %{
      provider: :xai,
      scenario: "object_streaming_tool_strict",
      test_file: "test/coverage/xai/streaming_structured_output_test.exs"
    },
    %{
      provider: :xai,
      scenario: "object_streaming_auto",
      test_file: "test/coverage/xai/streaming_structured_output_test.exs"
    },
    %{
      provider: :xai,
      scenario: "streaming_error_handling",
      test_file: "test/coverage/xai/streaming_structured_output_test.exs"
    }
  ]

  :ok = Validator.validate!(@operations, @capabilities, @scenarios, @routes)

  @doc "Returns operation routing metadata in canonical operation order."
  @spec operations() :: [operation()]
  def operations, do: @operations

  @doc "Returns the catalog's capability definitions in declaration order."
  @spec capabilities() :: [capability()]
  def capabilities, do: @capabilities

  @doc "Returns the catalog's scenario definitions in selection order."
  @spec scenarios() :: [scenario()]
  def scenarios, do: @scenarios

  @doc "Returns all provider-specific test routes."
  @spec routes() :: [route()]
  def routes, do: @routes

  @doc "Returns metadata for a known scenario."
  @spec fetch_scenario(atom() | binary()) :: {:ok, scenario()} | :error
  def fetch_scenario(id) when is_atom(id) or is_binary(id) do
    id = to_string(id)

    case Enum.find(@scenarios, &(&1.id == id)) do
      nil -> :error
      scenario -> {:ok, scenario}
    end
  end

  @doc "Returns metadata for a known scenario or raises for an unknown ID."
  @spec fetch_scenario!(atom() | binary()) :: scenario()
  def fetch_scenario!(id) when is_atom(id) or is_binary(id) do
    case fetch_scenario(id) do
      {:ok, scenario} -> scenario
      :error -> raise ArgumentError, "unknown compatibility scenario: #{inspect(id)}"
    end
  end

  @doc "Returns the ordered fixture contract for a known scenario."
  @spec fixtures(atom() | binary()) :: [binary()]
  def fixtures(id), do: fetch_scenario!(id).fixtures

  @doc "Returns one fixture name from a scenario's ordered fixture contract."
  @spec fixture!(atom() | binary(), non_neg_integer()) :: binary()
  def fixture!(id, index \\ 0) when is_integer(index) and index >= 0 do
    scenario = fetch_scenario!(id)

    case Enum.fetch(scenario.fixtures, index) do
      {:ok, fixture} ->
        fixture

      :error ->
        raise ArgumentError,
              "scenario #{inspect(scenario.id)} has no fixture at index #{index}"
    end
  end

  @doc "Returns ordered scenario IDs for a capability."
  @spec scenarios_for_capability(binary()) :: {:ok, [binary()]} | :error
  def scenarios_for_capability(capability) when is_binary(capability) do
    if Enum.any?(@capabilities, &(&1.id == capability)) do
      {:ok,
       @scenarios
       |> Enum.filter(&(&1.capability == capability))
       |> Enum.map(& &1.id)}
    else
      :error
    end
  end

  @doc "Returns ordered per-model compatibility scenarios for a capability and provider."
  @spec model_compat_scenarios_for_capability(binary(), atom()) ::
          {:ok, [binary()]} | :error
  def model_compat_scenarios_for_capability(capability, provider)
      when is_binary(capability) and is_atom(provider) do
    if Enum.any?(@capabilities, &(&1.id == capability)) do
      {:ok,
       @scenarios
       |> Enum.filter(&(&1.capability == capability and provider_applicable?(&1, provider)))
       |> Enum.reject(&(&1.applicability == :integration or &1.proof == :live_only))
       |> Enum.map(& &1.id)}
    else
      :error
    end
  end

  @doc "Returns the legacy default scenarios for a selected operation capability."
  @spec operation_defaults(atom(), binary() | nil) :: [binary()]
  def operation_defaults(operation, selected_capability) when is_atom(operation) do
    operation_capability = Atom.to_string(operation)

    case Enum.find(@capabilities, &(&1.id == operation_capability)) do
      %{operation: ^operation} when selected_capability == operation_capability ->
        {:ok, scenarios} = scenarios_for_capability(operation_capability)
        scenarios

      _ ->
        []
    end
  end

  @doc "Returns the selected test file for a provider, operation, and optional scenario."
  @spec test_file(atom(), atom(), atom() | binary() | nil) :: binary()
  def test_file(provider, operation, scenario \\ nil) when is_atom(provider) do
    scenario_test_file(provider, scenario) || operation_test_file(provider, operation)
  end

  @doc "Returns the focused test file for a provider and scenario, if configured."
  @spec scenario_test_file(atom(), atom() | binary() | nil) :: binary() | nil
  def scenario_test_file(_provider, nil), do: nil

  def scenario_test_file(provider, scenario) when is_atom(provider) do
    scenario = to_string(scenario)

    Enum.find_value(@routes, fn route ->
      if route.provider == provider and route.scenario == scenario, do: route.test_file
    end)
  end

  defp provider_applicable?(%{providers: :all}, _provider), do: true
  defp provider_applicable?(%{providers: providers}, provider), do: provider in providers

  @doc "Returns the established coverage test file for a provider operation."
  @spec operation_test_file(atom(), atom()) :: binary()
  def operation_test_file(provider, operation) when is_atom(provider) do
    case Enum.find(@operations, &(&1.id == operation)) do
      %{test_file: :provider_directory} ->
        "test/coverage/#{provider}"

      %{test_file: test_file} ->
        "test/coverage/#{provider}/#{test_file}"

      nil ->
        raise ArgumentError, "unknown compatibility operation: #{inspect(operation)}"
    end
  end

  @doc false
  @spec validate!([map()], [map()], [map()], [map()]) :: :ok
  defdelegate validate!(operations, capabilities, scenarios, routes), to: Validator
end
