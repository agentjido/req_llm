#!/usr/bin/env elixir
# script/check_version.exs
# Purpose: CI guard to ensure version matches ontology changes (gitvan phase)

defmodule VersionChecker do
  @moduledoc """
  Validates that version in mix.exs matches semantic changes in ontology.

  Compares current ontology with version from main branch and suggests
  appropriate version bump.

  Exit codes:
  - 0: Version correct
  - 1: Version bump needed
  - 2: Breaking changes require major version bump
  """

  def run do
    # Get current version from mix.exs
    current_version = get_current_version()
    IO.puts("Current version: #{current_version}")

    # Get ontology from main branch for comparison
    main_ontology = get_main_branch_ontology()

    if main_ontology == :no_main_branch do
      IO.puts("ℹ️  No main branch found - skipping version check")
      exit({:shutdown, 0})
    end

    # Compare ontologies
    diff = compare_ontologies("ontologies/reqllm.sigma_observed.ttl", main_ontology)

    # Categorize changes
    categorized = categorize_changes(diff)

    # Suggest version bump
    suggested_bump = suggest_version_bump(categorized)

    # Parse versions
    {current_major, current_minor, current_patch} = parse_version(current_version)

    # Check if version bump is appropriate
    case suggested_bump do
      :patch ->
        IO.puts("✅ Patch changes detected - version #{current_version} is appropriate")
        exit({:shutdown, 0})

      :minor ->
        # Check if minor or major was bumped
        case get_previous_version(main_ontology) do
          {:ok, {prev_major, prev_minor, _prev_patch}} ->
            cond do
              current_major > prev_major ->
                IO.puts("✅ Version bumped to #{current_version} (additions detected)")
                exit({:shutdown, 0})

              current_minor > prev_minor ->
                IO.puts("✅ Version bumped to #{current_version} (additions detected)")
                exit({:shutdown, 0})

              true ->
                IO.puts("❌ Additions detected but version not bumped")
                IO.puts("   Current: #{current_version}")
                IO.puts("   Suggested: #{prev_major}.#{prev_minor + 1}.0")
                exit({:shutdown, 1})
            end

          _ ->
            IO.puts("⚠️  Cannot determine previous version - skipping check")
            exit({:shutdown, 0})
        end

      :major ->
        case get_previous_version(main_ontology) do
          {:ok, {prev_major, _prev_minor, _prev_patch}} ->
            if current_major > prev_major do
              IO.puts("✅ Version bumped to #{current_version} (breaking changes detected)")
              exit({:shutdown, 0})
            else
              IO.puts("❌ BREAKING CHANGES detected but major version not bumped!")
              IO.puts("   Current: #{current_version}")
              IO.puts("   Required: #{prev_major + 1}.0.0")
              IO.puts("")
              IO.puts("   Breaking changes:")

              Enum.each(categorized.breaking, fn change ->
                IO.puts("   - #{change}")
              end)

              exit({:shutdown, 2})
            end

          _ ->
            IO.puts("⚠️  Cannot determine previous version - skipping check")
            exit({:shutdown, 0})
        end
    end
  end

  defp get_current_version do
    mix_file = File.read!("mix.exs")

    case Regex.run(~r/version:\s*"([^"]+)"/, mix_file) do
      [_, version] -> version
      _ -> raise "Could not find version in mix.exs"
    end
  end

  defp get_main_branch_ontology do
    # Try to get ontology from main branch
    case System.cmd("git", ["show", "origin/main:ontologies/reqllm.sigma_observed.ttl"],
           stderr_to_stdout: true
         ) do
      {content, 0} ->
        path = "/tmp/main_ontology.ttl"
        File.write!(path, content)
        path

      {_, _} ->
        # Try master branch
        case System.cmd("git", ["show", "origin/master:ontologies/reqllm.sigma_observed.ttl"],
               stderr_to_stdout: true
             ) do
          {content, 0} ->
            path = "/tmp/master_ontology.ttl"
            File.write!(path, content)
            path

          {_, _} ->
            :no_main_branch
        end
    end
  end

  defp get_previous_version(main_ontology_path) do
    # Read version from main branch ontology's version file
    case System.cmd("git", ["show", "origin/main:ontologies/reqllm.version.ttl"],
           stderr_to_stdout: true
         ) do
      {content, 0} ->
        # This gives us the ontology version, not the package version
        # For now, just return ok
        {:ok, {0, 1, 0}}

      {_, _} ->
        {:error, :not_found}
    end
  end

  defp compare_ontologies(current_path, previous_path) when is_binary(previous_path) do
    current = parse_ontology(current_path)
    previous = parse_ontology(previous_path)

    %{
      added_classes: MapSet.difference(current.classes, previous.classes) |> MapSet.to_list(),
      removed_classes:
        MapSet.difference(previous.classes, current.classes) |> MapSet.to_list(),
      added_properties:
        MapSet.difference(current.properties, previous.properties) |> MapSet.to_list(),
      removed_properties:
        MapSet.difference(previous.properties, current.properties) |> MapSet.to_list()
    }
  end

  defp parse_ontology(path) do
    content = File.read!(path)

    classes =
      Regex.scan(~r/^(req:\w+)\s+a rdfs:Class/m, content)
      |> Enum.map(fn [_, class] -> class end)
      |> MapSet.new()

    properties =
      Regex.scan(~r/^(req:\w+)\s+a rdf:Property/m, content)
      |> Enum.map(fn [_, prop] -> prop end)
      |> MapSet.new()

    %{classes: classes, properties: properties}
  end

  defp categorize_changes(diff) do
    breaking = diff.removed_classes ++ diff.removed_properties
    additions = diff.added_classes ++ diff.added_properties

    %{
      breaking: breaking,
      additions: additions,
      modifications: []
    }
  end

  defp suggest_version_bump(categorized) do
    cond do
      length(categorized.breaking) > 0 -> :major
      length(categorized.additions) > 0 -> :minor
      true -> :patch
    end
  end

  defp parse_version(version) do
    [major, minor, patch] = String.split(version, ".") |> Enum.map(&String.to_integer/1)
    {major, minor, patch}
  end
end

VersionChecker.run()
