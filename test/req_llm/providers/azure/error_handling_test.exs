defmodule ReqLLM.Providers.Azure.ErrorHandlingTest do
  @moduledoc """
  Tests for Azure provider error handling.

  Covers:
  - decode_response error extraction and formatting
  - Azure-specific error scenarios (validation, unsupported operations)
  - HTTP error status code handling
  """

  use ExUnit.Case, async: true

  alias ReqLLM.Providers.Azure

  describe "decode_response error handling" do
    test "extracts error message from standard Azure error format" do
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

      error_body = %{
        "error" => %{
          "message" => "The API key is invalid",
          "type" => "authentication_error",
          "code" => "invalid_api_key"
        }
      }

      response = %Req.Response{status: 401, body: error_body}

      {_req, result} = Azure.decode_response({request, response})

      assert %ReqLLM.Error.API.Response{} = result
      assert result.status == 401
      assert result.reason =~ "authentication_error"
      assert result.reason =~ "invalid_api_key"
    end

    test "extracts error message from simple error format" do
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

      error_body = %{"error" => %{"message" => "Rate limit exceeded"}}

      response = %Req.Response{status: 429, body: error_body}

      {_req, result} = Azure.decode_response({request, response})

      assert %ReqLLM.Error.API.Response{} = result
      assert result.status == 429
      assert result.reason =~ "Rate limit exceeded"
    end

    test "handles string error body" do
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

      error_body = "Service unavailable"

      response = %Req.Response{status: 503, body: error_body}

      {_req, result} = Azure.decode_response({request, response})

      assert %ReqLLM.Error.API.Response{} = result
      assert result.status == 503
      assert result.reason == "Service unavailable"
    end

    test "handles successful response with missing expected fields gracefully" do
      model = traditional_openai_model()
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      request =
        Req.new(url: "/test", method: :post)
        |> Req.Request.register_options([:context, :api_key, :base_url, :operation, :model])
        |> Req.Request.merge_options(
          context: context,
          operation: :chat,
          model: model.id
        )
        |> Azure.attach(model,
          api_key: "test-api-key",
          context: context,
          base_url: "https://my-resource.openai.azure.com/openai"
        )
        |> Req.Request.put_private(:model, model)

      malformed_body = %{"unexpected" => "response"}

      response = %Req.Response{status: 200, body: malformed_body}

      {_req, result} = Azure.decode_response({request, response})

      assert %Req.Response{body: %ReqLLM.Response{}} = result
      assert result.body.finish_reason == nil
    end

    test "extracts error from nested Azure error structure" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      request =
        Req.new(
          method: :post,
          url: "https://test.openai.azure.com/openai/deployments/test/chat/completions"
        )
        |> Req.Request.put_private(:context, context)
        |> Req.Request.put_private(:model, model)

      error_body = %{
        "error" => %{
          "code" => "DeploymentNotFound",
          "message" => "The API deployment for this resource does not exist.",
          "innererror" => %{
            "code" => "ModelNotFound",
            "message" => "Model 'gpt-4o-invalid' not found in deployment"
          }
        }
      }

      response = %Req.Response{status: 404, body: error_body}

      {_req, result} = Azure.decode_response({request, response})

      assert %ReqLLM.Error.API.Response{} = result
      assert result.status == 404
      assert result.reason =~ "DeploymentNotFound"
    end

    test "handles quota exceeded error" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      request =
        Req.new(
          method: :post,
          url: "https://test.openai.azure.com/openai/deployments/test/chat/completions"
        )
        |> Req.Request.put_private(:context, context)
        |> Req.Request.put_private(:model, model)

      error_body = %{
        "error" => %{
          "code" => "429",
          "message" =>
            "Requests to the ChatCompletions_Create Operation under Azure OpenAI API version 2024-08-01-preview have exceeded token rate limit of your current OpenAI S0 pricing tier."
        }
      }

      response = %Req.Response{status: 429, body: error_body}

      {_req, result} = Azure.decode_response({request, response})

      assert %ReqLLM.Error.API.Response{} = result
      assert result.status == 429
      assert result.reason =~ "rate limit" or result.reason =~ "429"
    end

    test "handles content filter error" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      request =
        Req.new(
          method: :post,
          url: "https://test.openai.azure.com/openai/deployments/test/chat/completions"
        )
        |> Req.Request.put_private(:context, context)
        |> Req.Request.put_private(:model, model)

      error_body = %{
        "error" => %{
          "code" => "content_filter",
          "message" =>
            "The response was filtered due to the prompt triggering Azure OpenAI's content management policy.",
          "status" => 400,
          "innererror" => %{
            "code" => "ResponsibleAIPolicyViolation",
            "content_filter_result" => %{
              "hate" => %{"filtered" => false, "severity" => "safe"},
              "self_harm" => %{"filtered" => true, "severity" => "high"}
            }
          }
        }
      }

      response = %Req.Response{status: 400, body: error_body}

      {_req, result} = Azure.decode_response({request, response})

      assert %ReqLLM.Error.API.Response{} = result
      assert result.status == 400
      assert result.reason =~ "content_filter"
    end

    test "handles plain text error response" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      request =
        Req.new(
          method: :post,
          url: "https://test.openai.azure.com/openai/deployments/test/chat/completions"
        )
        |> Req.Request.put_private(:context, context)
        |> Req.Request.put_private(:model, model)

      response = %Req.Response{status: 500, body: "Internal Server Error"}

      {_req, result} = Azure.decode_response({request, response})

      assert %ReqLLM.Error.API.Response{} = result
      assert result.status == 500
    end

    test "handles response with empty choices array" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      request =
        Req.new(url: "/test", method: :post)
        |> Req.Request.register_options([:context, :api_key, :base_url, :operation, :model])
        |> Req.Request.merge_options(context: context, operation: :chat, model: model.id)
        |> Azure.attach(model,
          api_key: "test-api-key",
          context: context,
          base_url: "https://my-resource.openai.azure.com/openai"
        )
        |> Req.Request.put_private(:model, model)

      body = %{
        "id" => "chatcmpl-123",
        "object" => "chat.completion",
        "model" => "gpt-4o",
        "choices" => [],
        "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 0, "total_tokens" => 10}
      }

      response = %Req.Response{status: 200, body: body}

      {_req, result} = Azure.decode_response({request, response})

      assert %Req.Response{body: %ReqLLM.Response{}} = result
    end

    test "handles response with null content" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      request =
        Req.new(url: "/test", method: :post)
        |> Req.Request.register_options([:context, :api_key, :base_url, :operation, :model])
        |> Req.Request.merge_options(context: context, operation: :chat, model: model.id)
        |> Azure.attach(model,
          api_key: "test-api-key",
          context: context,
          base_url: "https://my-resource.openai.azure.com/openai"
        )
        |> Req.Request.put_private(:model, model)

      body = %{
        "id" => "chatcmpl-123",
        "object" => "chat.completion",
        "model" => "gpt-4o",
        "choices" => [
          %{
            "index" => 0,
            "message" => %{"role" => "assistant", "content" => nil},
            "finish_reason" => "stop"
          }
        ],
        "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 0, "total_tokens" => 10}
      }

      response = %Req.Response{status: 200, body: body}

      {_req, result} = Azure.decode_response({request, response})

      assert %Req.Response{body: %ReqLLM.Response{}} = result
    end

    test "handles response with tool_calls but missing function field" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      request =
        Req.new(url: "/test", method: :post)
        |> Req.Request.register_options([:context, :api_key, :base_url, :operation, :model])
        |> Req.Request.merge_options(context: context, operation: :chat, model: model.id)
        |> Azure.attach(model,
          api_key: "test-api-key",
          context: context,
          base_url: "https://my-resource.openai.azure.com/openai"
        )
        |> Req.Request.put_private(:model, model)

      body = %{
        "id" => "chatcmpl-123",
        "object" => "chat.completion",
        "model" => "gpt-4o",
        "choices" => [
          %{
            "index" => 0,
            "message" => %{
              "role" => "assistant",
              "content" => nil,
              "tool_calls" => [%{"id" => "call_123", "type" => "function"}]
            },
            "finish_reason" => "tool_calls"
          }
        ],
        "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15}
      }

      response = %Req.Response{status: 200, body: body}

      {_req, result} = Azure.decode_response({request, response})

      assert %Req.Response{} = result
    end
  end

  describe "Azure-specific error handling" do
    test "raises ArgumentError when base_url is empty" do
      model = ReqLLM.Test.AzureModelHelpers.chat_model("gpt-4o")

      assert_raise ArgumentError, ~r/base_url/i, fn ->
        Azure.prepare_request(
          :chat,
          model,
          "Hello",
          base_url: "",
          deployment: "my-deployment"
        )
      end
    end

    test "returns error for embeddings with Claude model" do
      model = ReqLLM.Test.AzureModelHelpers.chat_model("claude-3-5-sonnet-20241022")

      result =
        Azure.prepare_request(
          :embedding,
          model,
          "Hello",
          base_url: "https://my-resource.openai.azure.com/openai",
          deployment: "claude-deployment"
        )

      assert {:error, error} = result
      assert Exception.message(error) =~ "embedding" or Exception.message(error) =~ "Claude"
    end
  end

  describe "HTTP error status codes" do
    test "handles 401 Unauthorized error" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      request =
        Req.new(
          method: :post,
          url: "https://test.openai.azure.com/openai/deployments/test/chat/completions"
        )
        |> Req.Request.put_private(:context, context)
        |> Req.Request.put_private(:model, model)

      error_body = %{
        "error" => %{
          "code" => "401",
          "message" => "Access denied due to invalid subscription key or wrong API endpoint."
        }
      }

      response = %Req.Response{status: 401, body: error_body}

      {_req, result} = Azure.decode_response({request, response})

      assert %ReqLLM.Error.API.Response{} = result
      assert result.status == 401
    end

    test "handles 403 Forbidden error" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      request =
        Req.new(
          method: :post,
          url: "https://test.openai.azure.com/openai/deployments/test/chat/completions"
        )
        |> Req.Request.put_private(:context, context)
        |> Req.Request.put_private(:model, model)

      error_body = %{
        "error" => %{
          "code" => "PermissionDenied",
          "message" => "Principal does not have access to API/Operation."
        }
      }

      response = %Req.Response{status: 403, body: error_body}

      {_req, result} = Azure.decode_response({request, response})

      assert %ReqLLM.Error.API.Response{} = result
      assert result.status == 403
    end

    test "handles 408 Request Timeout error" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      request =
        Req.new(
          method: :post,
          url: "https://test.openai.azure.com/openai/deployments/test/chat/completions"
        )
        |> Req.Request.put_private(:context, context)
        |> Req.Request.put_private(:model, model)

      error_body = %{"error" => %{"message" => "Request timed out"}}

      response = %Req.Response{status: 408, body: error_body}

      {_req, result} = Azure.decode_response({request, response})

      assert %ReqLLM.Error.API.Response{} = result
      assert result.status == 408
    end

    test "handles 502 Bad Gateway error" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      request =
        Req.new(
          method: :post,
          url: "https://test.openai.azure.com/openai/deployments/test/chat/completions"
        )
        |> Req.Request.put_private(:context, context)
        |> Req.Request.put_private(:model, model)

      response = %Req.Response{status: 502, body: "Bad Gateway"}

      {_req, result} = Azure.decode_response({request, response})

      assert %ReqLLM.Error.API.Response{} = result
      assert result.status == 502
    end

    test "handles 503 Service Unavailable error" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      request =
        Req.new(
          method: :post,
          url: "https://test.openai.azure.com/openai/deployments/test/chat/completions"
        )
        |> Req.Request.put_private(:context, context)
        |> Req.Request.put_private(:model, model)

      error_body = %{
        "error" => %{"message" => "The server is temporarily unable to handle the request."}
      }

      response = %Req.Response{status: 503, body: error_body}

      {_req, result} = Azure.decode_response({request, response})

      assert %ReqLLM.Error.API.Response{} = result
      assert result.status == 503
    end

    test "handles 504 Gateway Timeout error" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      request =
        Req.new(
          method: :post,
          url: "https://test.openai.azure.com/openai/deployments/test/chat/completions"
        )
        |> Req.Request.put_private(:context, context)
        |> Req.Request.put_private(:model, model)

      response = %Req.Response{status: 504, body: "Gateway Timeout"}

      {_req, result} = Azure.decode_response({request, response})

      assert %ReqLLM.Error.API.Response{} = result
      assert result.status == 504
    end
  end

  defp traditional_openai_model do
    %LLMDB.Model{
      id: "gpt-4o",
      provider: :azure,
      capabilities: %{chat: true},
      extra: %{}
    }
  end
end
