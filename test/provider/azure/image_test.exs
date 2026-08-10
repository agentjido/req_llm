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

    test "passes n and output_format into the body" do
      request = prepare!(base_url: @traditional_base_url, n: 3, output_format: :webp)

      body = request.options[:json]
      assert body["n"] == 3
      assert body["output_format"] == "webp"
    end

    # The Images API rejects these with `unknown_parameter`, so they are dropped
    # with a warning before the request goes out rather than surfacing as a
    # provider 400; `on_unsupported: :error` upgrades the drop to a hard error.
    for {option, value} <- [seed: 42, negative_prompt: "blurry"] do
      test "drops :#{option}, which the Images API does not accept" do
        request =
          prepare!([base_url: @traditional_base_url] ++ [{unquote(option), unquote(value)}])

        assert request.options[unquote(option)] == nil
        refute Map.has_key?(request.options[:json], to_string(unquote(option)))
      end

      test ":#{option} with on_unsupported: :error is a hard error" do
        assert {:error, %ReqLLM.Error.Validation.Error{reason: reason}} =
                 Azure.prepare_request(
                   :image,
                   "azure:gpt-image-1",
                   "A simple red square",
                   [
                     api_key: "test-api-key",
                     deployment: "my-image-deploy",
                     base_url: @traditional_base_url,
                     on_unsupported: :error
                   ] ++ [{unquote(option), unquote(value)}]
                 )

        assert reason =~ to_string(unquote(option))
      end
    end

    test "translates the DALL-E :hd quality name for gpt-image deployments" do
      request = prepare!(base_url: @traditional_base_url, quality: :hd)

      assert request.options[:json]["quality"] == "high"
    end

    test "drops :style, which gpt-image models do not accept" do
      request = prepare!(base_url: @traditional_base_url, style: "vivid")

      refute Map.has_key?(request.options[:json], "style")
    end

    test "sets a Finch pool_timeout matching the long image receive_timeout" do
      request = prepare!(base_url: @traditional_base_url)

      assert request.options[:finch][:pool_timeout] == 120_000
    end

    test "resolves aspect_ratio to the nearest size the model offers" do
      for {ratio, expected} <- [
            {"1:1", "1024x1024"},
            {"16:9", "1536x1024"},
            {"3:2", "1536x1024"},
            {"9:16", "1024x1536"},
            {"2:3", "1024x1536"}
          ] do
        request = prepare!(base_url: @traditional_base_url, aspect_ratio: ratio)

        assert request.options[:json]["size"] == expected
      end
    end

    test "an explicit size wins over aspect_ratio" do
      request =
        prepare!(base_url: @traditional_base_url, size: "1024x1024", aspect_ratio: "16:9")

      assert request.options[:json]["size"] == "1024x1024"
    end

    test "never sends aspect_ratio on the wire" do
      request = prepare!(base_url: @traditional_base_url, aspect_ratio: "16:9")

      refute Map.has_key?(request.options[:json], "aspect_ratio")
    end

    test "rejects a malformed aspect_ratio" do
      assert {:error, %ReqLLM.Error.Invalid.Parameter{parameter: message}} =
               Azure.prepare_request(
                 :image,
                 "azure:gpt-image-1",
                 "A simple red square",
                 api_key: "test-api-key",
                 deployment: "my-image-deploy",
                 base_url: @traditional_base_url,
                 aspect_ratio: "sixteen by nine"
               )

      assert message =~ "aspect_ratio"
    end

    test "returns an error tuple for invalid options instead of raising" do
      assert {:error, error} =
               Azure.prepare_request(
                 :image,
                 "azure:gpt-image-1",
                 "A simple red square",
                 api_key: "test-api-key",
                 deployment: "my-image-deploy",
                 base_url: @traditional_base_url,
                 source_image: nil
               )

      assert Exception.message(error) =~ "source_image"
    end

    test "rejects a mask without a source_image" do
      assert {:error, %ReqLLM.Error.Invalid.Parameter{parameter: message}} =
               Azure.prepare_request(
                 :image,
                 "azure:gpt-image-1",
                 "Remove the sky",
                 api_key: "test-api-key",
                 deployment: "my-image-deploy",
                 base_url: @traditional_base_url,
                 mask: @png_bytes
               )

      assert message =~ "source_image"
    end

    test "rejects an empty prompt" do
      assert {:error, %ReqLLM.Error.Invalid.Parameter{parameter: message}} =
               Azure.prepare_request(
                 :image,
                 "azure:gpt-image-1",
                 "   ",
                 api_key: "test-api-key",
                 deployment: "my-image-deploy",
                 base_url: @traditional_base_url
               )

      assert message =~ "non-empty user text prompt"
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

    test "returns the same error for edit requests" do
      assert {:error, %ReqLLM.Error.Invalid.Parameter{parameter: message}} =
               Azure.prepare_request(
                 :image,
                 "azure:gpt-image-1",
                 "Make the square blue",
                 api_key: "test-api-key",
                 deployment: "my-image-deploy",
                 base_url: @foundry_base_url,
                 source_image: @png_bytes
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

    test "rejects gpt chat models that are not image models" do
      for model_spec <- ["azure:gpt-4o", "azure:gpt-5.1"] do
        assert {:error, %ReqLLM.Error.Invalid.Parameter{parameter: message}} =
                 Azure.prepare_request(
                   :image,
                   model_spec,
                   "A simple red square",
                   api_key: "test-api-key",
                   deployment: "my-image-deploy",
                   base_url: @traditional_base_url
                 )

        assert message =~ "does not support image generation"
      end
    end

    test "accepts every documented gpt-image model" do
      for model_spec <- ["azure:gpt-image-1", "azure:gpt-image-1.5", "azure:gpt-image-2"] do
        assert {:ok, _request} =
                 Azure.prepare_request(
                   :image,
                   model_spec,
                   "A simple red square",
                   api_key: "test-api-key",
                   deployment: "my-image-deploy",
                   base_url: @traditional_base_url
                 )
      end
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

    test "reports the model id and image usage metadata" do
      request = prepare!(base_url: @traditional_base_url, size: "1024x1024", quality: "high")

      body = %{"created" => 1_700_000_000, "data" => [%{"b64_json" => Base.encode64(@png_bytes)}]}

      {_req, decoded} = Azure.decode_response({request, %Req.Response{status: 200, body: body}})

      # The catalog model id, not the deployment name, so cost lookups resolve.
      assert decoded.body.model == "gpt-image-1"
      assert %{image_usage: image_usage} = decoded.body.usage
      assert map_size(image_usage) > 0
    end

    test "lifts the Images API token usage into response usage" do
      request = prepare!(base_url: @traditional_base_url, size: "1024x1024", quality: "low")

      body = %{
        "created" => 1_700_000_000,
        "data" => [%{"b64_json" => Base.encode64(@png_bytes)}],
        "usage" => %{"input_tokens" => 14, "output_tokens" => 229, "total_tokens" => 243}
      }

      {_req, decoded} = Azure.decode_response({request, %Req.Response{status: 200, body: body}})

      usage = decoded.body.usage
      assert usage.input_tokens == 14
      assert usage.output_tokens == 229
      assert usage.total_tokens == 243
      assert %{generated: %{count: 1}} = usage.image_usage
    end

    test "token usage yields a non-zero cost, since Azure prices images per token" do
      request = prepare!(base_url: @traditional_base_url, size: "1024x1024", quality: "low")

      body = %{
        "created" => 1_700_000_000,
        "data" => [%{"b64_json" => Base.encode64(@png_bytes)}],
        "usage" => %{"input_tokens" => 14, "output_tokens" => 229, "total_tokens" => 243}
      }

      {_req, decoded} = Azure.decode_response({request, %Req.Response{status: 200, body: body}})
      {:ok, model} = ReqLLM.model("azure:gpt-image-1")

      assert {:ok, breakdown} = ReqLLM.Billing.calculate(decoded.body.usage, model)
      assert breakdown.total > 0
      assert breakdown.tokens > 0
    end

    test "a response without a usage object still reports image usage" do
      request = prepare!(base_url: @traditional_base_url, size: "1024x1024", quality: "low")

      body = %{"created" => 1_700_000_000, "data" => [%{"b64_json" => Base.encode64(@png_bytes)}]}

      {_req, decoded} = Azure.decode_response({request, %Req.Response{status: 200, body: body}})

      usage = decoded.body.usage
      assert %{generated: %{count: 1}} = usage.image_usage
      refute Map.has_key?(usage, :input_tokens)
    end

    test "keys provider_meta under azure rather than openai" do
      request = prepare!(base_url: @traditional_base_url)

      body = %{"created" => 1_700_000_000, "data" => [%{"b64_json" => Base.encode64(@png_bytes)}]}

      {_req, decoded} = Azure.decode_response({request, %Req.Response{status: 200, body: body}})

      assert %{"azure" => meta} = decoded.body.provider_meta
      assert meta["created"] == 1_700_000_000
      refute Map.has_key?(decoded.body.provider_meta, "openai")
    end

    test "a non-200 2xx response still decodes as success" do
      request = prepare!(base_url: @traditional_base_url)

      body = %{"created" => 1_700_000_000, "data" => [%{"b64_json" => Base.encode64(@png_bytes)}]}

      {_req, decoded} = Azure.decode_response({request, %Req.Response{status: 202, body: body}})

      assert %ReqLLM.Response{} = decoded.body
      assert [_image] = ReqLLM.Response.images(decoded.body)
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
