defmodule Mix.Tasks.ReqLlm.DoctorTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.ReqLlm.Doctor, as: DoctorTask

  setup do
    on_exit(fn -> Mix.Task.reenable("req_llm.doctor") end)
    :ok
  end

  test "prints concise human diagnostics and exits successfully when healthy" do
    output = capture_io(fn -> DoctorTask.run([]) end)

    assert output =~ "ReqLLM doctor:"
    assert output =~ "runtime.application"
    assert output =~ "finch.runtime"
    assert output =~ ~r/\d+ errors, \d+ warnings/
  end

  test "prints the stable machine-readable shape" do
    output = capture_io(fn -> DoctorTask.run(["--format", "json"]) end)
    result = Jason.decode!(output)

    assert result["schema_version"] == 1
    assert result["status"] in ["ok", "warning"]
    assert is_list(result["checks"])
  end

  test "supports model and operation inspection" do
    original_key = Application.get_env(:req_llm, :openai_api_key)
    Application.put_env(:req_llm, :openai_api_key, "doctor-task-test-key")

    on_exit(fn -> restore_app_env(:req_llm, :openai_api_key, original_key) end)

    output =
      capture_io(fn ->
        DoctorTask.run([
          "--model",
          "openai:gpt-4o-mini",
          "--operation",
          "chat",
          "--json"
        ])
      end)

    result = Jason.decode!(output)
    surface = Enum.find(result["checks"], &(&1["id"] == "model.surface"))

    assert surface["status"] == "ok"
  end

  test "prints diagnostics before returning a failing exit" do
    output =
      capture_io(fn ->
        assert_raise Mix.Error, ~r/diagnostics failed/, fn ->
          DoctorTask.run(["--provider", "not-a-provider", "--json"])
        end
      end)

    result = Jason.decode!(output)
    assert result["status"] == "error"
  end

  test "rejects invalid command options" do
    assert_raise Mix.Error, ~r/Invalid arguments/, fn ->
      DoctorTask.run(["--unknown"])
    end

    assert_raise Mix.Error, ~r/format must be human or json/, fn ->
      DoctorTask.run(["--format", "yaml"])
    end
  end

  defp restore_app_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_app_env(app, key, value), do: Application.put_env(app, key, value)
end
