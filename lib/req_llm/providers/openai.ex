defmodule ReqLLM.Providers.OpenAI do
  @moduledoc """
  OpenAI provider implementation using the Provider behavior.

  Supports OpenAI's Chat Completions API and Embeddings API with features including:
  - Text generation with GPT models
  - Streaming responses
  - Tool calling
  - Multi-modal inputs (text and images)
  - Embeddings generation
  - O1/O3 model support with automatic parameter translation

  ## Protocol Usage

  Uses the generic `ReqLLM.Context.Codec` and `ReqLLM.Response.Codec` protocols.
  No custom wrapper modules – leverages the standard OpenAI-compatible codecs.

  ## Configuration

  Set your OpenAI API key via environment variable or JidoKeys:

      # Option 1: Environment variable (automatically loaded)
      OPENAI_API_KEY=sk-...

      # Option 2: Set directly in JidoKeys
      ReqLLM.put_key(:openai_api_key, "sk-...")

  ## Examples

      # Simple text generation
      model = ReqLLM.Model.from("openai:gpt-4")
      {:ok, response} = ReqLLM.generate_text(model, "Hello!")

      # Streaming
      {:ok, stream} = ReqLLM.stream_text(model, "Tell me a story", stream: true)

      # Tool calling
      tools = [%ReqLLM.Tool{name: "get_weather", ...}]
      {:ok, response} = ReqLLM.generate_text(model, "What's the weather?", tools: tools)

      # Embeddings
      {:ok, embedding} = ReqLLM.generate_embedding("openai:text-embedding-3-small", "Hello world")
  """

  @behaviour ReqLLM.Provider

  use ReqLLM.Provider.DSL,
    id: :openai,
    base_url: "https://api.openai.com/v1",
    metadata: "priv/models_dev/openai.json",
    default_env_key: "OPENAI_API_KEY",
    provider_schema: [
      dimensions: [
        type: :pos_integer,
        doc: "Dimensions for embedding models (e.g., text-embedding-3-small supports 512-1536)"
      ],
      encoding_format: [type: :string, doc: "Format for embedding output (float, base64)"]
    ]

  import ReqLLM.Provider.Utils, only: [maybe_put: 3]

  require Logger

  @doc """
  Custom prepare_request for :object operations to maintain OpenAI-specific token handling and O1/O3 model support.
  """
  @impl ReqLLM.Provider

  def prepare_request(:object, model_spec, prompt, opts) do
    compiled_schema = Keyword.fetch!(opts, :compiled_schema)

    structured_output_tool =
      ReqLLM.Tool.new!(
        name: "structured_output",
        description: "Generate structured output matching the provided schema",
        parameter_schema: compiled_schema.schema,
        callback: fn _args -> {:ok, "structured output generated"} end
      )

    opts_with_tool =
      opts
      |> Keyword.update(:tools, [structured_output_tool], &[structured_output_tool | &1])
      |> Keyword.put(:tool_choice, %{type: "function", function: %{name: "structured_output"}})
      |> Keyword.put_new(:max_tokens, 4096)

    prepare_request(:chat, model_spec, prompt, opts_with_tool)
  end

  # Delegate all other operations to defaults
  def prepare_request(operation, model_spec, input, opts) do
    case ReqLLM.Provider.Defaults.prepare_request(__MODULE__, operation, model_spec, input, opts) do
      {:error, %ReqLLM.Error.Invalid.Parameter{parameter: param}} ->
        # Customize error message for unsupported operations
        custom_param = String.replace(param, inspect(__MODULE__), "OpenAI provider")
        {:error, ReqLLM.Error.Invalid.Parameter.exception(parameter: custom_param)}

      result ->
        result
    end
  end

  @doc """
  Translates provider-specific options for different model types.

  ## Reasoning Models

  Models with reasoning capabilities (o1, o3, o4, gpt-5, etc.) have special parameter requirements:
  - `max_tokens` must be renamed to `max_completion_tokens`
  - `temperature` is not supported and will be dropped for o1/o3 models

  ## Returns

  `{translated_opts, warnings}` where warnings is a list of transformation messages.
  """
  @impl ReqLLM.Provider
  def translate_options(:chat, %ReqLLM.Model{model: model_name, capabilities: capabilities}, opts) do
    # Check if this is a reasoning model either by capabilities or model name patterns
    is_reasoning_model =
      (is_map(capabilities) && Map.get(capabilities, :reasoning) == true) ||
        is_o_series_model?(model_name) ||
        is_gpt5_model?(model_name) ||
        is_reasoning_codex_model?(model_name)

    if is_reasoning_model do
      # All reasoning models need max_completion_tokens instead of max_tokens
      {opts_after_rename, rename_warnings} =
        translate_rename(opts, :max_tokens, :max_completion_tokens)

      # Only o1/o3 models don't support temperature
      if is_o_series_model?(model_name) do
        {final_opts, drop_warnings} =
          translate_drop(
            opts_after_rename,
            :temperature,
            "OpenAI #{get_model_series(model_name)} models do not support :temperature – dropped"
          )

        {final_opts, rename_warnings ++ drop_warnings}
      else
        {opts_after_rename, rename_warnings}
      end
    else
      {opts, []}
    end
  end

  def translate_options(_operation, _model, opts) do
    {opts, []}
  end

  # Helper functions for model type detection
  defp is_o_series_model?(<<"o1", _::binary>>), do: true
  defp is_o_series_model?(<<"o3", _::binary>>), do: true
  defp is_o_series_model?(<<"o4", _::binary>>), do: true
  defp is_o_series_model?(_), do: false

  defp is_gpt5_model?(<<"gpt-5", _::binary>>), do: true
  defp is_gpt5_model?(_), do: false

  defp is_reasoning_codex_model?(<<"codex", rest::binary>>),
    do: String.contains?(rest, "mini-latest")

  defp is_reasoning_codex_model?(_), do: false

  defp get_model_series(<<"o1", _::binary>>), do: "o1"
  defp get_model_series(<<"o3", _::binary>>), do: "o3"
  defp get_model_series(<<"o4", _::binary>>), do: "o4"
  defp get_model_series(_), do: "reasoning"

  @doc """
  Custom body encoding that adds OpenAI-specific token handling for O1/O3 models.
  """
  @impl ReqLLM.Provider
  def encode_body(request) do
    # Start with default encoding
    request = ReqLLM.Provider.Defaults.default_encode_body(request)

    # Parse the encoded body to add model-specific token handling
    body = Jason.decode!(request.body)

    enhanced_body =
      case request.options[:operation] do
        :embedding ->
          add_embedding_options(body, request.options)

        _ ->
          add_token_limits(body, request.options[:model], request.options)
      end

    # Re-encode with enhancements
    encoded_body = Jason.encode!(enhanced_body)
    Map.put(request, :body, encoded_body)
  end

  defp add_embedding_options(body, request_options) do
    provider_opts = request_options[:provider_options] || []

    body
    |> maybe_put(:dimensions, provider_opts[:dimensions])
    |> maybe_put(:encoding_format, provider_opts[:encoding_format])
  end

  @doc """
  Custom decode_response to ensure proper "OpenAI API error" naming.
  """
  @impl ReqLLM.Provider
  def decode_response({req, resp}) do
    case resp.status do
      200 ->
        ReqLLM.Provider.Defaults.default_decode_response({req, resp})

      status ->
        decode_openai_error_response(req, resp, status)
    end
  end

  defp decode_openai_error_response(req, resp, status) do
    err =
      ReqLLM.Error.API.Response.exception(
        reason: "OpenAI API error",
        status: status,
        response_body: resp.body
      )

    {req, err}
  end

  @doc false
  defp add_token_limits(body, model_name, request_options) do
    # Check if this is a reasoning model that needs max_completion_tokens
    if is_o_series_model?(model_name) || is_gpt5_model?(model_name) ||
         is_reasoning_codex_model?(model_name) do
      maybe_put(body, :max_completion_tokens, request_options[:max_completion_tokens])
    else
      maybe_put(body, :max_tokens, request_options[:max_tokens])
    end
  end
end
