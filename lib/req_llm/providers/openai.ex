defmodule ReqLLM.Providers.OpenAI do
  @moduledoc """
  OpenAI provider implementation using the Provider behavior.

  Supports OpenAI's Chat Completions API and Embeddings API with features including:
  - Text generation with GPT models
  - Streaming responses
  - Tool calling
  - Multi-modal inputs (text and images)
  - Embeddings generation
  - O1/O3/GPT-5 model support with automatic parameter translation
  - Reasoning effort control for GPT-5 models

  ## Implementation

  Uses built-in OpenAI-style encoding/decoding defaults.
  No custom request/response handling needed.

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
      encoding_format: [type: :string, doc: "Format for embedding output (float, base64)"],
      max_completion_tokens: [
        type: :integer,
        doc: "Maximum completion tokens (required for reasoning models like o1, o3, gpt-5)"
      ],
      reasoning_effort: [
        type:
          {:or,
           [{:in, [:minimal, :low, :medium, :high]}, {:in, ["minimal", "low", "medium", "high"]}]},
        doc: "Reasoning effort level for GPT-5 models (minimal, low, medium, high)"
      ]
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
      |> Keyword.put(:tool_choice, %{
        type: "function",
        function: %{name: "structured_output"}
      })
      |> put_default_max_tokens_for_model(model_spec)
      |> Keyword.put(:operation, :object)

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

  Uses a profile-based system to apply model-specific parameter transformations.
  Profiles are resolved from model metadata and capabilities, making it easy to
  add new model-specific rules without modifying this function.

  ## Reasoning Models

  Models with reasoning capabilities (o1, o3, o4, gpt-5, etc.) have special parameter requirements:
  - `max_tokens` is renamed to `max_completion_tokens`
  - `temperature` may be unsupported or restricted depending on the specific model

  ## Returns

  `{translated_opts, warnings}` where warnings is a list of transformation messages.
  """
  @impl ReqLLM.Provider
  def translate_options(operation, %ReqLLM.Model{} = model, opts) do
    steps = ReqLLM.Providers.OpenAI.ParamProfiles.steps_for(operation, model)
    ReqLLM.ParamTransform.apply(opts, steps)
  end

  def translate_options(_operation, _model, opts) do
    {opts, []}
  end

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
          body
          |> add_token_limits(request.options[:model], request.options)
          |> add_stream_options(request.options)
          |> add_reasoning_effort(request.options)
          |> translate_tool_choice_format()
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
    if is_reasoning_model_name?(model_name) do
      maybe_put(
        body,
        :max_completion_tokens,
        request_options[:max_completion_tokens] || request_options[:max_tokens]
      )
    else
      body
      |> maybe_put(:max_tokens, request_options[:max_tokens])
      |> maybe_put(:max_completion_tokens, request_options[:max_completion_tokens])
    end
  end

  defp put_default_max_tokens_for_model(opts, model_spec) do
    case ReqLLM.Model.from(model_spec) do
      {:ok, %{model: model_name}} when is_binary(model_name) ->
        if is_reasoning_model_name?(model_name) do
          Keyword.put_new(opts, :max_completion_tokens, 4096)
        else
          Keyword.put_new(opts, :max_tokens, 4096)
        end

      _ ->
        Keyword.put_new(opts, :max_tokens, 4096)
    end
  end

  defp is_reasoning_model_name?(<<"gpt-5", _::binary>>), do: true
  defp is_reasoning_model_name?(<<"o1", _::binary>>), do: true
  defp is_reasoning_model_name?(<<"o3", _::binary>>), do: true
  defp is_reasoning_model_name?(<<"o4", _::binary>>), do: true
  defp is_reasoning_model_name?(_), do: false

  @doc false
  defp add_stream_options(body, request_options) do
    # Automatically include usage data when streaming for better user experience
    if request_options[:stream] do
      maybe_put(body, :stream_options, %{include_usage: true})
    else
      body
    end
  end

  @doc false
  defp add_reasoning_effort(body, request_options) do
    provider_opts = request_options[:provider_options] || []
    maybe_put(body, :reasoning_effort, provider_opts[:reasoning_effort])
  end

  @doc false
  defp translate_tool_choice_format(body) do
    # Handle both atom and string keys in body
    {tool_choice, body_key} =
      cond do
        Map.has_key?(body, :tool_choice) -> {Map.get(body, :tool_choice), :tool_choice}
        Map.has_key?(body, "tool_choice") -> {Map.get(body, "tool_choice"), "tool_choice"}
        true -> {nil, nil}
      end

    # Handle both atom and string keys in tool_choice map
    type = tool_choice && (Map.get(tool_choice, :type) || Map.get(tool_choice, "type"))
    name = tool_choice && (Map.get(tool_choice, :name) || Map.get(tool_choice, "name"))

    if type == "tool" && name do
      # Build replacement with same key types as tool_choice
      replacement =
        if is_map_key(tool_choice, :type) do
          %{type: "function", function: %{name: name}}
        else
          %{"type" => "function", "function" => %{"name" => name}}
        end

      Map.put(body, body_key, replacement)
    else
      body
    end
  end
end
