defmodule ReqLLM.Providers.Groq do
  @moduledoc """
  Groq provider – 100% OpenAI Chat Completions compatible with Groq's high-performance hardware.

  ## Implementation

  Uses built-in OpenAI-style encoding/decoding defaults.
  No custom request/response handling needed – leverages the standard OpenAI wire format.

  ## Groq-Specific Extensions

  Beyond standard OpenAI parameters, Groq supports:
  - `service_tier` - Performance tier (auto, on_demand, flex, performance)
  - `reasoning_effort` - Reasoning level (none, default, low, medium, high)
  - `reasoning_format` - Format for reasoning output
  - `search_settings` - Web search configuration
  - `compound_custom` - Custom Compound systems configuration
  - `logit_bias` - Token bias adjustments

  See `provider_schema/0` for the complete Groq-specific schema and
  `ReqLLM.Provider.Options` for inherited OpenAI parameters.

  ## Configuration

      # Add to .env file (automatically loaded)
      GROQ_API_KEY=gsk_...
  """

  @behaviour ReqLLM.Provider

  use ReqLLM.Provider.DSL,
    id: :groq,
    base_url: "https://api.groq.com/openai/v1",
    metadata: "priv/models_dev/groq.json",
    default_env_key: "GROQ_API_KEY",
    provider_schema: [
      service_tier: [
        type: {:in, ~w(auto on_demand flex performance)},
        doc: "Performance tier for Groq requests"
      ],
      reasoning_effort: [
        type: {:in, ~w(none default low medium high)},
        doc: "Reasoning effort level"
      ],
      reasoning_format: [
        type: :string,
        doc: "Format for reasoning output"
      ],
      search_settings: [
        type: :map,
        doc: "Web search configuration with include/exclude domains"
      ],
      compound_custom: [
        type: :map,
        doc: "Custom configuration for Compound systems"
      ]
    ]

  import ReqLLM.Provider.Utils, only: [maybe_put: 3, maybe_put_skip: 4]

  require Logger

  @doc """
  Custom prepare_request for :object operations to maintain Groq-specific max_tokens handling.

  Ensures that structured output requests have adequate token limits while delegating
  other operations to the default implementation.
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

    # Adjust max_tokens for structured output with Groq-specific minimums
    opts_with_tokens =
      case Keyword.get(opts_with_tool, :max_tokens) do
        nil -> Keyword.put(opts_with_tool, :max_tokens, 4096)
        tokens when tokens < 200 -> Keyword.put(opts_with_tool, :max_tokens, 200)
        _tokens -> opts_with_tool
      end

    # Preserve the :object operation for response decoding
    opts_with_operation = Keyword.put(opts_with_tokens, :operation, :object)

    prepare_request(:chat, model_spec, prompt, opts_with_operation)
  end

  # Delegate all other operations to defaults
  def prepare_request(operation, model_spec, input, opts) do
    ReqLLM.Provider.Defaults.prepare_request(__MODULE__, operation, model_spec, input, opts)
  end

  @doc """
  Custom body encoding that adds Groq-specific extensions to the default OpenAI-compatible format.

  Adds support for:
  - service_tier (auto, on_demand, flex, performance)
  - reasoning_effort (none, default, low, medium, high)
  - reasoning_format
  - search_settings
  - compound_custom
  - logit_bias (in addition to standard options)
  """
  @impl ReqLLM.Provider
  def encode_body(request) do
    # Start with default encoding
    request = ReqLLM.Provider.Defaults.default_encode_body(request)

    # Parse the encoded body to add Groq-specific options
    body = Jason.decode!(request.body)

    enhanced_body =
      body
      |> maybe_put_skip(:service_tier, request.options[:service_tier], ["auto"])
      |> maybe_put_skip(:reasoning_effort, request.options[:reasoning_effort], ["default"])
      |> maybe_put(:reasoning_format, request.options[:reasoning_format])
      |> maybe_put(:search_settings, request.options[:search_settings])
      |> maybe_put(:compound_custom, request.options[:compound_custom])
      |> maybe_put(:logit_bias, request.options[:logit_bias])

    # Re-encode with Groq extensions
    encoded_body = Jason.encode!(enhanced_body)
    Map.put(request, :body, encoded_body)
  end
end
