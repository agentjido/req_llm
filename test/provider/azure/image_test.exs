defmodule ReqLLM.Providers.Azure.ImageTest do
  @moduledoc """
  Unit tests for Azure image generation and editing request construction.

  Tests Azure-specific behaviors:
  - Endpoint path construction across traditional / v1 GA / Foundry formats
  - Generation body encoding (no model/response_format leakage)
  - Multipart edit requests (no JSON content-type, model part handling)
  - Response decoding via the OpenAI ImagesAPI codec

  Does NOT test live API calls - see test/coverage/azure/ for integration tests.
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias ReqLLM.Providers.Azure

  @traditional_base_url "https://my-resource.openai.azure.com/openai"
  @v1_ga_base_url "https://my-resource.openai.azure.com/openai/v1"
  @foundry_base_url "https://my-resource.services.ai.azure.com"

  @png_bytes <<137, 80, 78, 71, 13, 10, 26, 10>>

  defp prepare!(opts) do
    {:ok, request} =
      Azure.prepare_request(
        :image,
        "azure:gpt-image-1",
        Keyword.get(opts, :prompt, "A simple red square"),
        Keyword.merge(
          [api_key: "test-api-key", deployment: "my-image-deploy"],
          Keyword.delete(opts, :prompt)
        )
      )

    request
  end

  describe "image generation (traditional format)" do
    test "constructs deployment-based URL with api-version" do
      request = prepare!(base_url: @traditional_base_url)

      assert URI.to_string(request.url) ==
               "/deployments/my-image-deploy/images/generations?api-version=2025-04-01-preview"
    end

    test "body contains prompt and n but no model or response_format" do
      request = prepare!(base_url: @traditional_base_url)

      body = request.options[:json]
      assert body["prompt"] == "A simple red square"
      assert body["n"] == 1
      refute Map.has_key?(body, "model")
      refute Map.has_key?(body, "response_format")
    end

    test "sets operation, JSON content-type, api-key header, and image timeout" do
      request = prepare!(base_url: @traditional_base_url)

      assert request.options[:operation] == :image
      assert Req.Request.get_header(request, "content-type") == ["application/json"]
      assert Req.Request.get_header(request, "api-key") == ["test-api-key"]
      assert request.options[:receive_timeout] == 120_000
    end

    test "passes size, quality, and user options into the body" do
      request =
        prepare!(
          base_url: @traditional_base_url,
          size: {1024, 1536},
          quality: "high",
          user: "test-user"
        )

      body = request.options[:json]
      assert body["size"] == "1024x1536"
      assert body["quality"] == "high"
      assert body["user"] == "test-user"
    end

    test "respects custom api_version from provider_options" do
      request =
        prepare!(
          base_url: @traditional_base_url,
          provider_options: [api_version: "2026-01-01-preview"]
        )

      assert URI.to_string(request.url) =~ "api-version=2026-01-01-preview"
    end
  end

  describe "image generation (v1 GA format)" do
    test "uses /images/generations without api-version and puts deployment in body" do
      request = prepare!(base_url: @v1_ga_base_url)

      assert URI.to_string(request.url) == "/images/generations"
      assert request.options[:json]["model"] == "my-image-deploy"
    end
  end

  describe "image generation (Foundry format)" do
    test "returns a clear error for Foundry endpoints" do
      assert {:error, %ReqLLM.Error.Invalid.Parameter{parameter: message}} =
               Azure.prepare_request(
                 :image,
                 "azure:gpt-image-1",
                 "A simple red square",
                 api_key: "test-api-key",
                 deployment: "my-image-deploy",
                 base_url: @foundry_base_url
               )

      assert message =~ "not supported on Azure AI Foundry"
    end
  end

  describe "image edits" do
    test "traditional format uses /images/edits with multipart body and no model part" do
      request =
        prepare!(
          base_url: @traditional_base_url,
          prompt: "Make the square blue",
          source_image: @png_bytes,
          mask: @png_bytes
        )

      assert URI.to_string(request.url) ==
               "/deployments/my-image-deploy/images/edits?api-version=2025-04-01-preview"

      parts = request.options[:form_multipart]
      assert Keyword.has_key?(parts, :image)
      assert Keyword.has_key?(parts, :mask)
      assert parts[:prompt] == "Make the square blue"
      refute Keyword.has_key?(parts, :model)
    end

    test "multipart requests do not get a JSON content-type header" do
      request =
        prepare!(
          base_url: @traditional_base_url,
          source_image: @png_bytes
        )

      assert Req.Request.get_header(request, "content-type") == []
    end

    test "v1 GA format keeps the deployment as the model form part" do
      request =
        prepare!(
          base_url: @v1_ga_base_url,
          source_image: @png_bytes
        )

      assert URI.to_string(request.url) == "/images/edits"
      assert request.options[:form_multipart][:model] == "my-image-deploy"
    end
  end

  describe "model validation" do
    test "rejects non-gpt models with a clear error" do
      assert {:error, %ReqLLM.Error.Invalid.Parameter{parameter: message}} =
               Azure.prepare_request(
                 :image,
                 "azure:claude-3-5-sonnet-20241022",
                 "A simple red square",
                 api_key: "test-api-key",
                 base_url: @traditional_base_url
               )

      assert message =~ "does not support image generation"
      assert message =~ "gpt-image-1"
    end
  end

  describe "decode_response/1" do
    test "decodes b64_json image data into a ReqLLM.Response with image content parts" do
      request = prepare!(base_url: @traditional_base_url)

      image_data = @png_bytes
      body = %{"created" => 1_700_000_000, "data" => [%{"b64_json" => Base.encode64(image_data)}]}
      response = %Req.Response{status: 200, body: body}

      {_req, decoded} = Azure.decode_response({request, response})

      assert %ReqLLM.Response{} = decoded.body
      images = ReqLLM.Response.images(decoded.body)
      assert [%ReqLLM.Message.ContentPart{type: :image, data: ^image_data}] = images
    end

    test "non-200 image responses fall through to Azure error handling" do
      request = prepare!(base_url: @traditional_base_url)

      response = %Req.Response{
        status: 400,
        body: %{"error" => %{"message" => "Bad prompt", "code" => "invalid_prompt"}}
      }

      {_req, error} = Azure.decode_response({request, response})

      assert %ReqLLM.Error.API.Response{} = error
      assert error.reason =~ "Bad prompt"
    end
  end
end
