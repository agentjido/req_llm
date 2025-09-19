defmodule ReqLLM.Provider.Metadata do
  @moduledoc """
  Model metadata schemas for capabilities, limits, and costs.

  This module defines validation schemas for static model information that
  describes what models can do, their constraints, and their pricing. This
  is separate from runtime options (in ReqLLM.Provider.Options) and
  connection configuration (in ReqLLM.Provider.Config).

  ## Usage

  These schemas are primarily used by:
  1. Model metadata files (JSON) for validation
  2. Provider registration and discovery
  3. Model capability checking
  4. Cost estimation and usage tracking

  ## Examples

      # Validate model capabilities
      caps = %{id: "gpt-4", reasoning: true, tool_call: true}
      {:ok, validated} = ReqLLM.Provider.Metadata.validate_capabilities(caps)

      # Validate pricing information
      costs = %{input: 30.0, output: 60.0}
      {:ok, validated} = ReqLLM.Provider.Metadata.validate_costs(costs)
  """

  # Model capability metadata schema
  @capabilities_schema NimbleOptions.new!(
                         id: [
                           type: :string,
                           required: true,
                           doc: "Model identifier"
                         ],
                         provider_model_id: [
                           type: :string,
                           doc: "Provider-specific model ID (may differ from generic ID)"
                         ],
                         name: [
                           type: :string,
                           doc: "Human-readable model name"
                         ],
                         modalities: [
                           type: :map,
                           doc: "Supported input/output modalities",
                           keys: [
                             input: [
                               type: {:list, {:in, [:text, :image, :audio, :video, :document]}},
                               doc: "Supported input modalities"
                             ],
                             output: [
                               type: {:list, {:in, [:text, :image, :audio, :video]}},
                               doc: "Supported output modalities"
                             ]
                           ]
                         ],
                         attachment: [
                           type: :boolean,
                           default: false,
                           doc: "Whether the model supports file attachments"
                         ],
                         reasoning: [
                           type: :boolean,
                           default: false,
                           doc: "Whether the model supports explicit reasoning/thinking tokens"
                         ],
                         tool_call: [
                           type: :boolean,
                           default: false,
                           doc: "Whether the model supports function/tool calling"
                         ],
                         temperature: [
                           type: :boolean,
                           default: true,
                           doc: "Whether the model supports temperature parameter"
                         ],
                         open_weights: [
                           type: :boolean,
                           default: false,
                           doc: "Whether the model weights are open source"
                         ],
                         knowledge: [
                           type: :string,
                           doc: "Knowledge cutoff date (YYYY-MM or YYYY-MM-DD format)"
                         ],
                         release_date: [
                           type: :string,
                           doc: "Model release date (YYYY-MM-DD format)"
                         ],
                         last_updated: [
                           type: :string,
                           doc: "Last update date (YYYY-MM-DD format)"
                         ]
                       )

  # Model limits metadata schema
  @limits_schema NimbleOptions.new!(
                   context: [
                     type: :pos_integer,
                     doc: "Maximum context window size in tokens"
                   ],
                   output: [
                     type: :pos_integer,
                     doc: "Maximum output tokens"
                   ],
                   rate_limit: [
                     type: :map,
                     doc: "Rate limiting configuration",
                     keys: [
                       requests_per_minute: [
                         type: :pos_integer,
                         doc: "Maximum requests per minute"
                       ],
                       tokens_per_minute: [
                         type: :pos_integer,
                         doc: "Maximum tokens per minute"
                       ],
                       requests_per_day: [
                         type: :pos_integer,
                         doc: "Maximum requests per day"
                       ]
                     ]
                   ]
                 )

  # Model cost metadata schema
  @costs_schema NimbleOptions.new!(
                  input: [
                    type: :float,
                    doc: "Cost per million input tokens"
                  ],
                  output: [
                    type: :float,
                    doc: "Cost per million output tokens"
                  ],
                  cache_read: [
                    type: :float,
                    doc: "Cost per million cached input tokens (for providers with caching)"
                  ],
                  cache_write: [
                    type: :float,
                    doc: "Cost per million tokens to write to cache"
                  ],
                  training: [
                    type: :float,
                    doc: "Cost per million training tokens (for fine-tuned models)"
                  ],
                  image: [
                    type: :float,
                    doc: "Cost per image (for image generation models)"
                  ],
                  audio: [
                    type: :float,
                    doc: "Cost per minute of audio (for audio models)"
                  ]
                )

  @doc """
  Returns the model capabilities schema.
  """
  def capabilities_schema, do: @capabilities_schema

  @doc """
  Returns the model limits schema.
  """
  def limits_schema, do: @limits_schema

  @doc """
  Returns the model costs schema.
  """
  def costs_schema, do: @costs_schema

  @doc """
  Validates model capabilities metadata.

  ## Examples

      iex> caps = %{id: "gpt-4", reasoning: true, tool_call: true}
      iex> ReqLLM.Provider.Metadata.validate_capabilities(caps)
      {:ok, %{id: "gpt-4", reasoning: true, tool_call: true, attachment: false, temperature: true, open_weights: false}}
  """
  def validate_capabilities(caps) do
    NimbleOptions.validate(caps, @capabilities_schema)
  end

  @doc """
  Validates model limits metadata.

  ## Examples

      iex> limits = %{context: 128_000, output: 4096}
      iex> ReqLLM.Provider.Metadata.validate_limits(limits)
      {:ok, %{context: 128_000, output: 4096}}
  """
  def validate_limits(limits) do
    NimbleOptions.validate(limits, @limits_schema)
  end

  @doc """
  Validates model costs metadata.

  ## Examples

      iex> costs = %{input: 30.0, output: 60.0}
      iex> ReqLLM.Provider.Metadata.validate_costs(costs)
      {:ok, %{input: 30.0, output: 60.0}}
  """
  def validate_costs(costs) do
    NimbleOptions.validate(costs, @costs_schema)
  end

  @doc """
  Returns all capability option keys.
  """
  def capability_keys do
    @capabilities_schema.schema |> Keyword.keys()
  end

  @doc """
  Returns all limit option keys.
  """
  def limit_keys do
    @limits_schema.schema |> Keyword.keys()
  end

  @doc """
  Returns all cost option keys.
  """
  def cost_keys do
    @costs_schema.schema |> Keyword.keys()
  end
end
