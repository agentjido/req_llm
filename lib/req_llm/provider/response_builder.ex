defmodule ReqLLM.Provider.ResponseBuilder do
  @moduledoc """
  Behaviour for provider-specific Response assembly from StreamChunks.

  Both streaming and non-streaming paths converge here, ensuring
  identical Response structs regardless of the code path taken.

  ## Why This Exists

  Different LLM providers have subtle differences in how they represent
  responses, tool calls, finish reasons, and metadata. Previously, these
  differences were handled in multiple places (streaming vs non-streaming,
  provider-specific decoders), leading to behavioral inconsistencies.

  This behaviour centralizes provider-specific Response assembly logic,
  ensuring that:

  1. Streaming and non-streaming produce identical Response structs
  2. Provider quirks are handled in one place per provider
  3. New providers have a clear extension point

  ## Provider-Specific Handling

  - **Anthropic**: Ensures content blocks are never empty (API requirement)
  - **OpenAI Responses API**: Propagates `response_id` for stateless multi-turn
  - **Google**: Detects `functionCall` to set correct finish_reason
  - **Default (OpenAI Chat)**: Standard handling for OpenAI-compatible providers

  ## Usage

  Both streaming and non-streaming paths should:

  1. Decode wire format to `[StreamChunk.t()]`
  2. Collect metadata (usage, finish_reason, provider-specific)
  3. Call the appropriate builder:

      builder = ResponseBuilder.for_model(model)
      {:ok, response} = builder.build_response(chunks, metadata, opts)

  """

  alias ReqLLM.Context
  alias ReqLLM.Response
  alias ReqLLM.StreamChunk

  @type chunks :: [StreamChunk.t()]

  @type metadata :: %{
          optional(:usage) => map(),
          optional(:finish_reason) => atom(),
          optional(:response_id) => String.t(),
          optional(:provider_meta) => map()
        }

  @type opts :: [
          {:context, Context.t()},
          {:model, LLMDB.Model.t()}
        ]

  @doc """
  Build a Response struct from accumulated StreamChunks and metadata.

  This is the central point where provider-specific logic is applied to
  produce a consistent Response struct.

  ## Parameters

    * `chunks` - List of StreamChunk structs from stream processing or
      converted from non-streaming response
    * `metadata` - Map containing usage, finish_reason, and provider-specific
      metadata collected during response processing
    * `opts` - Keyword list with `:context` and `:model`

  ## Returns

    * `{:ok, Response.t()}` - Successfully built response
    * `{:error, term()}` - Build failed

  """
  @callback build_response(chunks(), metadata(), opts()) ::
              {:ok, Response.t()} | {:error, term()}

  @doc """
  Get the appropriate ResponseBuilder module for a given model.

  Routes to provider-specific builders based on model metadata:

    * Anthropic models → `Anthropic.ResponseBuilder`
    * Google/Vertex models → `Google.ResponseBuilder`
    * OpenAI Responses API models → `OpenAI.ResponsesAPI.ResponseBuilder`
    * All others → `Provider.Defaults.ResponseBuilder`

  ## Examples

      iex> model = ReqLLM.model!("anthropic:claude-3-haiku-20240307")
      iex> ResponseBuilder.for_model(model)
      ReqLLM.Providers.Anthropic.ResponseBuilder

      iex> model = ReqLLM.model!("openai:gpt-4o")
      iex> ResponseBuilder.for_model(model)
      ReqLLM.Provider.Defaults.ResponseBuilder

  """
  @spec for_model(LLMDB.Model.t()) :: module()
  def for_model(%LLMDB.Model{provider: :anthropic}),
    do: ReqLLM.Providers.Anthropic.ResponseBuilder

  def for_model(%LLMDB.Model{provider: :google}), do: ReqLLM.Providers.Google.ResponseBuilder

  def for_model(%LLMDB.Model{provider: :google_vertex}),
    do: ReqLLM.Providers.Google.ResponseBuilder

  def for_model(%LLMDB.Model{extra: %{api: "responses"}}),
    do: ReqLLM.Providers.OpenAI.ResponsesAPI.ResponseBuilder

  def for_model(_model), do: ReqLLM.Provider.Defaults.ResponseBuilder
end
