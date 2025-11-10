# lib/req_llm/ontology/diff.ex
# Purpose: Ontology diff calculator for Σ versions (gitvan phase)

defmodule ReqLLM.Ontology.Diff do
  @moduledoc """
  Calculates semantic diffs between Σ ontology versions.

  Compares two versions of the ontology to detect:
  - Added classes and properties
  - Removed classes and properties (breaking changes)
  - Modified constraints (breaking if tightened)
  - Renamed elements (breaking)

  ## Usage

  ```elixir
  # Compare current with previous version
  diff = Diff.compare("ontologies/reqllm.sigma_observed.ttl",
                      "ontologies/previous/sigma.ttl")

  # Categorize changes
  changes = Diff.categorize(diff)
  # => %{
  #   breaking: [...],
  #   additions: [...],
  #   modifications: [...]
  # }

  # Determine version bump
  version_bump = Diff.suggest_version_bump(changes)
  # => :major | :minor | :patch
  ```
  """

  @type diff :: %{
          added_classes: [String.t()],
          removed_classes: [String.t()],
          added_properties: [String.t()],
          removed_properties: [String.t()],
          modified_properties: [property_change()],
          modified_constraints: [constraint_change()]
        }

  @type property_change :: %{
          property: String.t(),
          old_domain: String.t() | nil,
          new_domain: String.t() | nil,
          old_range: String.t() | nil,
          new_range: String.t() | nil
        }

  @type constraint_change :: %{
          class: String.t(),
          property: String.t(),
          change_type: :cardinality | :range | :pattern,
          old_value: any(),
          new_value: any()
        }

  @doc """
  Compare two ontology versions and return diff.

  Parses both TTL files and calculates differences.
  """
  def compare(current_path, previous_path) do
    current = parse_ontology(current_path)
    previous = parse_ontology(previous_path)

    %{
      added_classes: MapSet.difference(current.classes, previous.classes) |> MapSet.to_list(),
      removed_classes:
        MapSet.difference(previous.classes, current.classes) |> MapSet.to_list(),
      added_properties:
        MapSet.difference(current.properties, previous.properties) |> MapSet.to_list(),
      removed_properties:
        MapSet.difference(previous.properties, current.properties) |> MapSet.to_list(),
      modified_properties: find_property_changes(current.property_defs, previous.property_defs),
      modified_constraints: []
    }
  end

  @doc """
  Categorize changes into breaking/non-breaking.

  ## Breaking Changes
  - Removed classes
  - Removed properties
  - Changed property domains (narrowed)
  - Changed property ranges (incompatible)
  - Tightened cardinality constraints

  ## Non-Breaking Changes
  - Added classes
  - Added properties
  - Relaxed constraints
  - Added optional properties
  """
  def categorize(diff) do
    breaking =
      diff.removed_classes ++
        diff.removed_properties ++
        Enum.filter(diff.modified_properties, &breaking_property_change?/1)

    additions = diff.added_classes ++ diff.added_properties

    modifications =
      Enum.reject(diff.modified_properties, &breaking_property_change?/1)

    %{
      breaking: breaking,
      additions: additions,
      modifications: modifications
    }
  end

  @doc """
  Suggest semantic version bump based on changes.

  - Major: Breaking changes (removed/incompatible)
  - Minor: New features (added classes/properties)
  - Patch: Bug fixes, documentation
  """
  def suggest_version_bump(categorized_changes) do
    cond do
      length(categorized_changes.breaking) > 0 -> :major
      length(categorized_changes.additions) > 0 -> :minor
      length(categorized_changes.modifications) > 0 -> :patch
      true -> :patch
    end
  end

  @doc """
  Get human-readable summary of changes.
  """
  def summarize(diff) do
    categorized = categorize(diff)

    """
    Ontology Changes Summary
    ========================

    Breaking Changes (#{length(categorized.breaking)}):
    #{format_list(categorized.breaking)}

    Additions (#{length(categorized.additions)}):
    #{format_list(categorized.additions)}

    Modifications (#{length(categorized.modifications)}):
    #{format_list(categorized.modifications)}

    Recommended Version Bump: #{suggest_version_bump(categorized) |> Atom.to_string() |> String.upcase()}
    """
  end

  @doc """
  Parse ontology file and extract classes/properties.

  This is a simplified parser - in production, use proper RDF library
  like RDF.ex or parse with Apache Jena.
  """
  def parse_ontology(path) do
    content = File.read!(path)

    # Extract classes (lines with "a rdfs:Class")
    classes =
      Regex.scan(~r/^(req:\w+)\s+a rdfs:Class/m, content)
      |> Enum.map(fn [_, class] -> class end)
      |> MapSet.new()

    # Extract properties (lines with "a rdf:Property")
    properties =
      Regex.scan(~r/^(req:\w+)\s+a rdf:Property/m, content)
      |> Enum.map(fn [_, prop] -> prop end)
      |> MapSet.new()

    # Extract property definitions (domain, range)
    property_defs =
      properties
      |> Enum.map(fn prop ->
        domain = extract_property_attr(content, prop, "rdfs:domain")
        range = extract_property_attr(content, prop, "rdfs:range")
        {prop, %{domain: domain, range: range}}
      end)
      |> Enum.into(%{})

    %{
      classes: classes,
      properties: properties,
      property_defs: property_defs
    }
  end

  @doc """
  Calculate hash of ontology for version receipts.
  """
  def calculate_hash(ontology_path) do
    content = File.read!(ontology_path)

    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 12)
  end

  # -- Private Helpers --

  defp extract_property_attr(content, property, attr) do
    regex = ~r/#{Regex.escape(property)}\s+.*?#{Regex.escape(attr)}\s+(\S+)/s

    case Regex.run(regex, content) do
      [_, value] -> String.trim(value, ";. ")
      nil -> nil
    end
  end

  defp find_property_changes(current_defs, previous_defs) do
    common_props =
      MapSet.intersection(
        MapSet.new(Map.keys(current_defs)),
        MapSet.new(Map.keys(previous_defs))
      )

    common_props
    |> Enum.map(fn prop ->
      current = current_defs[prop]
      previous = previous_defs[prop]

      if current != previous do
        %{
          property: prop,
          old_domain: previous.domain,
          new_domain: current.domain,
          old_range: previous.range,
          new_range: current.range
        }
      else
        nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp breaking_property_change?(change) when is_binary(change), do: true

  defp breaking_property_change?(change) when is_map(change) do
    # Domain narrowed (was nil, now specific) is breaking
    domain_narrowed = change.old_domain == nil and change.new_domain != nil

    # Range changed incompatibly is breaking
    range_changed = change.old_range != change.new_range and change.old_range != nil

    domain_narrowed or range_changed
  end

  defp format_list([]), do: "  (none)"

  defp format_list(items) do
    items
    |> Enum.map(fn
      item when is_binary(item) -> "  - #{item}"
      item when is_map(item) -> "  - #{format_change(item)}"
    end)
    |> Enum.join("\n")
  end

  defp format_change(%{property: prop, old_domain: old_d, new_domain: new_d}) do
    "#{prop}: domain changed from #{old_d || "any"} to #{new_d || "any"}"
  end

  defp format_change(change), do: inspect(change)
end
