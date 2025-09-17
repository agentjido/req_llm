defmodule ReqLLM.GatewayDefaultsTest do
  use ExUnit.Case, async: true

  alias ReqLLM.{Context, Model}

  setup do
    # Preserve env
    old_url = System.get_env("RUNESTONE_URL")
    old_token = System.get_env("RUNESTONE_SERVICE_TOKEN")
    old_openai = Application.get_env(:req_llm, :openai_api_key)
    old_anthropic = Application.get_env(:req_llm, :anthropic_api_key)
    old_openrouter = Application.get_env(:req_llm, :openrouter_api_key)
    old_groq = Application.get_env(:req_llm, :groq_api_key)

    on_exit(fn ->
      if is_nil(old_url), do: System.delete_env("RUNESTONE_URL"), else: System.put_env("RUNESTONE_URL", old_url)
      if is_nil(old_token), do: System.delete_env("RUNESTONE_SERVICE_TOKEN"), else: System.put_env("RUNESTONE_SERVICE_TOKEN", old_token)
      Application.delete_env(:req_llm, :gateway_base_url)
      Application.delete_env(:req_llm, :gateway_service_token)

      if old_openai, do: Application.put_env(:req_llm, :openai_api_key, old_openai), else: Application.delete_env(:req_llm, :openai_api_key)
      if old_anthropic, do: Application.put_env(:req_llm, :anthropic_api_key, old_anthropic), else: Application.delete_env(:req_llm, :anthropic_api_key)
      if old_openrouter, do: Application.put_env(:req_llm, :openrouter_api_key, old_openrouter), else: Application.delete_env(:req_llm, :openrouter_api_key)
      if old_groq, do: Application.put_env(:req_llm, :groq_api_key, old_groq), else: Application.delete_env(:req_llm, :groq_api_key)
    end)

    :ok
  end

  describe "OpenAI provider" do
    test "attaches gateway base_url and service token by default when configured" do
      # Configure gateway via env
      System.put_env("RUNESTONE_URL", "https://gateway.local/v1")
      System.put_env("RUNESTONE_SERVICE_TOKEN", "test-token")

      # Stub API key lookup for OpenAI
      Application.put_env(:req_llm, :openai_api_key, "sk-test")

      model = Model.from!("openai:gpt-4o-mini")
      ctx = Context.new([Context.user("hello")])

      {:ok, req} = ReqLLM.Providers.OpenAI.prepare_request(:chat, model, ctx, [])

      # Assert base_url defaulted to gateway URL
      assert req.options[:base_url] == "https://gateway.local/v1"

      # Assert service token header present
      headers = Map.new(req.headers)
      assert headers["x-service-token"] == ["test-token"]
    end

    test "explicit base_url overrides gateway default" do
      System.put_env("RUNESTONE_URL", "https://gateway.local/v1")
      Application.put_env(:req_llm, :openai_api_key, "sk-test")

      model = Model.from!("openai:gpt-4o-mini")
      ctx = Context.new([Context.user("hello")])

      {:ok, req} = ReqLLM.Providers.OpenAI.prepare_request(:chat, model, ctx, [base_url: "https://custom.api/v1"])

      assert req.options[:base_url] == "https://custom.api/v1"
    end

    test "falls back to provider default when no gateway configured" do
      System.delete_env("RUNESTONE_URL")
      Application.delete_env(:req_llm, :gateway_base_url)
      Application.put_env(:req_llm, :openai_api_key, "sk-test")

      model = Model.from!("openai:gpt-4o-mini")
      ctx = Context.new([Context.user("hello")])

      {:ok, req} = ReqLLM.Providers.OpenAI.prepare_request(:chat, model, ctx, [])

      assert req.options[:base_url] == "https://api.openai.com/v1"
    end
  end

  describe "Anthropic provider" do
    test "attaches gateway base_url and service token when configured" do
      System.put_env("RUNESTONE_URL", "https://gateway.local/v1")
      System.put_env("RUNESTONE_SERVICE_TOKEN", "test-token")
      Application.put_env(:req_llm, :anthropic_api_key, "sk-ant-test")

      model = Model.from!("anthropic:claude-3-haiku-20240307")
      ctx = Context.new([Context.user("hello")])

      {:ok, req} = ReqLLM.Providers.Anthropic.prepare_request(:chat, model, ctx, [])

      assert req.options[:base_url] == "https://gateway.local/v1"
      headers = Map.new(req.headers)
      assert headers["x-service-token"] == ["test-token"]
    end

    test "explicit base_url overrides gateway default" do
      System.put_env("RUNESTONE_URL", "https://gateway.local/v1")
      Application.put_env(:req_llm, :anthropic_api_key, "sk-ant-test")

      model = Model.from!("anthropic:claude-3-haiku-20240307")
      ctx = Context.new([Context.user("hello")])

      {:ok, req} = ReqLLM.Providers.Anthropic.prepare_request(:chat, model, ctx, [base_url: "https://custom.api/v1"])

      assert req.options[:base_url] == "https://custom.api/v1"
    end

    test "falls back to provider default when no gateway configured" do
      System.delete_env("RUNESTONE_URL")
      Application.delete_env(:req_llm, :gateway_base_url)
      Application.put_env(:req_llm, :anthropic_api_key, "sk-ant-test")

      model = Model.from!("anthropic:claude-3-haiku-20240307")
      ctx = Context.new([Context.user("hello")])

      {:ok, req} = ReqLLM.Providers.Anthropic.prepare_request(:chat, model, ctx, [])

      assert req.options[:base_url] == "https://api.anthropic.com/v1"
    end
  end

  describe "OpenRouter provider" do
    test "attaches gateway base_url and service token when configured" do
      System.put_env("RUNESTONE_URL", "https://gateway.local/v1")
      System.put_env("RUNESTONE_SERVICE_TOKEN", "test-token")
      Application.put_env(:req_llm, :openrouter_api_key, "sk-or-test")

      model = Model.from!("openrouter:anthropic/claude-3-haiku")
      ctx = Context.new([Context.user("hello")])

      {:ok, req} = ReqLLM.Providers.OpenRouter.prepare_request(:chat, model, ctx, [])

      assert req.options[:base_url] == "https://gateway.local/v1"
      headers = Map.new(req.headers)
      assert headers["x-service-token"] == ["test-token"]
    end

    test "explicit base_url overrides gateway default" do
      System.put_env("RUNESTONE_URL", "https://gateway.local/v1")
      Application.put_env(:req_llm, :openrouter_api_key, "sk-or-test")

      model = Model.from!("openrouter:anthropic/claude-3-haiku")
      ctx = Context.new([Context.user("hello")])

      {:ok, req} = ReqLLM.Providers.OpenRouter.prepare_request(:chat, model, ctx, [base_url: "https://custom.api/v1"])

      assert req.options[:base_url] == "https://custom.api/v1"
    end

    test "falls back to provider default when no gateway configured" do
      System.delete_env("RUNESTONE_URL")
      Application.delete_env(:req_llm, :gateway_base_url)
      Application.put_env(:req_llm, :openrouter_api_key, "sk-or-test")

      model = Model.from!("openrouter:anthropic/claude-3-haiku")
      ctx = Context.new([Context.user("hello")])

      {:ok, req} = ReqLLM.Providers.OpenRouter.prepare_request(:chat, model, ctx, [])

      assert req.options[:base_url] == "https://openrouter.ai/api/v1"
    end
  end

  describe "Groq provider" do
    test "attaches gateway base_url and service token when configured" do
      System.put_env("RUNESTONE_URL", "https://gateway.local/v1")
      System.put_env("RUNESTONE_SERVICE_TOKEN", "test-token")
      Application.put_env(:req_llm, :groq_api_key, "gsk-test")

      model = Model.from!("groq:llama3-8b-8192")
      ctx = Context.new([Context.user("hello")])

      {:ok, req} = ReqLLM.Providers.Groq.prepare_request(:chat, model, ctx, [])

      assert req.options[:base_url] == "https://gateway.local/v1"
      headers = Map.new(req.headers)
      assert headers["x-service-token"] == ["test-token"]
    end

    test "explicit base_url overrides gateway default" do
      System.put_env("RUNESTONE_URL", "https://gateway.local/v1")
      Application.put_env(:req_llm, :groq_api_key, "gsk-test")

      model = Model.from!("groq:llama3-8b-8192")
      ctx = Context.new([Context.user("hello")])

      {:ok, req} = ReqLLM.Providers.Groq.prepare_request(:chat, model, ctx, [base_url: "https://custom.api/v1"])

      assert req.options[:base_url] == "https://custom.api/v1"
    end

    test "falls back to provider default when no gateway configured" do
      System.delete_env("RUNESTONE_URL")
      Application.delete_env(:req_llm, :gateway_base_url)
      Application.put_env(:req_llm, :groq_api_key, "gsk-test")

      model = Model.from!("groq:llama3-8b-8192")
      ctx = Context.new([Context.user("hello")])

      {:ok, req} = ReqLLM.Providers.Groq.prepare_request(:chat, model, ctx, [])

      assert req.options[:base_url] == "https://api.groq.com/openai/v1"
    end
  end

  describe "gateway configuration via Application env" do
    test "Application.put_env takes precedence over System env" do
      System.put_env("RUNESTONE_URL", "https://system.gateway/v1")
      System.put_env("RUNESTONE_SERVICE_TOKEN", "system-token")

      Application.put_env(:req_llm, :gateway_base_url, "https://app.gateway/v1")
      Application.put_env(:req_llm, :gateway_service_token, "app-token")
      Application.put_env(:req_llm, :openai_api_key, "sk-test")

      model = Model.from!("openai:gpt-4o-mini")
      ctx = Context.new([Context.user("hello")])

      {:ok, req} = ReqLLM.Providers.OpenAI.prepare_request(:chat, model, ctx, [])

      assert req.options[:base_url] == "https://app.gateway/v1"
      headers = Map.new(req.headers)
      assert headers["x-service-token"] == ["app-token"]
    end
  end
end

