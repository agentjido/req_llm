# lib/req_llm/ontology/changelog.ex
# Purpose: Auto-generate CHANGELOG from ontology diffs (gitvan phase)

defmodule ReqLLM.Ontology.Changelog do
  @moduledoc """
  Generates CHANGELOG entries from Σ ontology diffs.

  Automatically creates versioned changelog entries based on
  semantic changes to the ontology.

  ## Usage

  ```elixir
  # Generate changelog entry for current changes
  entry = Changelog.generate_entry(diff, "0.2.0", "0.1.0")

  # Append to CHANGELOG.md
  Changelog.append_to_file(entry, "CHANGELOG.md")
  ```
  """

  alias ReqLLM.Ontology.Diff

  @doc """
  Generate CHANGELOG entry from diff.

  Returns Markdown-formatted changelog entry.
  """
  def generate_entry(diff, new_version, old_version) do
    categorized = Diff.categorize(diff)
    date = Date.utc_today() |> Date.to_iso8601()

    """
    ## [#{new_version}] - #{date}

    #{format_breaking_changes(categorized.breaking)}
    #{format_additions(categorized.additions)}
    #{format_modifications(categorized.modifications)}

    ### Migration Guide

    #{generate_migration_notes(categorized.breaking)}

    **Previous Version**: #{old_version}
    **Ontology Hash**: #{Diff.calculate_hash("ontologies/reqllm.sigma_observed.ttl")}
    """
  end

  @doc """
  Append changelog entry to CHANGELOG.md file.
  """
  def append_to_file(entry, changelog_path \\ "CHANGELOG.md") do
    # Read existing changelog
    existing =
      if File.exists?(changelog_path) do
        File.read!(changelog_path)
      else
        """
        # Changelog

        All notable changes to the ReqLLM ontology will be documented in this file.

        The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
        and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

        """
      end

    # Insert new entry after header
    lines = String.split(existing, "\n")
    {header, rest} = Enum.split_while(lines, &(!String.starts_with?(&1, "## [")))

    new_content =
      (header ++ [entry] ++ rest)
      |> Enum.join("\n")

    File.write!(changelog_path, new_content)
  end

  @doc """
  Generate full changelog from git history.

  Walks through git commits that changed the ontology file.
  """
  def generate_from_git(ontology_path \\ "ontologies/reqllm.sigma_observed.ttl") do
    # Get git log for ontology file
    {log, 0} =
      System.cmd("git", [
        "log",
        "--pretty=format:%H|%ai|%s",
        "--",
        ontology_path
      ])

    commits =
      log
      |> String.split("\n", trim: true)
      |> Enum.map(&parse_commit_line/1)

    # For each commit pair, generate diff and changelog
    commits
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [current, previous] ->
      generate_entry_from_commits(current, previous, ontology_path)
    end)
    |> Enum.join("\n\n")
  end

  # -- Private Helpers --

  defp format_breaking_changes([]), do: ""

  defp format_breaking_changes(breaking) do
    """
    ### ⚠️ BREAKING CHANGES

    #{Enum.map(breaking, &format_breaking_item/1) |> Enum.join("\n")}
    """
  end

  defp format_additions([]), do: ""

  defp format_additions(additions) do
    """
    ### ✨ Added

    #{Enum.map(additions, &"- `#{&1}`") |> Enum.join("\n")}
    """
  end

  defp format_modifications([]), do: ""

  defp format_modifications(mods) do
    """
    ### 🔧 Changed

    #{Enum.map(mods, &format_modification_item/1) |> Enum.join("\n")}
    """
  end

  defp format_breaking_item(item) when is_binary(item) do
    "- **Removed**: `#{item}` - Update your code to remove references"
  end

  defp format_breaking_item(%{property: prop, old_domain: old_d, new_domain: new_d}) do
    "- **Modified**: `#{prop}` domain changed from `#{old_d}` to `#{new_d}` - May affect existing data"
  end

  defp format_modification_item(%{property: prop, old_range: old_r, new_range: new_r}) do
    "- `#{prop}`: range updated from `#{old_r}` to `#{new_r}`"
  end

  defp format_modification_item(item) when is_binary(item), do: "- #{item}"

  defp generate_migration_notes([]), do: "No breaking changes - upgrade should be seamless."

  defp generate_migration_notes(breaking) do
    """
    This release contains breaking changes. Please review the following:

    #{Enum.map(breaking, &generate_migration_step/1) |> Enum.join("\n\n")}

    For detailed migration guide, see `docs/MIGRATION_#{Date.utc_today().year}.md`.
    """
  end

  defp generate_migration_step(item) when is_binary(item) do
    if String.starts_with?(item, "req:") do
      """
      **Removed `#{item}`**:
      - Search codebase for `#{item}` references
      - Update to use alternative property/class
      - Run tests to verify changes
      """
    else
      "- #{item}"
    end
  end

  defp generate_migration_step(%{property: prop}) do
    """
    **Modified `#{prop}`**:
    - Review usage in codebase
    - Update data structures if needed
    - Verify validation still passes
    """
  end

  defp parse_commit_line(line) do
    [hash, date, message] = String.split(line, "|", parts: 3)

    %{
      hash: hash,
      date: date,
      message: message
    }
  end

  defp generate_entry_from_commits(current, previous, ontology_path) do
    # Get file contents at each commit
    {current_content, 0} = System.cmd("git", ["show", "#{current.hash}:#{ontology_path}"])
    {previous_content, 0} = System.cmd("git", ["show", "#{previous.hash}:#{ontology_path}"])

    # Write temporary files for comparison
    File.write!("/tmp/current_ontology.ttl", current_content)
    File.write!("/tmp/previous_ontology.ttl", previous_content)

    # Calculate diff
    diff = Diff.compare("/tmp/current_ontology.ttl", "/tmp/previous_ontology.ttl")

    # Generate changelog entry
    version = extract_version_from_message(current.message)
    entry = generate_entry(diff, version, "previous")

    # Cleanup
    File.rm("/tmp/current_ontology.ttl")
    File.rm("/tmp/previous_ontology.ttl")

    entry
  end

  defp extract_version_from_message(message) do
    case Regex.run(~r/v?(\d+\.\d+\.\d+)/, message) do
      [_, version] -> version
      nil -> "unreleased"
    end
  end
end
