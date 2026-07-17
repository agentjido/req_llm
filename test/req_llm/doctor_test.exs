defmodule ReqLLM.DoctorTest do
  use ExUnit.Case, async: false

  alias ReqLLM.Doctor

  setup do
    original_finch = Application.get_env(:req_llm, :finch)
    original_llm_db_load_dotenv = Application.get_env(:llm_db, :load_dotenv)
    original_oauth_file = Application.get_env(:req_llm, :oauth_file)
    original_auth_file = Application.get_env(:req_llm, :auth_file)
    original_openai_key = Application.get_env(:req_llm, :openai_api_key)
    original_openai_env = System.get_env("OPENAI_API_KEY")
    original_xai_key = Application.get_env(:req_llm, :xai_api_key)
    original_xai_env = System.get_env("XAI_API_KEY")

    on_exit(fn ->
      restore_app_env(:req_llm, :finch, original_finch)
      restore_app_env(:llm_db, :load_dotenv, original_llm_db_load_dotenv)
      restore_app_env(:req_llm, :oauth_file, original_oauth_file)
      restore_app_env(:req_llm, :auth_file, original_auth_file)
      restore_app_env(:req_llm, :openai_api_key, original_openai_key)
      restore_app_env(:req_llm, :xai_api_key, original_xai_key)
      restore_system_env("OPENAI_API_KEY", original_openai_env)
      restore_system_env("XAI_API_KEY", original_xai_env)
      Application.ensure_all_started(:req_llm)
      ReqLLM.Providers.initialize()
    end)

    :ok
  end

  test "returns a stable JSON-safe result with runtime versions" do
    result = Doctor.run()

    assert result["schema_version"] == 1
    assert result["status"] in ["ok", "warning"]
    assert Doctor.exit_status(result) == 0

    assert Enum.all?(result["checks"], fn check ->
             Map.keys(check) |> Enum.sort() ==
               ~w(details id layer message remediation status)
           end)

    versions = find_check(result, "runtime.versions")
    assert versions["status"] == "ok"
    assert versions["details"]["req_llm"] == to_string(Application.spec(:req_llm, :vsn))
    assert versions["details"]["elixir"] == System.version()
    assert versions["details"]["otp"] == System.otp_release()
    assert Jason.encode!(result)
  end

  test "does not start ReqLLM or mutate runtime configuration by default" do
    Application.delete_env(:llm_db, :load_dotenv)
    assert :ok = Application.stop(:req_llm)

    result = Doctor.run()

    refute Enum.any?(Application.started_applications(), fn {app, _description, _version} ->
             app == :req_llm
           end)

    assert Application.get_env(:llm_db, :load_dotenv) == nil
    assert find_check(result, "runtime.application")["status"] == "warning"
    assert find_check(result, "providers.registry")["status"] == "warning"
    assert find_check(result, "finch.runtime")["status"] == "warning"
    assert Doctor.exit_status(result) == 0
  end

  test "treats absent optional credentials as a warning with a successful exit" do
    retain_only_provider(:xai)
    delete_xai_credentials()

    result = Doctor.run()
    check = find_check(result, "credentials.configuration")

    assert result["status"] == "warning"
    assert check["status"] == "warning"
    assert check["details"]["configured_providers"] == []
    assert Doctor.exit_status(result) == 0
  end

  test "reports missing selected-provider credentials as a required error" do
    delete_xai_credentials()

    result = Doctor.run(provider: :xai)
    check = find_check(result, "credentials.selected_provider")

    assert result["status"] == "error"
    assert check["layer"] == "credentials"
    assert check["status"] == "error"
    assert check["remediation"] =~ "XAI_API_KEY"
    assert Doctor.exit_status(result) == 1
  end

  test "does not mistake invalid required credential configuration for presence" do
    System.delete_env("XAI_API_KEY")
    Application.put_env(:req_llm, :xai_api_key, 123)

    result = Doctor.run(provider: :xai)

    assert find_check(result, "credentials.selected_provider")["status"] == "error"
    assert result["status"] == "error"
  end

  test "never includes credential values in human or machine output" do
    secret = "doctor-secret-value-that-must-not-leak"
    Application.put_env(:req_llm, :xai_api_key, secret)
    System.put_env("XAI_API_KEY", secret)

    result = Doctor.run(provider: :xai)
    encoded = Jason.encode!(result)
    human = Doctor.format_human(result)

    assert find_check(result, "credentials.selected_provider")["status"] == "ok"
    refute encoded =~ secret
    refute human =~ secret
  end

  test "inspects OAuth credential presence without refreshes or file changes" do
    path =
      Path.join(
        System.tmp_dir!(),
        "req-llm-doctor-oauth-#{System.unique_integer([:positive])}.json"
      )

    body =
      Jason.encode!(%{
        "openai-codex" => %{
          "access" => "expired-doctor-access-secret",
          "refresh" => "doctor-refresh-secret",
          "expires" => 0
        }
      })

    File.write!(path, body)
    Application.put_env(:req_llm, :oauth_file, path)
    on_exit(fn -> File.rm(path) end)

    result = Doctor.run(provider: :openai_codex)

    Application.delete_env(:req_llm, :openai_api_key)
    System.delete_env("OPENAI_API_KEY")
    default_openai_result = Doctor.run(provider: :openai)

    assert find_check(result, "credentials.selected_provider")["status"] == "ok"
    assert find_check(default_openai_result, "credentials.selected_provider")["status"] == "error"
    assert File.read!(path) == body
    refute Jason.encode!(result) =~ "doctor-refresh-secret"
    refute Jason.encode!(result) =~ path
  end

  test "locates invalid models and missing providers without echoing inputs" do
    invalid_model = "unknown:doctor-sensitive-model-fragment"
    model_result = Doctor.run(model: invalid_model)
    provider_result = Doctor.run(provider: "doctor-provider-that-does-not-exist")

    assert find_check(model_result, "model.resolution")["status"] == "error"
    assert find_check(model_result, "model.resolution")["remediation"]
    refute Jason.encode!(model_result) =~ invalid_model

    assert find_check(provider_result, "providers.registry")["status"] == "error"
    assert find_check(provider_result, "providers.registry")["layer"] == "provider"
    refute Jason.encode!(provider_result) =~ "doctor-provider-that-does-not-exist"
  end

  test "reports the selected request surface without making a request" do
    Application.put_env(:req_llm, :xai_api_key, "doctor-test-key")
    Application.put_env(:req_llm, :openai_api_key, "doctor-test-key")

    result = Doctor.run(model: "openai:gpt-4o-mini", operation: :chat)
    check = find_check(result, "model.surface")

    assert check["status"] == "ok"
    assert check["details"]["surface"] in ["openai_chat_completions", "openai_responses"]
    assert check["details"]["transport"] == "req"
  end

  test "validates Finch pool configuration and only exposes safe fields" do
    Application.put_env(:req_llm, :finch,
      name: ReqLLM.Finch,
      pools: %{
        default: [
          protocols: [:http1],
          size: 2,
          count: 3,
          conn_opts: [proxy_headers: [{"authorization", "doctor-secret"}]]
        ]
      }
    )

    valid = Doctor.run()
    check = find_check(valid, "finch.configuration")

    assert check["status"] == "ok"

    assert check["details"]["pools"] == [
             %{"name" => "default", "protocols" => ["http1"], "size" => 2, "count" => 3}
           ]

    refute Jason.encode!(valid) =~ "doctor-secret"

    Application.put_env(:req_llm, :finch,
      name: ReqLLM.Finch,
      pools: %{default: [protocols: [:http3], size: 0, count: 0]}
    )

    invalid = Doctor.run()
    invalid_check = find_check(invalid, "finch.configuration")

    assert invalid_check["status"] == "error"
    assert invalid_check["layer"] == "finch"
    assert invalid_check["remediation"]
  end

  test "rejects invalid doctor options as configuration errors" do
    result = Doctor.run(operation: :embed)

    assert result["status"] == "error"
    assert find_check(result, "input")["layer"] == "configuration"
    assert Doctor.exit_status(result) == 1
  end

  defp find_check(result, id), do: Enum.find(result["checks"], &(&1["id"] == id))

  defp retain_only_provider(provider) do
    ReqLLM.Providers.list()
    |> Enum.reject(&(&1 == provider))
    |> Enum.each(&ReqLLM.Providers.unregister/1)
  end

  defp delete_xai_credentials do
    Application.delete_env(:req_llm, :xai_api_key)
    System.delete_env("XAI_API_KEY")
  end

  defp restore_app_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_app_env(app, key, value), do: Application.put_env(app, key, value)

  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)
end
