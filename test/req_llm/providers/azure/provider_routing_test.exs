defmodule ReqLLM.Providers.Azure.ProviderRoutingTest do
  @moduledoc """
  Provider routing, deployment URLs, and Azure endpoint format detection.
  """

  use ExUnit.Case, async: true

  import ReqLLM.Test.AzureModelHelpers, only: [traditional_openai_model: 0]

  alias ReqLLM.Providers.Azure

  describe "model lookup" do
    test "azure models are available from LLMDB" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")

      assert model.provider == :azure
      assert model.id == "gpt-4o"
    end

    test "provider is registered" do
      assert {:ok, Azure} = ReqLLM.provider(:azure)
    end
  end

  describe "base_url validation" do
    test "raises error for empty base_url" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")

      assert_raise ArgumentError, ~r/Azure requires a base_url/, fn ->
        Azure.prepare_request(
          :chat,
          model,
          "Hello",
          base_url: ""
        )
      end
    end

    test "accepts custom base_url" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")

      {:ok, request} =
        Azure.prepare_request(
          :chat,
          model,
          "Hello",
          base_url: "https://my-actual-resource.openai.azure.com/openai"
        )

      assert %Req.Request{} = request
    end
  end

  describe "Azure AI Foundry format detection" do
    test "detects Foundry format from .services.ai.azure.com domain" do
      assert Azure.uses_foundry_format?("https://my-resource.services.ai.azure.com")
      assert Azure.uses_foundry_format?("https://test.services.ai.azure.com/some/path")
      assert Azure.uses_foundry_format?("https://resource-name.services.ai.azure.com/")
    end

    test "does not detect Foundry format for traditional Azure OpenAI domains" do
      refute Azure.uses_foundry_format?("https://my-resource.openai.azure.com/openai")
      refute Azure.uses_foundry_format?("https://my-resource.cognitiveservices.azure.com")
      refute Azure.uses_foundry_format?("https://example.com")
    end

    test "handles edge cases safely" do
      refute Azure.uses_foundry_format?(nil)
      refute Azure.uses_foundry_format?("")
      refute Azure.uses_foundry_format?("not-a-url")
      refute Azure.uses_foundry_format?(12_345)
    end

    test "uses Foundry URL path for .services.ai.azure.com domain" do
      {:ok, model} = ReqLLM.model("azure:deepseek-v3.1")

      {:ok, request} =
        Azure.prepare_request(
          :chat,
          model,
          "Hello",
          deployment: "deepseek-v3",
          base_url: "https://my-resource.services.ai.azure.com",
          api_key: "test-key"
        )

      url_string = URI.to_string(request.url)
      assert url_string =~ "/models/chat/completions"
      refute url_string =~ "/deployments/"
    end

    test "uses traditional URL path for .openai.azure.com domain" do
      model = traditional_openai_model()

      {:ok, request} =
        Azure.prepare_request(
          :chat,
          model,
          "Hello",
          deployment: "my-deployment",
          base_url: "https://my-resource.openai.azure.com/openai",
          api_key: "test-key"
        )

      url_string = URI.to_string(request.url)
      assert url_string =~ "/deployments/my-deployment/chat/completions"
      refute url_string =~ "/models/chat/completions"
    end

    test "adds model to request body for Foundry format" do
      {:ok, model} = ReqLLM.model("azure:deepseek-v3.1")

      {:ok, request} =
        Azure.prepare_request(
          :chat,
          model,
          "Hello",
          deployment: "deepseek-v3-deployment",
          base_url: "https://my-resource.services.ai.azure.com",
          api_key: "test-key"
        )

      # Extract the JSON body from the request
      body = get_json_body(request)
      assert body["model"] == "deepseek-v3-deployment"
    end

    test "does not add model to request body for traditional format" do
      model = traditional_openai_model()

      {:ok, request} =
        Azure.prepare_request(
          :chat,
          model,
          "Hello",
          deployment: "my-deployment",
          base_url: "https://my-resource.openai.azure.com/openai",
          api_key: "test-key"
        )

      # Extract the JSON body from the request
      body = get_json_body(request)
      refute Map.has_key?(body, "model")
    end

    test "uses Foundry URL path for embeddings on .services.ai.azure.com domain" do
      model = ReqLLM.Test.AzureModelHelpers.embedding_model("text-embedding-3-small")

      {:ok, request} =
        Azure.prepare_request(
          :embedding,
          model,
          "Hello",
          deployment: "my-embedding-deployment",
          base_url: "https://my-resource.services.ai.azure.com",
          api_key: "test-key"
        )

      url_string = URI.to_string(request.url)
      assert url_string =~ "/models/embeddings"
      refute url_string =~ "/deployments/"
    end

    test "uses traditional URL path for embeddings on .openai.azure.com domain" do
      model = ReqLLM.Test.AzureModelHelpers.embedding_model("text-embedding-3-small")

      {:ok, request} =
        Azure.prepare_request(
          :embedding,
          model,
          "Hello",
          deployment: "my-embedding-deployment",
          base_url: "https://my-resource.openai.azure.com/openai",
          api_key: "test-key"
        )

      url_string = URI.to_string(request.url)
      assert url_string =~ "/deployments/my-embedding-deployment/embeddings"
      refute url_string =~ "/models/embeddings"
    end

    test "streaming uses Foundry URL path for .services.ai.azure.com domain" do
      {:ok, model} = ReqLLM.model("azure:deepseek-v3.1")
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      {:ok, finch_request} =
        Azure.attach_stream(
          model,
          context,
          [
            api_key: "test-api-key",
            deployment: "deepseek-v3-deployment",
            base_url: "https://my-resource.services.ai.azure.com"
          ],
          :req_llm_finch
        )

      url_string =
        case finch_request do
          %{path: path, query: query} when is_binary(query) and query != "" ->
            path <> "?" <> query

          %{path: path} ->
            path
        end

      assert url_string =~ "/models/chat/completions"
      refute url_string =~ "/deployments/"
    end

    test "streaming uses traditional URL path for .openai.azure.com domain" do
      model = traditional_openai_model()
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      {:ok, finch_request} =
        Azure.attach_stream(
          model,
          context,
          [
            api_key: "test-api-key",
            deployment: "my-deployment",
            base_url: "https://my-resource.openai.azure.com/openai"
          ],
          :req_llm_finch
        )

      url_string =
        case finch_request do
          %{path: path, query: query} when is_binary(query) and query != "" ->
            path <> "?" <> query

          %{path: path} ->
            path
        end

      assert url_string =~ "/deployments/my-deployment/chat/completions"
      refute url_string =~ "/models/chat/completions"
    end

    test "streaming adds model to request body for Foundry format" do
      {:ok, model} = ReqLLM.model("azure:deepseek-v3.1")
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      {:ok, finch_request} =
        Azure.attach_stream(
          model,
          context,
          [
            api_key: "test-api-key",
            deployment: "deepseek-v3-deployment",
            base_url: "https://my-resource.services.ai.azure.com"
          ],
          :req_llm_finch
        )

      # Decode the JSON body from the Finch request
      body = Jason.decode!(finch_request.body)
      assert body["model"] == "deepseek-v3-deployment"
    end

    test "Foundry endpoint uses Authorization Bearer header instead of api-key" do
      {:ok, model} = ReqLLM.model("azure:deepseek-v3.1")
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      request =
        Req.new(url: "/test", method: :post)
        |> Req.Request.register_options([:context, :api_key, :base_url])
        |> Req.Request.merge_options(context: context)
        |> Azure.attach(model,
          api_key: "test-api-key",
          context: context,
          base_url: "https://my-resource.services.ai.azure.com"
        )

      assert Req.Request.get_header(request, "authorization") == ["Bearer test-api-key"]
      assert Req.Request.get_header(request, "api-key") == []
    end

    test "traditional Azure endpoint uses api-key header" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      request =
        Req.new(url: "/test", method: :post)
        |> Req.Request.register_options([:context, :api_key, :base_url])
        |> Req.Request.merge_options(context: context)
        |> Azure.attach(model,
          api_key: "test-api-key",
          context: context,
          base_url: "https://my-resource.openai.azure.com/openai"
        )

      assert Req.Request.get_header(request, "api-key") == ["test-api-key"]
      assert Req.Request.get_header(request, "authorization") == []
    end

    test "streaming Foundry endpoint uses Authorization Bearer header" do
      {:ok, model} = ReqLLM.model("azure:deepseek-v3.1")
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      {:ok, finch_request} =
        Azure.attach_stream(
          model,
          context,
          [
            api_key: "test-api-key",
            deployment: "deepseek-v3-deployment",
            base_url: "https://my-resource.services.ai.azure.com"
          ],
          :req_llm_finch
        )

      header_map = Map.new(finch_request.headers)
      assert header_map["authorization"] == "Bearer test-api-key"
      refute Map.has_key?(header_map, "api-key")
    end

    test "Foundry endpoint defaults to 2024-05-01-preview API version" do
      {:ok, model} = ReqLLM.model("azure:deepseek-v3.1")

      {:ok, request} =
        Azure.prepare_request(
          :chat,
          model,
          "Hello",
          deployment: "deepseek-v3",
          base_url: "https://my-resource.services.ai.azure.com",
          api_key: "test-key"
        )

      url_string = URI.to_string(request.url)
      assert url_string =~ "api-version=2024-05-01-preview"
    end

    test "traditional Azure endpoint defaults to 2025-04-01-preview API version" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")

      {:ok, request} =
        Azure.prepare_request(
          :chat,
          model,
          "Hello",
          deployment: "my-deployment",
          base_url: "https://my-resource.openai.azure.com/openai",
          api_key: "test-key"
        )

      url_string = URI.to_string(request.url)
      assert url_string =~ "api-version=2025-04-01-preview"
    end

    test "explicit api_version overrides Foundry default" do
      {:ok, model} = ReqLLM.model("azure:deepseek-v3.1")

      {:ok, request} =
        Azure.prepare_request(
          :chat,
          model,
          "Hello",
          deployment: "deepseek-v3",
          base_url: "https://my-resource.services.ai.azure.com",
          api_key: "test-key",
          provider_options: [api_version: "2023-05-15"]
        )

      url_string = URI.to_string(request.url)
      assert url_string =~ "api-version=2023-05-15"
    end

    test "explicit api_version overrides traditional Azure default" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")

      {:ok, request} =
        Azure.prepare_request(
          :chat,
          model,
          "Hello",
          deployment: "my-deployment",
          base_url: "https://my-resource.openai.azure.com/openai",
          api_key: "test-key",
          provider_options: [api_version: "2023-05-15"]
        )

      url_string = URI.to_string(request.url)
      assert url_string =~ "api-version=2023-05-15"
    end
  end

  describe "Azure OpenAI v1 GA format detection" do
    test "detects v1 GA format from /openai/v1 path" do
      assert Azure.uses_v1_ga_format?("https://my-resource.openai.azure.com/openai/v1")
      assert Azure.uses_v1_ga_format?("https://my-resource.openai.azure.com/openai/v1/")

      assert Azure.uses_v1_ga_format?("https://my-resource.services.ai.azure.com/openai/v1")
    end

    test "does not detect v1 GA format for traditional /openai path" do
      refute Azure.uses_v1_ga_format?("https://my-resource.openai.azure.com/openai")
      refute Azure.uses_v1_ga_format?("https://my-resource.services.ai.azure.com")
      refute Azure.uses_v1_ga_format?("https://example.com")
    end

    test "handles edge cases safely" do
      refute Azure.uses_v1_ga_format?(nil)
      refute Azure.uses_v1_ga_format?("")
      refute Azure.uses_v1_ga_format?("not-a-url")
      refute Azure.uses_v1_ga_format?(12_345)
    end

    test "uses /chat/completions path with no api-version for v1 GA" do
      model = traditional_openai_model()

      {:ok, request} =
        Azure.prepare_request(
          :chat,
          model,
          "Hello",
          deployment: "gpt-4o",
          base_url: "https://my-resource.openai.azure.com/openai/v1",
          api_key: "test-key"
        )

      url_string = URI.to_string(request.url)
      assert url_string =~ "/chat/completions"
      refute url_string =~ "api-version="
      refute url_string =~ "/deployments/"
    end

    test "adds model to request body for v1 GA format" do
      model = traditional_openai_model()

      {:ok, request} =
        Azure.prepare_request(
          :chat,
          model,
          "Hello",
          deployment: "gpt-4o-deployment",
          base_url: "https://my-resource.openai.azure.com/openai/v1",
          api_key: "test-key"
        )

      body = get_json_body(request)
      assert body["model"] == "gpt-4o-deployment"
    end

    test "uses /embeddings path with no api-version for v1 GA" do
      model = ReqLLM.Test.AzureModelHelpers.embedding_model("text-embedding-3-small")

      {:ok, request} =
        Azure.prepare_request(
          :embedding,
          model,
          "Hello",
          deployment: "my-embedding-deployment",
          base_url: "https://my-resource.openai.azure.com/openai/v1",
          api_key: "test-key"
        )

      url_string = URI.to_string(request.url)
      assert url_string =~ "/embeddings"
      refute url_string =~ "api-version="
      refute url_string =~ "/deployments/"
    end

    test "streaming uses /chat/completions with no api-version for v1 GA" do
      model = traditional_openai_model()
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      {:ok, finch_request} =
        Azure.attach_stream(
          model,
          context,
          [
            api_key: "test-api-key",
            deployment: "gpt-4o-deployment",
            base_url: "https://my-resource.openai.azure.com/openai/v1"
          ],
          :req_llm_finch
        )

      url_string =
        case finch_request do
          %{path: path, query: query} when is_binary(query) and query != "" ->
            path <> "?" <> query

          %{path: path} ->
            path
        end

      assert url_string =~ "/chat/completions"
      refute url_string =~ "api-version="
      refute url_string =~ "/deployments/"
    end

    test "streaming handles trailing-slash base URL without producing //" do
      model = traditional_openai_model()
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      {:ok, finch_request} =
        Azure.attach_stream(
          model,
          context,
          [
            api_key: "test-api-key",
            deployment: "gpt-4o-deployment",
            # Trailing slash, as documented in the moduledoc usage example.
            base_url: "https://my-resource.openai.azure.com/openai/v1/"
          ],
          :req_llm_finch
        )

      path =
        case finch_request do
          %{path: p} -> p
        end

      refute path =~ "//", "expected single-slash path, got: #{inspect(path)}"
      assert path =~ "/openai/v1/chat/completions"
    end
  end

  describe "Kimi family routing" do
    import ExUnit.CaptureLog

    test "resolves Kimi family for lowercase model id from LLMDB" do
      {:ok, model} = ReqLLM.model("azure:kimi-k2.5")

      assert model.provider == :azure
      assert model.id == "kimi-k2.5"

      {:ok, _request} =
        Azure.prepare_request(
          :chat,
          model,
          "Hello",
          base_url: "https://my-resource.services.ai.azure.com/openai/v1",
          deployment: "kimi-k2.5"
        )
    end

    test "resolves Kimi family for uppercase Azure deployment id" do
      model = %LLMDB.Model{
        id: "Kimi-K2.6",
        provider: :azure,
        capabilities: %{chat: true},
        extra: %{}
      }

      {:ok, _request} =
        Azure.prepare_request(
          :chat,
          model,
          "Hello",
          api_key: "test-key",
          base_url: "https://my-resource.services.ai.azure.com/openai/v1",
          deployment: "Kimi-K2.6"
        )
    end

    test "format_request does not warn for Kimi models (lowercase)" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      log =
        capture_log(fn ->
          _body = Azure.OpenAI.format_request("kimi-k2.5", context, stream: false)
        end)

      refute log =~ "does not appear to be OpenAI-compatible"
    end

    test "format_request does not warn for Kimi models (uppercase)" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      log =
        capture_log(fn ->
          _body = Azure.OpenAI.format_request("Kimi-K2.6", context, stream: false)
        end)

      refute log =~ "does not appear to be OpenAI-compatible"
    end
  end

  describe "Mistral family routing" do
    import ExUnit.CaptureLog

    test "resolves Mistral family and routes through OpenAI formatter" do
      model = %LLMDB.Model{
        id: "mistral-large-2411",
        provider: :azure,
        capabilities: %{chat: true},
        extra: %{}
      }

      {:ok, _request} =
        Azure.prepare_request(
          :chat,
          model,
          "Hello",
          api_key: "test-key",
          base_url: "https://my-resource.services.ai.azure.com/openai/v1",
          deployment: "mistral-large-2411"
        )
    end

    test "translate_options delegates Mistral to OpenAI" do
      model = %LLMDB.Model{
        id: "mistral-large-2411",
        provider: :azure,
        capabilities: %{chat: true},
        extra: %{}
      }

      {translated, _warnings} = Azure.translate_options(:chat, model, temperature: 0.7)

      assert Keyword.get(translated, :temperature) == 0.7
    end

    test "format_request does not warn for Mistral models" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      log =
        capture_log(fn ->
          _body = Azure.OpenAI.format_request("mistral-large-2411", context, stream: false)
        end)

      refute log =~ "does not appear to be OpenAI-compatible"
    end

    test "uses default 30s timeout for Mistral models" do
      model = %LLMDB.Model{
        id: "mistral-large-2411",
        provider: :azure,
        capabilities: %{chat: true},
        extra: %{}
      }

      {:ok, request} =
        Azure.prepare_request(
          :chat,
          model,
          "Hello",
          api_key: "test-key",
          base_url: "https://my-resource.services.ai.azure.com/openai/v1",
          deployment: "mistral-large-2411"
        )

      assert request.options[:receive_timeout] == 30_000
    end
  end

  defp get_json_body(%Req.Request{} = request) do
    # Req stores JSON body in options[:json] before encoding
    request.options[:json] || %{}
  end
end
