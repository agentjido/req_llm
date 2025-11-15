defmodule ReqLLM.BaseURLStreamingTest do
  use ExUnit.Case, async: false

  alias ReqLLM.Context

  setup do
    ReqLLM.TestSupport.FakeKeys.install!()

    # Save original config and restore after each test
    original_env = Application.get_all_env(:req_llm)

    on_exit(fn ->
      Application.put_all_env([{:req_llm, original_env}])
    end)

    :ok
  end

  describe "OpenAI ChatAPI base_url precedence" do
    setup do
      {:ok, model} = ReqLLM.model("openai:gpt-4o-mini")
      context = Context.new([Context.user("test")])
      {:ok, model: model, context: context}
    end

    test "opts[:base_url] takes precedence over app config", %{model: model, context: context} do
      Application.put_env(:req_llm, :openai, base_url: "https://config.example.com")

      opts = [api_key: "test-openai", base_url: "https://opts.example.com"]

      {:ok, finch_request} =
        ReqLLM.Providers.OpenAI.ChatAPI.attach_stream(model, context, opts, nil)

      assert finch_request.scheme == :https
      assert finch_request.host == "opts.example.com"
      assert finch_request.path == "/chat/completions"
    end

    test "app config is used when opts[:base_url] not provided", %{
      model: model,
      context: context
    } do
      Application.put_env(:req_llm, :openai, base_url: "https://config.example.com")

      opts = [api_key: "test-openai"]

      {:ok, finch_request} =
        ReqLLM.Providers.OpenAI.ChatAPI.attach_stream(model, context, opts, nil)

      assert finch_request.scheme == :https
      assert finch_request.host == "config.example.com"
      assert finch_request.path == "/chat/completions"
    end

    test "fallback to provider default when neither opts nor app config set", %{
      model: model,
      context: context
    } do
      Application.delete_env(:req_llm, :openai)

      opts = [api_key: "[REDACTED:api-key]"]

      {:ok, finch_request} =
        ReqLLM.Providers.OpenAI.ChatAPI.attach_stream(model, context, opts, nil)

      assert finch_request.scheme == :https
      assert finch_request.host == "api.openai.com"
      assert finch_request.path == "/v1/chat/completions"
    end
  end

  describe "Anthropic base_url precedence" do
    setup do
      {:ok, model} = ReqLLM.model("anthropic:claude-3-haiku")
      context = Context.new([Context.user("test")])
      {:ok, model: model, context: context}
    end

    test "opts[:base_url] takes precedence over app config", %{model: model, context: context} do
      Application.put_env(:req_llm, :anthropic, base_url: "https://config.example.com")

      opts = [api_key: "[REDACTED:api-key]", base_url: "https://opts.example.com"]

      {:ok, finch_request} =
        ReqLLM.Providers.Anthropic.attach_stream(model, context, opts, nil)

      assert finch_request.scheme == :https
      assert finch_request.host == "opts.example.com"
      assert finch_request.path == "/v1/messages"
    end

    test "app config is used when opts[:base_url] not provided", %{
      model: model,
      context: context
    } do
      Application.put_env(:req_llm, :anthropic, base_url: "https://config.example.com")

      opts = [api_key: "[REDACTED:api-key]"]

      {:ok, finch_request} =
        ReqLLM.Providers.Anthropic.attach_stream(model, context, opts, nil)

      assert finch_request.scheme == :https
      assert finch_request.host == "config.example.com"
      assert finch_request.path == "/v1/messages"
    end

    test "fallback to provider default when neither opts nor app config set", %{
      model: model,
      context: context
    } do
      Application.delete_env(:req_llm, :anthropic)

      opts = [api_key: "[REDACTED:api-key]"]

      {:ok, finch_request} =
        ReqLLM.Providers.Anthropic.attach_stream(model, context, opts, nil)

      assert finch_request.scheme == :https
      assert finch_request.host == "api.anthropic.com"
      assert finch_request.path == "/v1/messages"
    end
  end

  describe "OpenRouter base_url precedence" do
    setup do
      {:ok, model} = ReqLLM.model("openrouter:anthropic/claude-3-haiku")

      context = Context.new([Context.user("test")])
      {:ok, model: model, context: context}
    end

    test "opts[:base_url] takes precedence over app config", %{model: model, context: context} do
      Application.put_env(:req_llm, :openrouter, base_url: "https://config.example.com")

      opts = [api_key: "[REDACTED:api-key]", base_url: "https://opts.example.com"]

      {:ok, finch_request} =
        ReqLLM.Providers.OpenRouter.attach_stream(model, context, opts, nil)

      assert finch_request.scheme == :https
      assert finch_request.host == "opts.example.com"
      assert finch_request.path == "/chat/completions"
    end

    test "app config is used when opts[:base_url] not provided", %{
      model: model,
      context: context
    } do
      Application.put_env(:req_llm, :openrouter, base_url: "https://config.example.com")

      opts = [api_key: "[REDACTED:api-key]"]

      {:ok, finch_request} =
        ReqLLM.Providers.OpenRouter.attach_stream(model, context, opts, nil)

      assert finch_request.scheme == :https
      assert finch_request.host == "config.example.com"
      assert finch_request.path == "/chat/completions"
    end

    test "fallback to provider default when neither opts nor app config set", %{
      model: model,
      context: context
    } do
      Application.delete_env(:req_llm, :openrouter)

      opts = [api_key: "[REDACTED:api-key]"]

      {:ok, finch_request} =
        ReqLLM.Providers.OpenRouter.attach_stream(model, context, opts, nil)

      assert finch_request.scheme == :https
      assert finch_request.host == "openrouter.ai"
      assert finch_request.path == "/api/v1/chat/completions"
    end
  end

  describe "Google base_url precedence" do
    setup do
      {:ok, model} = ReqLLM.model("google:gemini-2.0-flash-exp")
      context = Context.new([Context.user("test")])
      {:ok, model: model, context: context}
    end

    test "opts[:base_url] takes precedence over app config", %{model: model, context: context} do
      Application.put_env(:req_llm, :google, base_url: "https://config.example.com")

      opts = [api_key: "[REDACTED:api-key]", base_url: "https://opts.example.com"]

      {:ok, finch_request} = ReqLLM.Providers.Google.attach_stream(model, context, opts, nil)

      assert finch_request.scheme == :https
      assert finch_request.host == "opts.example.com"
      assert finch_request.path =~ ~r/^\/models\/gemini-2.0-flash-exp:streamGenerateContent/
    end

    test "app config is used when opts[:base_url] not provided", %{
      model: model,
      context: context
    } do
      Application.put_env(:req_llm, :google, base_url: "https://config.example.com")

      opts = [api_key: "[REDACTED:api-key]"]

      {:ok, finch_request} = ReqLLM.Providers.Google.attach_stream(model, context, opts, nil)

      assert finch_request.scheme == :https
      assert finch_request.host == "config.example.com"
      assert finch_request.path =~ ~r/^\/models\/gemini-2.0-flash-exp:streamGenerateContent/
    end

    test "fallback to v1beta default when neither opts nor app config set", %{
      model: model,
      context: context
    } do
      Application.delete_env(:req_llm, :google)

      opts = [api_key: "[REDACTED:api-key]"]

      {:ok, finch_request} = ReqLLM.Providers.Google.attach_stream(model, context, opts, nil)

      assert finch_request.scheme == :https
      assert finch_request.host == "generativelanguage.googleapis.com"

      assert finch_request.path =~
               ~r/^\/v1beta\/models\/gemini-2.0-flash-exp:streamGenerateContent/
    end

    test "v1beta selected when grounding is enabled without explicit version", %{
      model: model,
      context: context
    } do
      Application.delete_env(:req_llm, :google)

      opts = [
        api_key: "[REDACTED:api-key]",
        provider_options: [google_grounding: %{enable: true}]
      ]

      {:ok, finch_request} = ReqLLM.Providers.Google.attach_stream(model, context, opts, nil)

      assert finch_request.scheme == :https
      assert finch_request.host == "generativelanguage.googleapis.com"

      assert finch_request.path =~
               ~r/^\/v1beta\/models\/gemini-2.0-flash-exp:streamGenerateContent/
    end

    test "v1beta selected when explicitly set in provider_options", %{
      model: model,
      context: context
    } do
      Application.delete_env(:req_llm, :google)

      opts = [api_key: "[REDACTED:api-key]", provider_options: [google_api_version: "v1beta"]]

      {:ok, finch_request} = ReqLLM.Providers.Google.attach_stream(model, context, opts, nil)

      assert finch_request.scheme == :https
      assert finch_request.host == "generativelanguage.googleapis.com"

      assert finch_request.path =~
               ~r/^\/v1beta\/models\/gemini-2.0-flash-exp:streamGenerateContent/
    end

    test "opts[:base_url] overrides v1beta selection from grounding", %{
      model: model,
      context: context
    } do
      Application.delete_env(:req_llm, :google)

      opts = [
        api_key: "[REDACTED:api-key]",
        base_url: "https://custom.example.com/v1",
        provider_options: [google_grounding: %{enable: true}]
      ]

      {:ok, finch_request} = ReqLLM.Providers.Google.attach_stream(model, context, opts, nil)

      assert finch_request.scheme == :https
      assert finch_request.host == "custom.example.com"
      assert finch_request.path =~ ~r/^\/v1\/models\/gemini-2.0-flash-exp:streamGenerateContent/
    end
  end

  describe "edge cases and validation" do
    test "handles base_url with trailing slash correctly for OpenAI" do
      {:ok, model} = ReqLLM.model("openai:gpt-4o-mini")
      context = Context.new([Context.user("test")])
      opts = [api_key: "[REDACTED:api-key]", base_url: "https://example.com"]

      {:ok, finch_request} =
        ReqLLM.Providers.OpenAI.ChatAPI.attach_stream(model, context, opts, nil)

      assert finch_request.host == "example.com"
      assert finch_request.path == "/chat/completions"
    end

    test "handles base_url without scheme for Anthropic" do
      {:ok, model} = ReqLLM.model("anthropic:claude-3-haiku")
      context = Context.new([Context.user("test")])
      opts = [api_key: "[REDACTED:api-key]", base_url: "http://example.com"]

      {:ok, finch_request} =
        ReqLLM.Providers.Anthropic.attach_stream(model, context, opts, nil)

      assert finch_request.scheme == :http
      assert finch_request.host == "example.com"
    end

    test "constructed request includes proper headers and body" do
      {:ok, model} = ReqLLM.model("openai:gpt-4o-mini")
      context = Context.new([Context.user("hello")])
      opts = [api_key: "[REDACTED:api-key]", base_url: "https://custom.example.com"]

      {:ok, finch_request} =
        ReqLLM.Providers.OpenAI.ChatAPI.attach_stream(model, context, opts, nil)

      assert finch_request.method == "POST"
      headers = finch_request.headers
      header_names = Enum.map(headers, fn {k, _v} -> String.downcase(k) end)
      assert "accept" in header_names
      assert "content-type" in header_names
      assert "authorization" in header_names

      {_, accept_value} = Enum.find(headers, fn {k, _v} -> String.downcase(k) == "accept" end)
      assert accept_value == "text/event-stream"

      assert is_binary(finch_request.body)
      assert {:ok, body_map} = Jason.decode(finch_request.body)
      assert body_map["stream"] == true
      assert body_map["model"] == "gpt-4o-mini"
    end
  end
end
