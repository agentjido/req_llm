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
  @type scenario :: %{required(:id) => binary(), required(:capability) => binary()}
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
    %{id: "streaming_structured_output", operation: :text}
  ]

  @scenarios [
    %{id: "basic", capability: "core"},
    %{id: "usage", capability: "core"},
    %{id: "token_limit", capability: "core"},
    %{id: "context_append", capability: "conversation"},
    %{id: "streaming", capability: "streaming"},
    %{id: "tool_none", capability: "tools"},
    %{id: "tool_multi", capability: "tools"},
    %{id: "tool_round_trip", capability: "tools"},
    %{id: "object_basic", capability: "objects"},
    %{id: "object_streaming", capability: "objects"},
    %{id: "reasoning", capability: "reasoning"},
    %{id: "embed_basic", capability: "embedding"},
    %{id: "embed_usage", capability: "embedding"},
    %{id: "embed_batch", capability: "embedding"},
    %{id: "image_basic", capability: "image"},
    %{id: "speech_basic", capability: "speech"},
    %{id: "transcription_basic", capability: "transcription"},
    %{id: "rerank_basic", capability: "rerank"},
    %{id: "ocr_basic", capability: "ocr"},
    %{id: "grounding_basic", capability: "grounding"},
    %{id: "grounding_with_context", capability: "grounding"},
    %{id: "grounding_streaming", capability: "grounding"},
    %{id: "grounding_legacy", capability: "grounding_legacy"},
    %{id: "multimodal_tool_result", capability: "multimodal_tool_result"},
    %{id: "web_search_basic", capability: "web_search"},
    %{id: "web_search_streaming", capability: "web_search"},
    %{id: "x_search_streaming", capability: "web_search"},
    %{id: "object_streaming_json_schema", capability: "streaming_structured_output"},
    %{id: "object_streaming_tool_strict", capability: "streaming_structured_output"},
    %{id: "object_streaming_auto", capability: "streaming_structured_output"},
    %{id: "streaming_error_handling", capability: "streaming_structured_output"}
  ]

  @routes [
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
