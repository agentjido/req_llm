defmodule ReqLLM.Providers.GoogleVertex.ConfigTest do
  use ExUnit.Case, async: false

  alias ReqLLM.Context
  alias ReqLLM.Providers.GoogleVertex

  @env_vars [
    "GOOGLE_APPLICATION_CREDENTIALS",
    "GOOGLE_CLOUD_PROJECT",
    "GOOGLE_CLOUD_REGION"
  ]

  setup do
    env_snapshot = Map.new(@env_vars, &{&1, System.get_env(&1)})
    app_config = Application.get_env(:req_llm, :google_vertex)

    Enum.each(@env_vars, &System.delete_env/1)
    Application.delete_env(:req_llm, :google_vertex)

    on_exit(fn ->
      Enum.each(env_snapshot, fn
        {var, nil} -> System.delete_env(var)
        {var, value} -> System.put_env(var, value)
      end)

      restore_application_env(app_config)
    end)

    :ok
  end

  describe "application config credentials" do
    test "uses keyword config for chat request credentials" do
      Application.put_env(:req_llm, :google_vertex,
        service_account_json: "/tmp/config-service-account.json",
        project_id: "config-project",
        region: "us-central1"
      )

      {:ok, model} = ReqLLM.model("google_vertex:gemini-2.5-pro")
      {:ok, request} = GoogleVertex.prepare_request(:chat, model, context_fixture(), [])

      url = URI.to_string(request.url)
      creds = Req.Request.get_private(request, :gcp_credentials)

      assert url =~ "us-central1-aiplatform.googleapis.com"
      assert url =~ "projects/config-project"
      assert creds[:service_account_json] == "/tmp/config-service-account.json"
    end

    test "uses map config for streaming access token credentials" do
      Application.put_env(:req_llm, :google_vertex, %{
        "access_token" => "config-token",
        "project_id" => "map-project",
        "region" => "europe-west4"
      })

      {:ok, model} = ReqLLM.model("google_vertex:zai-org/glm-4.7-maas")
      {:ok, finch_request} = GoogleVertex.attach_stream(model, context_fixture(), [], nil)

      assert finch_request.path =~ "projects/map-project"
      assert finch_request.path =~ "locations/europe-west4"
      assert authorization_header(finch_request) == "Bearer config-token"
    end

    test "request options override application config" do
      Application.put_env(:req_llm, :google_vertex,
        access_token: "config-token",
        project_id: "config-project",
        region: "global"
      )

      {:ok, model} = ReqLLM.model("google_vertex:gemini-2.5-pro")

      opts = [
        access_token: "request-token",
        project_id: "request-project",
        region: "us-central1"
      ]

      {:ok, request} = GoogleVertex.prepare_request(:chat, model, context_fixture(), opts)

      url = URI.to_string(request.url)
      creds = Req.Request.get_private(request, :gcp_credentials)

      assert url =~ "us-central1-aiplatform.googleapis.com"
      assert url =~ "projects/request-project"
      assert creds[:access_token] == "request-token"
    end

    test "application config overrides environment credentials" do
      System.put_env("GOOGLE_APPLICATION_CREDENTIALS", "/tmp/env-service-account.json")
      System.put_env("GOOGLE_CLOUD_PROJECT", "env-project")
      System.put_env("GOOGLE_CLOUD_REGION", "asia-northeast1")

      Application.put_env(:req_llm, :google_vertex,
        service_account_json: "/tmp/config-service-account.json",
        project_id: "config-project",
        region: "us-central1"
      )

      {:ok, model} = ReqLLM.model("google_vertex:gemini-2.5-pro")
      {:ok, request} = GoogleVertex.prepare_request(:chat, model, context_fixture(), [])

      url = URI.to_string(request.url)
      creds = Req.Request.get_private(request, :gcp_credentials)

      assert url =~ "us-central1-aiplatform.googleapis.com"
      assert url =~ "projects/config-project"
      assert creds[:service_account_json] == "/tmp/config-service-account.json"
    end
  end

  defp context_fixture do
    Context.new([Context.user("Hello")])
  end

  defp authorization_header(%Finch.Request{headers: headers}) do
    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(key) == "authorization", do: value
    end)
  end

  defp restore_application_env(nil), do: Application.delete_env(:req_llm, :google_vertex)
  defp restore_application_env(value), do: Application.put_env(:req_llm, :google_vertex, value)
end
