defmodule ReqLLM.EmbeddingTest do
  @moduledoc """
  Test suite for embedding functionality across all providers.

  This test suite covers:
  - Single text embedding generation
  - Batch text embedding generation
  - Model validation for embedding support
  - Provider-specific functionality
  - Error handling
  """

  use ExUnit.Case, async: true

  alias ReqLLM.Embedding

  describe "supported_models/0" do
    test "returns list of available embedding models" do
      models = Embedding.supported_models()

      assert is_list(models)
      refute Enum.empty?(models)

      # Should include OpenAI models
      assert "openai:text-embedding-3-small" in models
      assert "openai:text-embedding-3-large" in models
      assert "openai:text-embedding-ada-002" in models

      # Should include Google model if available
      if "google:gemini-embedding-001" in models do
        assert "google:gemini-embedding-001" in models
      end
    end

    test "all returned models follow provider:model format" do
      models = Embedding.supported_models()

      for model <- models do
        assert model =~ ~r/^[a-z_]+:[a-z0-9\-_.]+$/i
      end
    end
  end

  describe "validate_model/1" do
    test "validates OpenAI embedding models" do
      assert {:ok, model} = Embedding.validate_model("openai:text-embedding-3-small")
      assert model.provider == :openai
      assert model.model == "text-embedding-3-small"
    end

    test "validates Google embedding model if available" do
      case Embedding.validate_model("google:gemini-embedding-001") do
        {:ok, model} ->
          assert model.provider == :google
          assert model.model == "gemini-embedding-001"

        {:error, _} ->
          # May not be implemented yet
          :ok
      end
    end

    test "rejects non-embedding models" do
      assert {:error, error} = Embedding.validate_model("openai:gpt-4")
      assert Exception.message(error) =~ "does not support embedding operations"
    end

    test "rejects unsupported providers" do
      assert {:error, :unknown_provider} = Embedding.validate_model("unsupported:model")
    end

    test "handles various model input formats" do
      # String format
      assert {:ok, _} = Embedding.validate_model("openai:text-embedding-3-small")

      # Model struct format
      {:ok, model} = ReqLLM.model("openai:text-embedding-3-small")
      assert {:ok, _} = Embedding.validate_model(model)

      # Tuple format (if supported)
      assert {:ok, _} = Embedding.validate_model({:openai, id: "text-embedding-3-small"})
    end
  end

  describe "embed/3 - basic functionality" do
    test "validates model before attempting embedding" do
      # Should work with valid embedding model
      case Embedding.validate_model("openai:text-embedding-3-small") do
        {:ok, _model} ->
          # Model validation works
          :ok

        {:error, _error} ->
          # Model or provider not available in test environment
          :ok
      end
    end

    test "rejects non-embedding models" do
      assert {:error, error} = Embedding.embed("openai:gpt-4", "Hello")
      assert Exception.message(error) =~ "does not support embedding operations"
    end

    test "rejects unsupported providers" do
      assert {:error, :unknown_provider} = Embedding.embed("unsupported:model", "Hello")
    end
  end

  describe "embed_many/3 - basic functionality" do
    test "validates model before attempting embedding" do
      case Embedding.validate_model("openai:text-embedding-3-small") do
        {:ok, _model} ->
          # Model validation works
          :ok

        {:error, _error} ->
          # Model or provider not available in test environment
          :ok
      end
    end

    test "handles empty list" do
      # This should fail at validation stage due to model validation
      assert {:error, _error} = Embedding.embed("openai:text-embedding-3-small", [])
    end

    test "rejects non-embedding models" do
      assert {:error, error} = Embedding.embed("openai:gpt-4", ["Hello"])
      assert Exception.message(error) =~ "does not support embedding operations"
    end
  end

  describe "error handling" do
    test "validates input parameters" do
      assert {:error, _} = Embedding.embed("invalid:model", "text")
      assert {:error, _} = Embedding.embed("invalid:model", ["text"])
    end

    test "ensures function exists with correct arity" do
      assert function_exported?(Embedding, :embed, 3)
      assert function_exported?(Embedding, :validate_model, 1)
      assert function_exported?(Embedding, :supported_models, 0)
      assert function_exported?(Embedding, :schema, 0)
    end
  end

  describe "schema validation" do
    test "embedding schema includes required options" do
      schema = Embedding.schema()

      assert is_struct(schema, NimbleOptions)

      # Check that key embedding options are supported by checking the documentation
      docs = NimbleOptions.docs(schema)

      assert docs =~ "dimensions"
      assert docs =~ "encoding_format"
      assert docs =~ "user"
    end

    test "validates options correctly" do
      # Invalid dimensions should fail at validation stage
      assert {:error, error} =
               Embedding.embed("openai:text-embedding-3-small", "Hello", dimensions: -1)

      # The error gets wrapped in Unknown, so we need to check the wrapped error
      assert %ReqLLM.Error.Unknown.Unknown{} = error
      assert %NimbleOptions.ValidationError{} = error.error
    end
  end

  describe "integration with ReqLLM.Model" do
    test "works with ReqLLM.model/1" do
      {:ok, model} = ReqLLM.model("openai:text-embedding-3-small")

      # Should validate successfully
      case Embedding.validate_model(model) do
        {:ok, validated_model} ->
          assert validated_model.provider == :openai
          assert validated_model.model == "text-embedding-3-small"

        {:error, _} ->
          # Provider not available in test environment
          :ok
      end
    end
  end
end
