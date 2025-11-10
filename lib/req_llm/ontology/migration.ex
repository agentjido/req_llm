# lib/req_llm/ontology/migration.ex
# Purpose: Generate migration guides from ontology diffs (gitvan phase)

defmodule ReqLLM.Ontology.Migration do
  @moduledoc """
  Generates detailed migration guides from Σ ontology changes.

  Creates step-by-step migration instructions for breaking changes,
  including code examples and deprecation warnings.

  ## Usage

  ```elixir
  # Generate migration guide
  guide = Migration.generate_guide(diff, "0.2.0", "0.1.0")

  # Save to file
  Migration.save_guide(guide, "docs/MIGRATION_2025.md")
  ```
  """

  alias ReqLLM.Ontology.Diff

  @doc """
  Generate complete migration guide from diff.

  Returns Markdown-formatted migration guide with code examples.
  """
  def generate_guide(diff, new_version, old_version) do
    categorized = Diff.categorize(diff)
    date = Date.utc_today() |> Date.to_iso8601()

    if length(categorized.breaking) == 0 do
      """
      # Migration Guide: #{old_version} → #{new_version}

      **Date**: #{date}
      **Type**: Non-Breaking Update

      ## Summary

      This update contains only additions and non-breaking modifications.
      No migration steps required - upgrade should be seamless.

      #{format_new_features(categorized.additions)}
      """
    else
      """
      # Migration Guide: #{old_version} → #{new_version}

      **Date**: #{date}
      **Type**: Breaking Update
      **Difficulty**: #{assess_difficulty(categorized.breaking)}

      ⚠️ **WARNING**: This update contains breaking changes that require code modifications.

      ## Quick Start

      1. Review breaking changes below
      2. Search codebase for affected references
      3. Apply migration steps
      4. Run tests
      5. Update ontology version hash in CI

      ## Breaking Changes

      #{format_breaking_changes_detailed(categorized.breaking)}

      ## New Features

      #{format_new_features(categorized.additions)}

      ## Validation

      After migration, verify:

      ```bash
      # Run tests
      mix test

      # Validate against new SHACL constraints
      bash script/validate_shacl.sh

      # Update Σ_HASH in GitHub secrets
      # New hash: #{Diff.calculate_hash("ontologies/reqllm.sigma_observed.ttl")}
      ```

      ## Rollback

      If issues arise, rollback to #{old_version}:

      ```bash
      git checkout v#{old_version} -- ontologies/
      mix deps.get
      mix test
      ```

      ## Support

      - Issues: https://github.com/your-org/req_llm/issues
      - Discussions: https://github.com/your-org/req_llm/discussions
      """
    end
  end

  @doc """
  Save migration guide to file.
  """
  def save_guide(guide, path) do
    # Ensure directory exists
    Path.dirname(path) |> File.mkdir_p!()

    File.write!(path, guide)
  end

  @doc """
  Generate deprecation warnings for code.

  Returns Elixir code with deprecation warnings for removed elements.
  """
  def generate_deprecation_warnings(removed_properties) do
    removed_properties
    |> Enum.map(&generate_deprecation_for_property/1)
    |> Enum.join("\n\n")
  end

  @doc """
  Generate data migration script.

  Creates Elixir script to migrate data from old structure to new.
  """
  def generate_data_migration(diff) do
    categorized = Diff.categorize(diff)

    """
    # Data Migration Script
    # Auto-generated from ontology diff

    defmodule ReqLLM.Migrations.Data do
      @moduledoc \"\"\"
      Migrates data structures from old ontology to new.
      \"\"\"

      #{generate_property_migrations(categorized.breaking)}

      def migrate_response(old_response) do
        old_response
        #{generate_migration_pipeline(categorized.breaking)}
      end

      def migrate_context(old_context) do
        old_context
        # Add migration steps for Context changes
      end

      def migrate_message(old_message) do
        old_message
        # Add migration steps for Message changes
      end
    end
    """
  end

  # -- Private Helpers --

  defp assess_difficulty(breaking_changes) do
    count = length(breaking_changes)

    cond do
      count == 0 -> "None"
      count <= 2 -> "Low"
      count <= 5 -> "Medium"
      true -> "High"
    end
  end

  defp format_breaking_changes_detailed([]), do: "(none)"

  defp format_breaking_changes_detailed(breaking) do
    breaking
    |> Enum.with_index(1)
    |> Enum.map(fn {change, index} ->
      format_breaking_change_with_migration(change, index)
    end)
    |> Enum.join("\n\n")
  end

  defp format_breaking_change_with_migration(item, index) when is_binary(item) do
    if String.starts_with?(item, "req:") do
      # Removed property or class
      name = String.replace(item, "req:", "")

      """
      ### #{index}. Removed `#{item}`

      **Impact**: Any code referencing `#{item}` will fail validation.

      **Search Pattern**:
      ```bash
      git grep -i "#{name}" lib/ test/
      ```

      **Migration Steps**:

      1. Find all references to `#{item}`:
         ```bash
         rg "#{name}" lib/
         ```

      2. Remove or replace with alternative:
         ```elixir
         # Before:
         response.#{String.downcase(name)}

         # After:
         # (remove reference or use alternative property)
         ```

      3. Update tests:
         ```elixir
         # Remove assertions checking for #{item}
         ```

      **Verification**:
      ```bash
      mix test
      ```
      """
    else
      """
      ### #{index}. Breaking Change

      #{item}

      **Action Required**: Review and update affected code.
      """
    end
  end

  defp format_breaking_change_with_migration(%{property: prop} = change, index) do
    """
    ### #{index}. Modified `#{prop}`

    **Change**: Domain/range modified
    - Old domain: #{change.old_domain || "any"}
    - New domain: #{change.new_domain || "any"}
    - Old range: #{change.old_range || "any"}
    - New range: #{change.new_range || "any"}

    **Impact**: Data validation may fail if values don't match new constraints.

    **Migration Steps**:

    1. Review usage of `#{prop}`:
       ```bash
       git grep -i "#{String.replace(prop, "req:", "")}"
       ```

    2. Update code to match new domain/range:
       ```elixir
       # Ensure values conform to new constraints
       # Run validator: Validator.validate_response(response)
       ```

    3. Update test fixtures:
       ```elixir
       # Update test data to match new schema
       ```

    **Verification**:
    ```bash
    mix test test/ontology_validation_test.exs
    ```
    """
  end

  defp format_new_features([]), do: "(none)"

  defp format_new_features(additions) do
    """
    #{Enum.map(additions, &format_addition/1) |> Enum.join("\n\n")}

    These are non-breaking additions. You can start using them immediately.
    """
  end

  defp format_addition(item) do
    """
    - **`#{item}`**: New property/class available
      - Update emitters to include if needed
      - Update parsers to handle if needed
      - See SHACL constraints for validation rules
    """
  end

  defp generate_deprecation_for_property(prop) do
    """
    @deprecated "#{prop} has been removed from the ontology. See migration guide."
    def #{String.replace(prop, "req:", "") |> Macro.underscore()}(_) do
      IO.warn("#{prop} is deprecated and will be removed")
      nil
    end
    """
  end

  defp generate_property_migrations([]), do: "# No property migrations needed"

  defp generate_property_migrations(breaking) do
    breaking
    |> Enum.filter(&is_binary/1)
    |> Enum.filter(&String.starts_with?(&1, "req:"))
    |> Enum.map(&generate_property_migration/1)
    |> Enum.join("\n\n")
  end

  defp generate_property_migration(prop) do
    field_name = String.replace(prop, "req:", "") |> Macro.underscore()

    """
    # Migration for removed property: #{prop}
    defp remove_#{field_name}(data) do
      Map.delete(data, :#{field_name})
      |> Map.delete("#{field_name}")
    end
    """
  end

  defp generate_migration_pipeline([]), do: ""

  defp generate_migration_pipeline(breaking) do
    breaking
    |> Enum.filter(&is_binary/1)
    |> Enum.filter(&String.starts_with?(&1, "req:"))
    |> Enum.map(fn prop ->
      field_name = String.replace(prop, "req:", "") |> Macro.underscore()
      "|> remove_#{field_name}()"
    end)
    |> Enum.join("\n        ")
  end
end
