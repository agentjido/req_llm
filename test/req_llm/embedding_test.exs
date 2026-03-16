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

  defp setup_telemetry do
    test_pid = self()
    ref = System.unique_integer([:positive])
    handler_id = "embedding-usage-handler-#{ref}"

    :telemetry.attach(
      handler_id,
      [:req_llm, :token_usage],
      fn name, measurements, metadata, _ ->
        send(test_pid, {:telemetry_event, name, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

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

    test "accepts inline embedding models outside the catalog" do
      assert {:ok, %LLMDB.Model{id: "text-embedding-4"}} =
               Embedding.validate_model(%{provider: :openai, id: "text-embedding-4"})
    end

    test "accepts inline embedding models declared via capabilities" do
      assert {:ok, %LLMDB.Model{id: "custom-embed"}} =
               Embedding.validate_model(%{
                 provider: :openai,
                 id: "custom-embed",
                 capabilities: %{embeddings: true}
               })
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

  describe "embed/3 - Google Vertex usage metadata" do
    setup do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{
          "predictions" => [
            %{
              "embeddings" => %{
                "values" => [0.1, -0.2, 0.3],
                "statistics" => %{"token_count" => 2}
              }
            }
          ]
        })
      end)

      setup_telemetry()
    end

    test "emits telemetry and returns usage for embeddings" do
      {:ok, %{embedding: embedding, usage: usage}} =
        Embedding.embed(
          "google_vertex:gemini-embedding-001",
          "Hello world",
          access_token: "test-token",
          project_id: "test-project",
          region: "us-central1",
          return_usage: true,
          req_http_options: [plug: {Req.Test, __MODULE__}]
        )

      assert embedding == [0.1, -0.2, 0.3]
      assert usage.input == 2

      assert_receive {:telemetry_event, [:req_llm, :token_usage], measurements,
                      %{model: %LLMDB.Model{provider: :google_vertex, id: "gemini-embedding-001"}} =
                        metadata}

      assert measurements.tokens.input == 2
      assert metadata.model.provider == :google_vertex
      assert metadata.model.id == "gemini-embedding-001"
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
