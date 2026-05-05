defmodule ReqLLM.Embedding do
  @moduledoc """
  Embedding functionality for ReqLLM.

  This module provides embedding generation capabilities with support for:
  - Single text embedding generation
  - Batch text embedding generation
  - Model validation for embedding support

  ## Usage Tracking

  By default, `embed/3` returns only the embedding vectors. To also retrieve
  token usage data, pass `return_usage: true`:

      {:ok, %{embedding: vectors, usage: usage}} =
        ReqLLM.embed("openai:text-embedding-3-small", "Hello", return_usage: true)

  Usage maps include canonical token fields and, when model pricing is
  available, flat cost fields such as `total_cost`.
  """

  alias LLMDB.Model

  defp get_embedding_models do
    ReqLLM.Providers.list()
    |> Enum.flat_map(fn provider ->
      LLMDB.models(provider)
      |> Enum.filter(fn model ->
        model.capabilities && model.capabilities.embeddings
      end)
      |> Enum.map(fn model ->
        LLMDB.Model.spec(model)
      end)
    end)
  end

  @base_schema NimbleOptions.new!(
                 dimensions: [
                   type: :pos_integer,
                   doc: "Number of dimensions for the embedding vector"
                 ],
                 encoding_format: [
                   type: {:in, ["float", "base64"]},
                   doc: "Format for encoding the embedding vector",
                   default: "float"
                 ],
                 user: [
                   type: :string,
                   doc: "User identifier for tracking and abuse detection"
                 ],
                 provider_options: [
                   type: {:or, [:map, {:list, :any}]},
                   doc: "Provider-specific options (keyword list or map)",
                   default: []
                 ],
                 req_http_options: [
                   type: {:or, [:map, {:list, :any}]},
                   doc: "Req-specific options (keyword list or map)",
                   default: []
                 ],
                 telemetry: [
                   type: {:or, [:map, {:list, :any}]},
                   doc: "ReqLLM telemetry options (for example, [payloads: :raw])",
                   default: []
                 ],
                 fixture: [
                   type: {:or, [:string, {:tuple, [:atom, :string]}]},
                   doc: "HTTP fixture for testing (provider inferred from model if string)"
                 ],
                 return_usage: [
                   type: :boolean,
                   default: false,
                   doc:
                     "When true, returns %{embedding: vectors, usage: usage_map} instead of just vectors"
                 ]
               )

  @doc """
  Returns the list of supported embedding model specifications.

  ## Examples

      ReqLLM.Embedding.supported_models()
      #=> ["openai:text-embedding-3-small", "openai:text-embedding-3-large", "openai:text-embedding-ada-002", "google:gemini-embedding-001"]

  """
  @spec supported_models() :: [String.t()]
  def supported_models, do: get_embedding_models()

  @doc """
  Validates that a model supports embedding operations.

  ## Parameters

    * `model_spec` - Model specification in various formats

  ## Examples

      ReqLLM.Embedding.validate_model("openai:text-embedding-3-small")
      #=> {:ok, %LLMDB.Model{provider: :openai, model: "text-embedding-3-small"}}

      ReqLLM.Embedding.validate_model("anthropic:claude-3-sonnet")
      #=> {:error, :embedding_not_supported}

  """
  @spec validate_model(ReqLLM.model_input()) ::
          {:ok, Model.t()} | {:error, term()}
  def validate_model(model_spec) do
    with {:ok, model} <- ReqLLM.model(model_spec),
         {:ok, _provider_module} <- ReqLLM.provider(model.provider) do
      model_string = LLMDB.Model.spec(model)

      if embedding_capable_model?(model) do
        {:ok, model}
      else
        {:error,
         ReqLLM.Error.Invalid.Parameter.exception(
           parameter: "model: #{model_string} does not support embedding operations"
         )}
      end
    end
  end

  # Fallback detection for embedding models when LLMDB capabilities metadata is missing/null.
  defp embedding_model_id?(model_id) when is_binary(model_id) do
    String.contains?(model_id, "embedding")
  end

  defp embedding_capable_model?(%Model{} = model) do
    model_string = LLMDB.Model.spec(model)
    capabilities = model.capabilities || %{}

    model_string in get_embedding_models() or
      embeddings_enabled?(capabilities) or
      embedding_model_id?(model.provider_model_id || model.id)
  end

  defp embeddings_enabled?(capabilities) when is_map(capabilities) do
    case capabilities[:embeddings] do
      true -> true
      %{enabled: true} -> true
      _ -> false
    end
  end

  defp embeddings_enabled?(_), do: false

  @doc """
  Returns the base embedding options schema.

  This schema contains embedding-specific options that are vendor-neutral.
  """
  @spec schema :: NimbleOptions.t()
  def schema, do: @base_schema

  @doc """
  Generates embeddings for single or multiple text inputs.

  Accepts either a single string or a list of strings, automatically handling
  both cases using pattern matching.

  ## Parameters

    * `model_spec` - Model specification in various formats
    * `input` - Text string or list of text strings to generate embeddings for
    * `opts` - Additional options (keyword list)

  ## Options

    * `:dimensions` - Number of dimensions for embeddings
    * `:encoding_format` - Format for encoding ("float" or "base64")
    * `:user` - User identifier for tracking
    * `:provider_options` - Provider-specific options
    * `:return_usage` - When `true`, returns `%{embedding: vectors, usage: map}` (default: `false`)

  ## Examples

      # Single text input
      {:ok, embedding} = ReqLLM.Embedding.embed("openai:text-embedding-3-small", "Hello world")
      #=> {:ok, [0.1, -0.2, 0.3, ...]}

      # Multiple text inputs
      {:ok, embeddings} = ReqLLM.Embedding.embed(
        "openai:text-embedding-3-small",
        ["Hello", "World"]
      )
      #=> {:ok, [[0.1, -0.2, ...], [0.3, 0.4, ...]]}

      # With usage data
      {:ok, %{embedding: vectors, usage: usage}} = ReqLLM.Embedding.embed(
        "openai:text-embedding-3-small",
        "Hello world",
        return_usage: true
      )
      Map.has_key?(usage, :total_cost)
      #=> true

  """
  @spec embed(
          ReqLLM.model_input(),
          String.t() | [String.t()],
          keyword()
        ) :: {:ok, [float()] | [[float()]] | map()} | {:error, term()}
  def embed(model_spec, input, opts \\ [])

  def embed(model_spec, text, opts) when is_binary(text) do
    {return_usage, provider_opts} = Keyword.pop(opts, :return_usage, false)

    with {:ok, model} <- validate_model(model_spec),
         :ok <- validate_input(text),
         {:ok, provider_module} <- ReqLLM.provider(model.provider),
         {:ok, request} <-
           provider_module.prepare_request(:embedding, model, text, provider_opts),
         {:ok, %Req.Response{status: status} = response} when status in 200..299 <-
           Req.request(request),
         {:ok, embedding} <- extract_single_embedding(response.body) do
      if return_usage do
        {:ok, %{embedding: embedding, usage: extract_usage(response)}}
      else
        {:ok, embedding}
      end
    else
      {:ok, %Req.Response{status: status, body: body}} ->
        {:error,
         ReqLLM.Error.API.Request.exception(
           reason: "HTTP #{status}: Request failed",
           status: status,
           response_body: body
         )}

      {:error, error} ->
        {:error, error}
    end
  end

  def embed(model_spec, texts, opts) when is_list(texts) do
    {return_usage, provider_opts} = Keyword.pop(opts, :return_usage, false)

    with {:ok, model} <- validate_model(model_spec),
         :ok <- validate_input(texts),
         {:ok, provider_module} <- ReqLLM.provider(model.provider),
         {:ok, request} <-
           provider_module.prepare_request(:embedding, model, texts, provider_opts),
         {:ok, %Req.Response{status: status} = response} when status in 200..299 <-
           Req.request(request),
         {:ok, embeddings} <- extract_multiple_embeddings(response.body) do
      if return_usage do
        {:ok, %{embedding: embeddings, usage: extract_usage(response)}}
      else
        {:ok, embeddings}
      end
    else
      {:ok, %Req.Response{status: status, body: body}} ->
        {:error,
         ReqLLM.Error.API.Request.exception(
           reason: "HTTP #{status}: Request failed",
           status: status,
           response_body: body
         )}

      {:error, error} ->
        {:error, error}
    end
  end

  defp validate_input("") do
    {:error, ReqLLM.Error.Invalid.Parameter.exception(parameter: "text: cannot be empty")}
  end

  defp validate_input(text) when is_binary(text) do
    :ok
  end

  defp validate_input([]) do
    {:error, ReqLLM.Error.Invalid.Parameter.exception(parameter: "texts: cannot be empty")}
  end

  defp validate_input(texts) when is_list(texts) do
    :ok
  end

  defp extract_single_embedding(%{"data" => [%{"embedding" => embedding}]}) do
    {:ok, embedding}
  end

  defp extract_single_embedding(response) do
    {:error,
     ReqLLM.Error.API.Response.exception(
       reason: "Invalid embedding response format",
       response_body: response
     )}
  end

  defp extract_multiple_embeddings(%{"data" => data}) when is_list(data) do
    embeddings =
      data
      |> Enum.sort_by(& &1["index"])
      |> Enum.map(& &1["embedding"])

    {:ok, embeddings}
  end

  defp extract_multiple_embeddings(response) do
    {:error,
     ReqLLM.Error.API.Response.exception(
       reason: "Invalid embedding response format",
       response_body: response
     )}
  end

  defp extract_usage(%Req.Response{private: private}) do
    case get_in(private, [:req_llm, :usage]) do
      %{tokens: tokens} = usage_meta when is_map(tokens) ->
        usage_meta
        |> Map.take([:input_cost, :output_cost, :reasoning_cost, :total_cost])
        |> Enum.reduce(tokens, fn
          {_key, nil}, acc -> acc
          {key, value}, acc -> Map.put(acc, key, value)
        end)

      usage when is_map(usage) ->
        usage

      _ ->
        nil
    end
  end
end
