defmodule ReqLLM.Release.LLMDBDependencyTest do
  use ExUnit.Case, async: false

  @moduletag timeout: 180_000

  @project_root Path.expand("../..", __DIR__)
  @fixture_path Path.join(@project_root, "test/fixtures/llm_db_release")
  @release_name "req_llm_llm_db_release_fixture"

  test "builds and boots with an embedded LLMDB catalog" do
    temporary_path =
      Path.join(
        System.tmp_dir!(),
        "req-llm-llm-db-release-#{System.unique_integer([:positive])}"
      )

    fixture_path = Path.join(temporary_path, "fixture")
    build_path = Path.join(fixture_path, "_build/prod")
    release_path = Path.join(temporary_path, "release")
    File.mkdir_p!(temporary_path)
    File.cp_r!(@fixture_path, fixture_path)
    on_exit(fn -> File.rm_rf!(temporary_path) end)

    environment = [
      {"HEX_OFFLINE", "1"},
      {"MIX_ENV", "prod"},
      {"MIX_DEPS_PATH", Path.join(@project_root, "deps")},
      {"REQ_LLM_PATH", @project_root}
    ]

    {build_output, build_status} =
      System.cmd(mix_executable(), ["release", "--path", release_path],
        cd: fixture_path,
        env: environment,
        stderr_to_stdout: true
      )

    assert build_status == 0, build_output

    assert_regular_llm_db_dependency(build_path)
    remove_packaged_catalog(release_path)
    assert_release_boots(release_path)
  end

  defp assert_regular_llm_db_dependency(build_path) do
    app_file = Path.join(build_path, "lib/req_llm/ebin/req_llm.app")

    assert {:ok, [{:application, :req_llm, properties}]} = :file.consult(app_file)
    assert :llm_db in Keyword.fetch!(properties, :applications)
    refute :llm_db in Keyword.get(properties, :included_applications, [])
  end

  defp remove_packaged_catalog(release_path) do
    snapshots =
      Path.wildcard(Path.join(release_path, "lib/llm_db-*/priv/llm_db/snapshot.json"))

    assert [snapshot] = snapshots
    File.rm!(snapshot)
  end

  defp assert_release_boots(release_path) do
    executable = Path.join([release_path, "bin", @release_name])

    expression =
      "{:ok, started} = Application.ensure_all_started(:req_llm_llm_db_release_fixture); " <>
        "true = Enum.member?(started, :llm_db); " <>
        "{:ok, model} = ReqLLM.model(\"openai:gpt-4o-mini\"); " <>
        "IO.puts(Atom.to_string(model.provider) <> \":\" <> model.id)"

    {output, status} =
      System.cmd(executable, ["eval", expression], stderr_to_stdout: true)

    assert status == 0, output
    assert output =~ "openai:gpt-4o-mini"
  end

  defp mix_executable do
    System.find_executable("mix") || raise "mix executable not found"
  end
end
