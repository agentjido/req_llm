defmodule ReqLLM.AvailabilityTest do
  use ExUnit.Case, async: false

  @env_vars [
    "ANTHROPIC_API_KEY",
    "AWS_ACCESS_KEY_ID",
    "AWS_BEARER_TOKEN_BEDROCK",
    "AWS_SECRET_ACCESS_KEY",
    "AZURE_API_KEY",
    "AZURE_BASE_URL",
    "AZURE_OPENAI_API_KEY",
    "AZURE_OPENAI_BASE_URL",
    "CEREBRAS_API_KEY",
    "DEEPSEEK_API_KEY",
    "DASHSCOPE_API_KEY",
    "ELEVENLABS_API_KEY",
    "GOOGLE_API_KEY",
    "GOOGLE_APPLICATION_CREDENTIALS",
    "GOOGLE_CLOUD_PROJECT",
    "GROQ_API_KEY",
    "OPENROUTER_API_KEY",
    "OPENAI_API_KEY",
    "VENICE_API_KEY",
    "XAI_API_KEY",
    "ZAI_API_KEY",
    "ZENMUX_API_KEY"
  ]

  @app_keys [
    :anthropic_api_key,
    :azure_api_key,
    :cerebras_api_key,
    :deepseek_api_key,
    :elevenlabs_api_key,
    :google_api_key,
    :groq_api_key,
    :openai_api_key,
    :openrouter_api_key,
    :venice_api_key,
    :xai_api_key,
    :zai_api_key,
    :zenmux_api_key
  ]

  setup do
    env_snapshot = Map.new(@env_vars, &{&1, System.get_env(&1)})
    app_snapshot = Map.new(@app_keys, &{&1, Application.get_env(:req_llm, &1)})
    azure_snapshot = Application.get_env(:req_llm, :azure)

    Enum.each(@env_vars, &System.delete_env/1)
    Enum.each(@app_keys, &Application.delete_env(:req_llm, &1))
    Application.delete_env(:req_llm, :azure)

    on_exit(fn ->
      Enum.each(env_snapshot, fn
        {var, nil} -> System.delete_env(var)
        {var, value} -> System.put_env(var, value)
      end)

      Enum.each(app_snapshot, fn
        {key, nil} -> Application.delete_env(:req_llm, key)
        {key, value} -> Application.put_env(:req_llm, key, value)
      end)

      restore_application_env(:azure, azure_snapshot)
    end)

    :ok
  end

  describe "available_models/1" do
    test "returns models only for configured providers" do
      System.put_env("OPENAI_API_KEY", "openai-test-key")
      System.put_env("ANTHROPIC_API_KEY", "anthropic-test-key")

      models = ReqLLM.available_models()

      assert "openai:gpt-4o" in models
      assert "anthropic:claude-3-haiku-20240307" in models
      refute Enum.any?(models, &String.starts_with?(&1, "groq:"))
    end

    test "forwards capability filters to model selection" do
      System.put_env("OPENAI_API_KEY", "openai-test-key")

      models = ReqLLM.available_models(scope: :openai, require: [embeddings: true])

      assert "openai:text-embedding-3-small" in models
      refute "openai:gpt-4o" in models
    end

    test "accepts oauth provider options for scoped discovery" do
      models =
        ReqLLM.available_models(
          scope: :openai,
          provider_options: [auth_mode: :oauth, access_token: "oauth-access-token"]
        )

      assert "openai:gpt-4o" in models
    end

    test "requires project configuration for google vertex discovery" do
      System.put_env("GOOGLE_APPLICATION_CREDENTIALS", "/tmp/service-account.json")

      assert ReqLLM.available_models(scope: :google_vertex) == []

      System.put_env("GOOGLE_CLOUD_PROJECT", "test-project")

      models = ReqLLM.available_models(scope: :google_vertex)

      assert Enum.any?(models, &String.starts_with?(&1, "google_vertex:"))
    end

    test "detects Bedrock bearer token credentials" do
      System.put_env("AWS_BEARER_TOKEN_BEDROCK", "bedrock-token")

      models = ReqLLM.available_models(scope: :amazon_bedrock)

      assert Enum.any?(models, &String.starts_with?(&1, "amazon_bedrock:"))
    end

    test "requires both azure key and base url" do
      System.put_env("AZURE_OPENAI_API_KEY", "azure-test-key")

      assert ReqLLM.available_models(scope: :azure) == []

      System.put_env("AZURE_OPENAI_BASE_URL", "https://example.openai.azure.com")

      models = ReqLLM.available_models(scope: :azure)

      assert Enum.any?(models, &String.starts_with?(&1, "azure:"))
    end
  end

  defp restore_application_env(key, nil), do: Application.delete_env(:req_llm, key)
  defp restore_application_env(key, value), do: Application.put_env(:req_llm, key, value)
end
