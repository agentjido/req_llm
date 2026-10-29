defmodule ReqLLM.Providers.Azure.ProviderUsageTest do
  @moduledoc """
  Provider usage extraction across Chat Completions, Responses API, and Claude models.
  """

  use ExUnit.Case, async: true

  import ReqLLM.Test.AzureModelHelpers, only: [traditional_openai_model: 0]

  alias ReqLLM.Providers.Azure

  describe "extract_usage/2" do
    test "extracts usage for OpenAI models" do
      model = traditional_openai_model()

      body = %{
        "usage" => %{
          "prompt_tokens" => 10,
          "completion_tokens" => 20,
          "total_tokens" => 30
        }
      }

      {:ok, usage} = Azure.extract_usage(body, model)

      assert usage.input_tokens == 10
      assert usage.output_tokens == 20
      assert usage.total_tokens == 30
    end

    test "extracts usage for Responses API models" do
      {:ok, model} = ReqLLM.model("azure:gpt-5.4")

      body = %{
        "usage" => %{
          "input_tokens" => 10,
          "output_tokens" => 20,
          "total_tokens" => 30,
          "input_tokens_details" => %{"cached_tokens" => 4}
        }
      }

      {:ok, usage} = Azure.extract_usage(body, model)

      assert usage.input_tokens == 10
      assert usage.output_tokens == 20
      assert usage.total_tokens == 30
      assert usage.cached_tokens == 4
      assert usage.reasoning_tokens == 0
    end

    test "extracts reasoning tokens for o1 models" do
      {:ok, model} = ReqLLM.model("azure:o1")

      body = %{
        "usage" => %{
          "input_tokens" => 100,
          "output_tokens" => 200,
          "total_tokens" => 300,
          "output_tokens_details" => %{
            "reasoning_tokens" => 150
          }
        }
      }

      {:ok, usage} = Azure.extract_usage(body, model)

      assert usage.input_tokens == 100
      assert usage.output_tokens == 200
      assert usage.reasoning_tokens == 150
    end

    test "extracts usage for Claude models" do
      model = ReqLLM.Test.AzureModelHelpers.chat_model("claude-3-5-sonnet-20241022")

      body = %{
        "usage" => %{
          "input_tokens" => 15,
          "output_tokens" => 25
        }
      }

      {:ok, usage} = Azure.extract_usage(body, model)

      assert usage["input_tokens"] == 15
      assert usage["output_tokens"] == 25
    end

    test "returns error when no usage data" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")

      body = %{"choices" => []}

      assert {:error, _} = Azure.extract_usage(body, model)
    end
  end
end
