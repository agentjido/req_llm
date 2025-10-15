defmodule Provider.OpenAI.MetadataTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Provider.Registry

  describe "OpenAI model metadata" do
    test "all OpenAI chat/completion models have api classification" do
      {:ok, model_names} = Registry.list_models(:openai)

      embedding_models = [
        "text-embedding-3-large",
        "text-embedding-3-small",
        "text-embedding-ada-002"
      ]

      non_embedding_models = model_names -- embedding_models

      for model_id <- non_embedding_models do
        {:ok, model} = Registry.get_model(:openai, model_id)
        api_value = get_in(model._metadata, ["api"])

        assert api_value in ["chat", "responses"],
               "Model #{model_id} missing or invalid api classification (got: #{inspect(api_value)})"
      end

      assert not Enum.empty?(non_embedding_models), "No OpenAI non-embedding models found"
    end

    test "o-series models use responses API" do
      responses_models = [
        "o1",
        "o3",
        "o3-mini",
        "o3-pro",
        "o4-mini"
      ]

      for model_id <- responses_models do
        {:ok, model} = Registry.get_model(:openai, model_id)
        api_value = get_in(model._metadata, ["api"])

        assert api_value == "responses",
               "Model #{model_id} should use responses API (got: #{inspect(api_value)})"
      end
    end

    test "gpt-4.1 and gpt-5 models use responses API" do
      responses_models = [
        "gpt-4.1",
        "gpt-5",
        "gpt-5-chat-latest",
        "gpt-5-codex",
        "gpt-5-mini",
        "gpt-5-nano",
        "codex-mini-latest"
      ]

      for model_id <- responses_models do
        {:ok, model} = Registry.get_model(:openai, model_id)
        api_value = get_in(model._metadata, ["api"])

        assert api_value == "responses",
               "Model #{model_id} should use responses API (got: #{inspect(api_value)})"
      end
    end

    test "gpt-4o and other chat models use chat API" do
      chat_models = [
        "gpt-4o",
        "gpt-4o-mini",
        "gpt-4",
        "gpt-4-turbo",
        "gpt-3.5-turbo"
      ]

      for model_id <- chat_models do
        {:ok, model} = Registry.get_model(:openai, model_id)
        api_value = get_in(model._metadata, ["api"])

        assert api_value == "chat",
               "Model #{model_id} should use chat API (got: #{inspect(api_value)})"
      end
    end

    test "embedding models do not have api field" do
      embedding_models = [
        "text-embedding-3-large",
        "text-embedding-3-small",
        "text-embedding-ada-002"
      ]

      for model_id <- embedding_models do
        {:ok, model} = Registry.get_model(:openai, model_id)
        api_value = get_in(model._metadata, ["api"])

        refute api_value,
               "Embedding model #{model_id} should not have api field (got: #{inspect(api_value)})"
      end
    end
  end
end
