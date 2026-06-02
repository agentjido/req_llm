defmodule ReqLLM.Test.Scenarios.ModalityTaxonomyTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.ReqLlm.ModelCompat
  alias ReqLLM.Test.Scenarios
  alias ReqLLM.Test.Scenarios.ModalityTaxonomy

  test "taxonomy ids are unique" do
    ids = ModalityTaxonomy.ids()

    assert ids == Enum.uniq(ids)
  end

  test "scenario registry groups are represented exactly" do
    assert ModalityTaxonomy.registry_groups() == Scenarios.groups()
  end

  test "model_compat capability groups stay aligned with taxonomy scenario ids" do
    for area <- ModalityTaxonomy.model_compat_areas() do
      expected = Enum.map(area.scenario_ids, &Atom.to_string/1)

      assert ModelCompat.capability_scenarios!(area.model_compat_capability) == expected
    end
  end

  test "focused route files exist and model_compat points at them" do
    for route <- ModalityTaxonomy.focused_routes(),
        scenario_id <- route.scenario_ids do
      scenario = Atom.to_string(scenario_id)

      assert File.exists?(route.test_file), "Expected coverage file at #{route.test_file}"

      assert ModelCompat.test_args_for(route.provider, route.operation, scenario) == [
               "test",
               route.test_file,
               "--only",
               "scenario:#{scenario}"
             ]
    end
  end

  test "documented concrete coverage files exist" do
    for path <- ModalityTaxonomy.concrete_test_files() do
      assert File.exists?(path), "Expected documented coverage file at #{path}"
    end
  end

  test "taxonomy distinguishes fixture-backed proof from planned gaps" do
    assert :ocr in ModalityTaxonomy.gap_ids()
    assert :vision_input in ModalityTaxonomy.gap_ids()
    assert :file_input in ModalityTaxonomy.gap_ids()
    assert :media_url_content in ModalityTaxonomy.gap_ids()
    assert :audio_output_chat in ModalityTaxonomy.gap_ids()

    assert :embedding in ModalityTaxonomy.fixture_backed_ids()
    assert :image in ModalityTaxonomy.fixture_backed_ids()
    assert :transcription in ModalityTaxonomy.fixture_backed_ids()
    assert :speech in ModalityTaxonomy.fixture_backed_ids()
    assert :rerank in ModalityTaxonomy.fixture_backed_ids()
  end
end
