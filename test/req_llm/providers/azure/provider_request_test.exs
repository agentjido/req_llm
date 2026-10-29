defmodule ReqLLM.Providers.Azure.ProviderRequestTest do
  @moduledoc """
  Provider request preparation, embedding validation, and encoding delegation.
  """

  use ExUnit.Case, async: true

  import ReqLLM.Test.AzureModelHelpers, only: [traditional_openai_model: 0]

  alias ReqLLM.Providers.Azure

  describe "prepare_request/4" do
    import ExUnit.CaptureLog

    test "constructs URL with deployment from options" do
      model = traditional_openai_model()

      {:ok, request} =
        Azure.prepare_request(
          :chat,
          model,
          "Hello",
          deployment: "my-gpt4-deployment",
          base_url: "https://my-resource.openai.azure.com/openai"
        )

      url_string = URI.to_string(request.url)
      assert url_string =~ "/deployments/my-gpt4-deployment/chat/completions"
      assert url_string =~ "api-version="
    end

    test "uses model.id as default deployment when not specified" do
      model = traditional_openai_model()

      {:ok, request} =
        Azure.prepare_request(
          :chat,
          model,
          "Hello",
          base_url: "https://my-resource.openai.azure.com/openai"
        )

      url_string = URI.to_string(request.url)
      assert url_string =~ "/deployments/gpt-4o/chat/completions"
    end

    test "uses custom api_version from provider_options" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")

      {:ok, request} =
        Azure.prepare_request(
          :chat,
          model,
          "Hello",
          base_url: "https://my-resource.openai.azure.com/openai",
          provider_options: [api_version: "2023-05-15"]
        )

      url_string = URI.to_string(request.url)
      assert url_string =~ "api-version=2023-05-15"
    end

    test "passes logprobs options to Azure Chat Completions" do
      {{:ok, request}, log} =
        with_log(fn -> prepare_chat_with_logprobs(traditional_openai_model()) end)

      refute log =~ "logprobs will be ignored"
      assert request.options[:json][:logprobs] == true
      assert request.options[:json][:top_logprobs] == 3
    end

    test "warns and ignores logprobs options on Responses API requests" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")
      {{:ok, request}, log} = with_log(fn -> prepare_chat_with_logprobs(model) end)

      assert log =~ "openai_logprobs"
      assert log =~ "Chat Completions"
      assert log =~ "logprobs will be ignored"

      for key <- [:logprobs, "logprobs", :top_logprobs, "top_logprobs"] do
        refute Map.has_key?(request.options[:json], key)
      end

      assert URI.to_string(request.url) =~ "/responses"
    end

    test "preserves custom finch from req_http_options" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")

      {:ok, request} =
        Azure.prepare_request(
          :chat,
          model,
          "Hello",
          base_url: "https://my-resource.openai.azure.com/openai",
          req_http_options: [finch: :custom_finch]
        )

      assert request.options[:finch] == [name: :custom_finch]
    end

    test "embedding operation uses correct endpoint" do
      model = ReqLLM.Test.AzureModelHelpers.embedding_model("text-embedding-3-small")

      {:ok, request} =
        Azure.prepare_request(
          :embedding,
          model,
          "Hello",
          deployment: "my-embedding-deployment",
          base_url: "https://my-resource.openai.azure.com/openai"
        )

      url_string = URI.to_string(request.url)
      assert url_string =~ "/deployments/my-embedding-deployment/embeddings"
      assert url_string =~ "api-version="
    end

    test "embedding operation rejects non-embedding models" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")

      assert {:error, %ReqLLM.Error.Invalid.Parameter{}} =
               Azure.prepare_request(
                 :embedding,
                 model,
                 "Hello",
                 deployment: "my-deployment",
                 base_url: "https://my-resource.openai.azure.com/openai"
               )
    end

    test "embedding operation returns an error tuple for invalid options" do
      model = ReqLLM.Test.AzureModelHelpers.embedding_model("text-embedding-3-small")

      assert {:error, error} =
               Azure.prepare_request(
                 :embedding,
                 model,
                 "Hello",
                 deployment: "my-embedding-deployment",
                 base_url: "https://my-resource.openai.azure.com/openai",
                 provider_options: [dimensions: "not-an-integer"]
               )

      assert Exception.message(error) =~ "dimensions"
    end
  end

  describe "encode_body/1" do
    test "is pass-through since formatters handle encoding" do
      request = %Req.Request{body: {:json, %{"key" => "value"}}}

      assert Azure.encode_body(request) == request
    end
  end

  defp prepare_chat_with_logprobs(model) do
    Azure.prepare_request(
      :chat,
      model,
      "Hello",
      base_url: "https://my-resource.openai.azure.com/openai",
      provider_options: [openai_logprobs: true, openai_top_logprobs: 3]
    )
  end
end
