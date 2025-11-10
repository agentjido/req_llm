# lib/req_llm/ontology/metrics.ex
# Purpose: Ontology coverage and usage metrics (KNHK phase)

defmodule ReqLLM.Ontology.Metrics do
  @moduledoc """
  Tracks ontology coverage and usage patterns.

  Monitors which parts of the ontology are actively used in production,
  enabling ontology refinement and deprecation detection.

  ## Metrics

  - **Class Coverage**: Which RDF classes are instantiated
  - **Property Coverage**: Which properties are populated
  - **ContentPart Distribution**: Frequency of each ContentPart variant
  - **FinishReason Distribution**: Distribution of termination reasons
  - **Validation Failure Rate**: Percentage of validation failures by type
  """

  use GenServer
  require Logger

  @table :req_llm_ontology_metrics

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Record ontology class usage.

  Examples:
  - `record_class("req:Response")`
  - `record_class("req:TextPart")`
  """
  def record_class(class_name) when is_binary(class_name) do
    GenServer.cast(__MODULE__, {:record_class, class_name})
  end

  @doc """
  Record ontology property usage.

  Examples:
  - `record_property("req:hasContext")`
  - `record_property("req:inputTokens")`
  """
  def record_property(property_name) when is_binary(property_name) do
    GenServer.cast(__MODULE__, {:record_property, property_name})
  end

  @doc """
  Record ContentPart variant usage.
  """
  def record_part_type(part_type) when is_atom(part_type) or is_binary(part_type) do
    GenServer.cast(__MODULE__, {:record_part_type, to_string(part_type)})
  end

  @doc """
  Record FinishReason occurrence.
  """
  def record_finish_reason(reason) when is_atom(reason) or is_binary(reason) do
    GenServer.cast(__MODULE__, {:record_finish_reason, to_string(reason)})
  end

  @doc """
  Record validation failure.
  """
  def record_validation_failure(type, errors) do
    GenServer.cast(__MODULE__, {:record_validation_failure, type, length(errors)})
  end

  @doc """
  Get current metrics snapshot.

  Returns map with:
  - classes: %{"req:Response" => 42, ...}
  - properties: %{"req:hasContext" => 42, ...}
  - part_types: %{"TextPart" => 150, ...}
  - finish_reasons: %{"stop" => 38, "tool_calls" => 4}
  - validation_failures: %{"req:Message" => 2}
  """
  def get_metrics do
    GenServer.call(__MODULE__, :get_metrics)
  end

  @doc """
  Reset all metrics.
  """
  def reset_metrics do
    GenServer.call(__MODULE__, :reset_metrics)
  end

  @doc """
  Get ontology coverage report.

  Returns percentage of Σ classes/properties that have been used.
  """
  def coverage_report do
    metrics = get_metrics()

    # Known classes from Σ
    known_classes = [
      "req:Model",
      "req:Provider",
      "req:Context",
      "req:Message",
      "req:ContentPart",
      "req:TextPart",
      "req:ImageURLPart",
      "req:ImagePart",
      "req:FilePart",
      "req:ThinkingPart",
      "req:ToolCallPart",
      "req:ToolResultPart",
      "req:Tool",
      "req:StreamChunk",
      "req:Response",
      "req:StreamResponse",
      "req:Usage"
    ]

    # Known properties (subset for tracking)
    known_properties = [
      "req:hasContext",
      "req:hasMessage",
      "req:hasMessageOut",
      "req:hasUsage",
      "req:hasPart",
      "req:finishReason",
      "req:role",
      "req:text",
      "req:url",
      "req:toolName",
      "req:argumentsJson",
      "req:inputTokens",
      "req:outputTokens",
      "req:totalCost"
    ]

    used_classes = Map.keys(metrics.classes) |> MapSet.new()
    used_properties = Map.keys(metrics.properties) |> MapSet.new()

    %{
      class_coverage:
        (MapSet.size(used_classes) / length(known_classes) * 100)
        |> Float.round(1),
      property_coverage:
        (MapSet.size(used_properties) / length(known_properties) * 100)
        |> Float.round(1),
      used_classes: MapSet.to_list(used_classes),
      unused_classes:
        MapSet.difference(MapSet.new(known_classes), used_classes) |> MapSet.to_list(),
      used_properties: MapSet.to_list(used_properties),
      unused_properties:
        MapSet.difference(MapSet.new(known_properties), used_properties) |> MapSet.to_list(),
      total_interactions: Map.get(metrics.classes, "req:Response", 0)
    }
  end

  ## Server Callbacks

  @impl true
  def init(_opts) do
    # Create ETS table for metrics storage
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])

    # Initialize counters
    :ets.insert(@table, {:classes, %{}})
    :ets.insert(@table, {:properties, %{}})
    :ets.insert(@table, {:part_types, %{}})
    :ets.insert(@table, {:finish_reasons, %{}})
    :ets.insert(@table, {:validation_failures, %{}})

    {:ok, %{}}
  end

  @impl true
  def handle_cast({:record_class, class_name}, state) do
    increment_counter(:classes, class_name)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:record_property, property_name}, state) do
    increment_counter(:properties, property_name)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:record_part_type, part_type}, state) do
    increment_counter(:part_types, part_type)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:record_finish_reason, reason}, state) do
    increment_counter(:finish_reasons, reason)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:record_validation_failure, type, _count}, state) do
    increment_counter(:validation_failures, type)
    {:noreply, state}
  end

  @impl true
  def handle_call(:get_metrics, _from, state) do
    metrics = %{
      classes: get_counter_map(:classes),
      properties: get_counter_map(:properties),
      part_types: get_counter_map(:part_types),
      finish_reasons: get_counter_map(:finish_reasons),
      validation_failures: get_counter_map(:validation_failures)
    }

    {:reply, metrics, state}
  end

  @impl true
  def handle_call(:reset_metrics, _from, state) do
    :ets.insert(@table, {:classes, %{}})
    :ets.insert(@table, {:properties, %{}})
    :ets.insert(@table, {:part_types, %{}})
    :ets.insert(@table, {:finish_reasons, %{}})
    :ets.insert(@table, {:validation_failures, %{}})

    {:reply, :ok, state}
  end

  ## Private Helpers

  defp increment_counter(category, key) do
    [{^category, map}] = :ets.lookup(@table, category)
    updated_map = Map.update(map, key, 1, &(&1 + 1))
    :ets.insert(@table, {category, updated_map})
  end

  defp get_counter_map(category) do
    case :ets.lookup(@table, category) do
      [{^category, map}] -> map
      [] -> %{}
    end
  end
end
