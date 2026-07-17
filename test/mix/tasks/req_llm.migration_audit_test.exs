defmodule Mix.Tasks.ReqLlm.MigrationAuditTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.ReqLlm.MigrationAudit, as: MigrationAuditTask

  setup do
    directory =
      Path.join(System.tmp_dir!(), "req-llm-migration-task-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)

    on_exit(fn ->
      File.rm_rf!(directory)
      Mix.Task.reenable("req_llm.migration_audit")
    end)

    %{directory: directory}
  end

  test "prints a clean human report", %{directory: directory} do
    File.write!(Path.join(directory, "clean.ex"), "defmodule CleanTaskFixture do\nend\n")

    output = capture_io(fn -> MigrationAuditTask.run([directory]) end)

    assert output =~ "ReqLLM V2 migration audit: CLEAN"
    assert output =~ "1 files, 0 actionable, 0 advisory, 0 errors"
  end

  test "prints stable JSON before failing for actionable findings", %{directory: directory} do
    File.write!(
      Path.join(directory, "deprecated.ex"),
      "defmodule DeprecatedTaskFixture do\n  def run, do: ReqLLM.stream_text!(\"openai:gpt-4o\", \"hello\")\nend\n"
    )

    output =
      capture_io(fn ->
        assert catch_exit(MigrationAuditTask.run([directory, "--json"])) == {:shutdown, 1}
      end)

    report = Jason.decode!(output)

    assert report["schema_version"] == 1
    assert report["status"] == "findings"
    assert hd(report["findings"])["id"] == "req_llm.stream_text_bang"
  end

  test "exits successfully for unapproved deprecation advisories", %{directory: directory} do
    File.write!(
      Path.join(directory, "advisory.ex"),
      "defmodule AdvisoryTaskFixture do\n  def run, do: ReqLLM.Keys.fetch(:openai)\nend\n"
    )

    output = capture_io(fn -> MigrationAuditTask.run([directory, "--json"]) end)
    report = Jason.decode!(output)

    assert report["status"] == "advisory"
    assert report["summary"]["actionable"] == 0
    assert report["summary"]["advisory"] == 1
  end

  test "uses exit status 2 for audit errors", %{directory: directory} do
    missing = Path.join(directory, "missing")

    output =
      capture_io(fn ->
        assert catch_exit(MigrationAuditTask.run([missing, "--json"])) == {:shutdown, 2}
      end)

    report = Jason.decode!(output)
    assert report["status"] == "error"
    assert report["summary"]["errors"] == 1
  end

  test "supports repeated exclusions", %{directory: directory} do
    first = Path.join(directory, "first")
    second = Path.join(directory, "second")
    File.mkdir_p!(first)
    File.mkdir_p!(second)
    File.write!(Path.join(first, "one.ex"), "ReqLLM.Keys.fetch(:openai)\n")
    File.write!(Path.join(second, "two.ex"), "ReqLLM.Keys.fetch(:openai)\n")

    output =
      capture_io(fn ->
        MigrationAuditTask.run([
          directory,
          "--exclude",
          first,
          "--exclude",
          second,
          "--format",
          "json"
        ])
      end)

    report = Jason.decode!(output)
    assert report["status"] == "clean"
    assert report["summary"]["files_scanned"] == 0
  end

  test "rejects invalid command options" do
    assert_raise Mix.Error, ~r/Invalid arguments/, fn ->
      MigrationAuditTask.run(["--unknown"])
    end

    assert_raise Mix.Error, ~r/format must be human or json/, fn ->
      MigrationAuditTask.run(["--format", "yaml"])
    end
  end
end
