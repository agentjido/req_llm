# test/ontology_gitvan_test.exs
# Purpose: Test gitvan (deterministic versioning) functionality

defmodule ReqLLM.OntologyGitvanTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Ontology.{Diff, Changelog, Migration}

  @test_ontology_v1 """
  @prefix req: <https://schema.reqllm.dev#> .
  @prefix rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#> .
  @prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .

  req:Response a rdfs:Class .
  req:Context a rdfs:Class .
  req:Message a rdfs:Class .

  req:hasContext a rdf:Property ; rdfs:domain req:Response ; rdfs:range req:Context .
  req:hasMessage a rdf:Property ; rdfs:domain req:Context ; rdfs:range req:Message .
  req:role a rdf:Property ; rdfs:domain req:Message ; rdfs:range xsd:string .
  """

  @test_ontology_v2_additions """
  @prefix req: <https://schema.reqllm.dev#> .
  @prefix rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#> .
  @prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .

  req:Response a rdfs:Class .
  req:Context a rdfs:Class .
  req:Message a rdfs:Class .
  req:Usage a rdfs:Class .

  req:hasContext a rdf:Property ; rdfs:domain req:Response ; rdfs:range req:Context .
  req:hasMessage a rdf:Property ; rdfs:domain req:Context ; rdfs:range req:Message .
  req:role a rdf:Property ; rdfs:domain req:Message ; rdfs:range xsd:string .
  req:hasUsage a rdf:Property ; rdfs:domain req:Response ; rdfs:range req:Usage .
  """

  @test_ontology_v3_breaking """
  @prefix req: <https://schema.reqllm.dev#> .
  @prefix rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#> .
  @prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .

  req:Response a rdfs:Class .
  req:Context a rdfs:Class .
  req:Usage a rdfs:Class .

  req:hasContext a rdf:Property ; rdfs:domain req:Response ; rdfs:range req:Context .
  req:hasUsage a rdf:Property ; rdfs:domain req:Response ; rdfs:range req:Usage .
  """

  setup do
    # Create test ontology files
    File.write!("/tmp/test_ontology_v1.ttl", @test_ontology_v1)
    File.write!("/tmp/test_ontology_v2_additions.ttl", @test_ontology_v2_additions)
    File.write!("/tmp/test_ontology_v3_breaking.ttl", @test_ontology_v3_breaking)

    on_exit(fn ->
      File.rm("/tmp/test_ontology_v1.ttl")
      File.rm("/tmp/test_ontology_v2_additions.ttl")
      File.rm("/tmp/test_ontology_v3_breaking.ttl")
    end)

    :ok
  end

  describe "Diff.parse_ontology/1" do
    test "parses classes from TTL file" do
      ontology = Diff.parse_ontology("/tmp/test_ontology_v1.ttl")

      assert MapSet.member?(ontology.classes, "req:Response")
      assert MapSet.member?(ontology.classes, "req:Context")
      assert MapSet.member?(ontology.classes, "req:Message")
      assert MapSet.size(ontology.classes) == 3
    end

    test "parses properties from TTL file" do
      ontology = Diff.parse_ontology("/tmp/test_ontology_v1.ttl")

      assert MapSet.member?(ontology.properties, "req:hasContext")
      assert MapSet.member?(ontology.properties, "req:hasMessage")
      assert MapSet.member?(ontology.properties, "req:role")
      assert MapSet.size(ontology.properties) == 3
    end
  end

  describe "Diff.compare/2" do
    test "detects added classes" do
      diff = Diff.compare("/tmp/test_ontology_v2_additions.ttl", "/tmp/test_ontology_v1.ttl")

      assert "req:Usage" in diff.added_classes
      assert length(diff.added_classes) == 1
    end

    test "detects added properties" do
      diff = Diff.compare("/tmp/test_ontology_v2_additions.ttl", "/tmp/test_ontology_v1.ttl")

      assert "req:hasUsage" in diff.added_properties
      assert length(diff.added_properties) == 1
    end

    test "detects removed classes" do
      diff = Diff.compare("/tmp/test_ontology_v3_breaking.ttl", "/tmp/test_ontology_v1.ttl")

      assert "req:Message" in diff.removed_classes
      assert length(diff.removed_classes) == 1
    end

    test "detects removed properties" do
      diff = Diff.compare("/tmp/test_ontology_v3_breaking.ttl", "/tmp/test_ontology_v1.ttl")

      assert "req:hasMessage" in diff.removed_properties
      assert "req:role" in diff.removed_properties
      assert length(diff.removed_properties) == 2
    end

    test "handles no changes" do
      diff = Diff.compare("/tmp/test_ontology_v1.ttl", "/tmp/test_ontology_v1.ttl")

      assert diff.added_classes == []
      assert diff.removed_classes == []
      assert diff.added_properties == []
      assert diff.removed_properties == []
    end
  end

  describe "Diff.categorize/1" do
    test "categorizes additions as non-breaking" do
      diff = Diff.compare("/tmp/test_ontology_v2_additions.ttl", "/tmp/test_ontology_v1.ttl")
      categorized = Diff.categorize(diff)

      assert "req:Usage" in categorized.additions
      assert "req:hasUsage" in categorized.additions
      assert length(categorized.breaking) == 0
    end

    test "categorizes removals as breaking" do
      diff = Diff.compare("/tmp/test_ontology_v3_breaking.ttl", "/tmp/test_ontology_v1.ttl")
      categorized = Diff.categorize(diff)

      assert "req:Message" in categorized.breaking
      assert "req:hasMessage" in categorized.breaking
      assert "req:role" in categorized.breaking
      assert length(categorized.breaking) == 3
    end
  end

  describe "Diff.suggest_version_bump/1" do
    test "suggests major for breaking changes" do
      diff = Diff.compare("/tmp/test_ontology_v3_breaking.ttl", "/tmp/test_ontology_v1.ttl")
      categorized = Diff.categorize(diff)

      assert Diff.suggest_version_bump(categorized) == :major
    end

    test "suggests minor for additions" do
      diff = Diff.compare("/tmp/test_ontology_v2_additions.ttl", "/tmp/test_ontology_v1.ttl")
      categorized = Diff.categorize(diff)

      assert Diff.suggest_version_bump(categorized) == :minor
    end

    test "suggests patch for no changes" do
      diff = Diff.compare("/tmp/test_ontology_v1.ttl", "/tmp/test_ontology_v1.ttl")
      categorized = Diff.categorize(diff)

      assert Diff.suggest_version_bump(categorized) == :patch
    end
  end

  describe "Diff.summarize/1" do
    test "produces human-readable summary" do
      diff = Diff.compare("/tmp/test_ontology_v2_additions.ttl", "/tmp/test_ontology_v1.ttl")
      summary = Diff.summarize(diff)

      assert is_binary(summary)
      assert summary =~ "Ontology Changes Summary"
      assert summary =~ "Breaking Changes (0)"
      assert summary =~ "Additions (2)"
      assert summary =~ "MINOR"
    end

    test "includes breaking changes in summary" do
      diff = Diff.compare("/tmp/test_ontology_v3_breaking.ttl", "/tmp/test_ontology_v1.ttl")
      summary = Diff.summarize(diff)

      assert summary =~ "Breaking Changes (3)"
      assert summary =~ "MAJOR"
    end
  end

  describe "Diff.calculate_hash/1" do
    test "calculates consistent hash for same file" do
      hash1 = Diff.calculate_hash("/tmp/test_ontology_v1.ttl")
      hash2 = Diff.calculate_hash("/tmp/test_ontology_v1.ttl")

      assert hash1 == hash2
      assert String.length(hash1) == 12
    end

    test "calculates different hash for different files" do
      hash1 = Diff.calculate_hash("/tmp/test_ontology_v1.ttl")
      hash2 = Diff.calculate_hash("/tmp/test_ontology_v2_additions.ttl")

      assert hash1 != hash2
    end
  end

  describe "Changelog.generate_entry/3" do
    test "generates changelog entry for additions" do
      diff = Diff.compare("/tmp/test_ontology_v2_additions.ttl", "/tmp/test_ontology_v1.ttl")
      entry = Changelog.generate_entry(diff, "0.2.0", "0.1.0")

      assert is_binary(entry)
      assert entry =~ "## [0.2.0]"
      assert entry =~ "Added"
      assert entry =~ "req:Usage"
      assert entry =~ "req:hasUsage"
      assert entry =~ "Previous Version"
    end

    test "generates changelog entry for breaking changes" do
      diff = Diff.compare("/tmp/test_ontology_v3_breaking.ttl", "/tmp/test_ontology_v1.ttl")
      entry = Changelog.generate_entry(diff, "2.0.0", "1.0.0")

      assert entry =~ "## [2.0.0]"
      assert entry =~ "BREAKING CHANGES"
      assert entry =~ "Migration Guide"
      assert entry =~ "req:Message"
    end

    test "includes ontology hash in entry" do
      diff = Diff.compare("/tmp/test_ontology_v2_additions.ttl", "/tmp/test_ontology_v1.ttl")
      entry = Changelog.generate_entry(diff, "0.2.0", "0.1.0")

      assert entry =~ "**Ontology Hash**:"
    end
  end

  describe "Migration.generate_guide/3" do
    test "generates guide for non-breaking update" do
      diff = Diff.compare("/tmp/test_ontology_v2_additions.ttl", "/tmp/test_ontology_v1.ttl")
      guide = Migration.generate_guide(diff, "0.2.0", "0.1.0")

      assert is_binary(guide)
      assert guide =~ "Migration Guide: 0.1.0 → 0.2.0"
      assert guide =~ "Non-Breaking Update"
      assert guide =~ "No migration steps required"
    end

    test "generates guide for breaking update" do
      diff = Diff.compare("/tmp/test_ontology_v3_breaking.ttl", "/tmp/test_ontology_v1.ttl")
      guide = Migration.generate_guide(diff, "2.0.0", "1.0.0")

      assert guide =~ "Migration Guide: 1.0.0 → 2.0.0"
      assert guide =~ "Breaking Update"
      assert guide =~ "WARNING"
      assert guide =~ "Breaking Changes"
      assert guide =~ "Validation"
      assert guide =~ "Rollback"
    end

    test "assesses migration difficulty" do
      diff = Diff.compare("/tmp/test_ontology_v3_breaking.ttl", "/tmp/test_ontology_v1.ttl")
      guide = Migration.generate_guide(diff, "2.0.0", "1.0.0")

      assert guide =~ "**Difficulty**:"
    end

    test "includes migration steps for removed properties" do
      diff = Diff.compare("/tmp/test_ontology_v3_breaking.ttl", "/tmp/test_ontology_v1.ttl")
      guide = Migration.generate_guide(diff, "2.0.0", "1.0.0")

      assert guide =~ "req:hasMessage"
      assert guide =~ "req:role"
      assert guide =~ "Search Pattern"
      assert guide =~ "Migration Steps"
    end
  end

  describe "Migration.generate_data_migration/1" do
    test "generates data migration script" do
      diff = Diff.compare("/tmp/test_ontology_v3_breaking.ttl", "/tmp/test_ontology_v1.ttl")
      script = Migration.generate_data_migration(diff)

      assert is_binary(script)
      assert script =~ "defmodule ReqLLM.Migrations.Data"
      assert script =~ "def migrate_response"
      assert script =~ "def migrate_context"
      assert script =~ "def migrate_message"
    end
  end
end
