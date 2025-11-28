defmodule ReqLLM do
  @moduledoc """
  Main API facade for Req AI.

  Inspired by the Vercel AI SDK, provides a unified interface to AI providers with
  flexible model specifications, rich prompt support, configuration management,
  and structured data generation.

  ## Quick Start

      # Simple text generation using string format
      ReqLLM.generate_text("anthropic:claude-3-5-sonnet", "Hello world")
      #=> {:ok, "Hello! How can I assist you today?"}

      # Structured data generation with schema validation
      schema = [
        name: [type: :string, required: true],
        age: [type: :pos_integer, required: true]
      ]
      ReqLLM.generate_object("anthropic:claude-3-5-sonnet", "Generate a person", schema)
      #=> {:ok, %{name: "John Doe", age: 30}}

  ## Model Specifications

  Multiple formats supported for maximum flexibility:

      # String format: "provider:model"
      ReqLLM.generate_text("anthropic:claude-sonnet-4-5-20250929", messages)

      # Tuple format: {provider, options}
      ReqLLM.generate_text({:anthropic, "claude-3-5-sonnet", temperature: 0.7}, messages)

      # Model struct format
      {:ok, model} = ReqLLM.model("anthropic:claude-3-5-sonnet", temperature: 0.5)
      ReqLLM.generate_text(model, messages)

  ## Configuration

  ReqLLM loads API keys from standard sources in order of precedence:

  1. Per-request `:api_key` option
  2. Application config: `config :req_llm, :anthropic_api_key, "..."`
  3. System environment: `ANTHROPIC_API_KEY` (loaded from .env via dotenvy)

  The recommended approach is to use a .env file:

      # .env
      ANTHROPIC_API_KEY=sk-ant-...
      OPENAI_API_KEY=sk-...

  Keys are automatically loaded at startup via dotenvy.

  For programmatic key management:

      # Store keys (uses Application config)
      ReqLLM.put_key(:anthropic_api_key, "sk-ant-...")

      # Retrieve keys
      ReqLLM.get_key(:anthropic_api_key)
      ReqLLM.get_key("ANTHROPIC_API_KEY")

  ## Providers

  Built-in support for major AI providers:

  - **Anthropic**: Claude 3.5 Sonnet, Claude 3 Haiku, Claude 3 Opus

      # Access provider modules directly
      provider = ReqLLM.provider(:anthropic)
      provider.generate_text(model, messages, opts)
  """

  alias ReqLLM.{Embedding, Generation, Schema, Tool}

  # ===========================================================================
  # Configuration API
  # ===========================================================================

  @doc """
  Stores an API key in application configuration.

  Keys from .env files are automatically loaded via dotenvy at startup.
  This function is useful for programmatic key management in tests or at runtime.

  ## Parameters

    * `key` - The configuration key (atom)
    * `value` - The value to store

  ## Examples

      ReqLLM.put_key(:anthropic_api_key, "sk-ant-...")

  """
  @spec put_key(atom(), term()) :: :ok
  def put_key(key, value) when is_atom(key) do
    Application.put_env(:req_llm, key, value)
    :ok
  end

  def put_key(_key, _value) do
    raise ArgumentError, "put_key/2 expects an atom key like :anthropic_api_key"
  end

  @doc """
  Gets an API key from application config or system environment.

  Keys from .env files are automatically loaded via dotenvy at startup.

  ## Parameters

    * `key` - The configuration key (atom or string)

  ## Examples

      ReqLLM.get_key(:anthropic_api_key)
      ReqLLM.get_key("ANTHROPIC_API_KEY")  # Auto-loaded from .env

  """
  @spec get_key(atom() | String.t()) :: String.t() | nil
  def get_key(key) when is_atom(key), do: Application.get_env(:req_llm, key)
  def get_key(key) when is_binary(key), do: System.get_env(key)

  @doc """
  Creates a context from a list of messages, a single message struct, or a string.

  ## Parameters

    * `messages` - List of Message structs, a single Message struct, or a string

  ## Examples

      messages = [
        ReqLLM.Context.system("You are helpful"),
        ReqLLM.Context.user("Hello!")
      ]
      ctx = ReqLLM.context(messages)
      # Now you can use Enum functions on the context
      user_msgs = ctx |> Enum.filter(&(&1.role == :user))

      # Single message struct
      ctx = ReqLLM.context(ReqLLM.Context.user("Hello!"))

      # String prompt
      ctx = ReqLLM.context("Hello!")

  """
  @spec context([struct()] | struct() | String.t()) :: ReqLLM.Context.t()
  def context(message_list) when is_list(message_list) do
    ReqLLM.Context.new(message_list)
  end

  def context(%ReqLLM.Message{} = message) do
    ReqLLM.Context.new([message])
  end

  def context(prompt) when is_binary(prompt) do
    ReqLLM.Context.new([ReqLLM.Context.user(prompt)])
  end

  @doc """
  Gets a provider module from the registry.

  ## Parameters

    * `provider` - Provider identifier (atom)

  ## Examples

      ReqLLM.provider(:anthropic)
      #=> {:ok, ReqLLM.Providers.Anthropic}

      ReqLLM.provider(:unknown)
      #=> {:error, %ReqLLM.Error.Invalid.Provider{provider: :unknown}}

  """
  @spec provider(atom()) ::
          {:ok, module()}
          | {:error,
             ReqLLM.Error.Invalid.Provider.t() | ReqLLM.Error.Invalid.Provider.NotImplemented.t()}
  def provider(provider) when is_atom(provider) do
    ReqLLM.Providers.get(provider)
  end

  @doc """
  Creates a model struct from various specifications.

  ## Parameters

    * `model_spec` - Model specification in various formats:
      - String format: `"anthropic:claude-3-sonnet"`
      - Tuple format: `{:anthropic, "claude-3-sonnet", temperature: 0.7}`
      - Model struct: `%LLMDB.Model{}`

  ## Examples

      ReqLLM.model("anthropic:claude-3-sonnet")
      #=> {:ok, %LLMDB.Model{provider: :anthropic, model: "claude-3-sonnet"}}

      ReqLLM.model({:anthropic, "claude-3-sonnet", temperature: 0.5})
      #=> {:ok, %LLMDB.Model{provider: :anthropic, model: "claude-3-sonnet", temperature: 0.5}}

  """
  @spec model(String.t() | {atom(), String.t(), keyword()} | {atom(), keyword()} | struct()) ::
          {:ok, struct()} | {:error, term()}
  def model(%LLMDB.Model{} = model), do: {:ok, model}

  def model({provider, model_id, _opts}) when is_atom(provider) and is_binary(model_id) do
    LLMDB.model(provider, model_id)
  end

  def model({provider, kw}) when is_atom(provider) and is_list(kw) do
    case kw[:id] || kw[:model] do
      id when is_binary(id) -> LLMDB.model(provider, id)
      _ -> {:error, ReqLLM.Error.Invalid.Parameter.exception(parameter: :model, value: kw)}
    end
  end

  def model(spec) when is_binary(spec), do: LLMDB.model(spec)

  def model(other) do
    {:error,
     ReqLLM.Error.Validation.Error.exception(message: "Invalid model spec: #{inspect(other)}")}
  end

  # ===========================================================================
  # Text Generation API - Delegated to ReqLLM.Generation
  # ===========================================================================

  @doc """
  Generates text using an AI model with full response metadata.

  Returns a canonical ReqLLM.Response which includes usage data, context, and metadata.
  For simple text-only results, use `generate_text!/3`.

  ## Parameters

    * `model_spec` - Model specification in various formats
    * `messages` - Text prompt or list of messages
    * `opts` - Additional options (keyword list)

  ## Options

    * `:temperature` - Control randomness in responses (0.0 to 2.0)
    * `:max_tokens` - Limit the length of the response
    * `:top_p` - Nucleus sampling parameter
    * `:presence_penalty` - Penalize new tokens based on presence
    * `:frequency_penalty` - Penalize new tokens based on frequency
    * `:tools` - List of tool definitions
    * `:tool_choice` - Tool choice strategy
    * `:system_prompt` - System prompt to prepend
    * `:provider_options` - Provider-specific options

  ## Examples

      {:ok, response} = ReqLLM.generate_text("anthropic:claude-3-sonnet", "Hello world")
      ReqLLM.Response.text(response)
      #=> "Hello! How can I assist you today?"

      # Access usage metadata
      ReqLLM.Response.usage(response)
      #=> %{input_tokens: 10, output_tokens: 8}

  """
  defdelegate generate_text(model_spec, messages, opts \\ []), to: Generation

  @doc """
  Generates text using an AI model, returning only the text content.

  This is a convenience function that extracts just the text from the response.
  For access to usage metadata and other response data, use `generate_text/3`.
  Raises on error.

  ## Parameters

  Same as `generate_text/3`.

  ## Examples

      ReqLLM.generate_text!("anthropic:claude-3-sonnet", "Hello world")
      #=> "Hello! How can I assist you today?"

  """
  defdelegate generate_text!(model_spec, messages, opts \\ []), to: Generation

  @doc """
  Streams text generation using an AI model with concurrent metadata collection.

  Returns a `ReqLLM.StreamResponse` that provides both real-time token streaming
  and asynchronous metadata collection (usage, finish_reason). This enables
  zero-latency content delivery while collecting billing/usage data concurrently.

  The streaming implementation uses Finch directly for production-grade performance
  with HTTP/2 multiplexing and automatic connection pooling.

  ## Parameters

  Same as `generate_text/3`.

  ## Returns

    * `{:ok, stream_response}` - StreamResponse with stream and metadata task
    * `{:error, reason}` - Request failed or invalid parameters

  ## Examples

      # Real-time streaming
      {:ok, response} = ReqLLM.stream_text("anthropic:claude-3-sonnet", "Tell me a story")
      response
      |> ReqLLM.StreamResponse.tokens()
      |> Stream.each(&IO.write/1)
      |> Stream.run()

      # Concurrent metadata collection
      usage = ReqLLM.StreamResponse.usage(response)
      #=> %{input_tokens: 15, output_tokens: 42, total_cost: 0.087}

      # Simple text collection
      text = ReqLLM.StreamResponse.text(response)

      # Backward compatibility
      {:ok, legacy_response} = ReqLLM.StreamResponse.to_response(response)

  ## StreamResponse Fields

    * `stream` - Lazy enumerable of `StreamChunk` structs for real-time consumption
    * `metadata_handle` - Concurrent handle collecting usage and finish_reason
    * `cancel` - Function to terminate streaming and cleanup resources
    * `model` - Model specification that generated this response
    * `context` - Updated conversation context including assistant's response

  ## Performance Notes

  The stream is lazy and supports backpressure. Metadata collection happens
  concurrently and won't block token delivery. Use cancellation for early
  termination to free resources.

  """
  defdelegate stream_text(model_spec, messages, opts \\ []), to: Generation

  @doc """
  **DEPRECATED**: This function will be removed in a future version.

  The streaming API has been redesigned to return a composite `StreamResponse` struct
  that provides both the stream and metadata. Use `stream_text/3` instead:

      {:ok, response} = ReqLLM.stream_text(model, messages)
      response.stream |> Enum.each(&IO.write/1)

  For simple text extraction, use:

      text = ReqLLM.StreamResponse.text(response)

  ## Legacy Behavior

  This function currently returns `:ok` and logs a deprecation warning.
  It will be formally removed in the next major version.
  """
  @deprecated "Use stream_text/3 with StreamResponse instead"
  def stream_text!(_model_spec, _messages, _opts \\ []) do
    IO.warn("""
    ReqLLM.stream_text!/3 is deprecated and will be removed in a future version.

    Please migrate to the new streaming API:

    Old code:
        ReqLLM.stream_text!(model, messages) |> Enum.each(&IO.write/1)

    New code:
        {:ok, response} = ReqLLM.stream_text(model, messages)
        response.stream |> Enum.each(&IO.write/1)

    Or for simple text extraction:
        text = ReqLLM.StreamResponse.text(response)
    """)

    :ok
  end

  @doc """
  Generates structured data using an AI model with schema validation.

  Equivalent to Vercel AI SDK's `generateObject()` function, this method
  generates structured data according to a provided schema and validates
  the output against that schema.

  ## Parameters

    * `model_spec` - Model specification in various formats
    * `messages` - Text prompt or list of messages
    * `schema` - Schema definition for structured output (NimbleOptions schema or JSON Schema map)
    * `opts` - Additional options (keyword list)

  ## Options

    * `:temperature` - Control randomness in responses (0.0 to 2.0)
    * `:max_tokens` - Limit the length of the response
    * `:provider_options` - Provider-specific options

  ## Examples

      # Generate a structured object
      schema = [
        name: [type: :string, required: true],
        age: [type: :pos_integer, required: true]
      ]
      {:ok, object} = ReqLLM.generate_object("anthropic:claude-3-sonnet", "Generate a person", schema)
      #=> {:ok, %{name: "John Doe", age: 30}}

      # Generate an array of objects (requires JSON Schema-capable provider like OpenAI)
      person_schema = ReqLLM.Schema.to_json([
        name: [type: :string, required: true],
        age: [type: :pos_integer, required: true]
      ])

      array_schema = %{"type" => "array", "items" => person_schema}

      {:ok, response} = ReqLLM.generate_object(
        "openai:gpt-4o",
        "Generate 3 heroes",
        array_schema
      )
      # Note: Array outputs currently require manual extraction from the response

      # Recommended: Use Zoi for cleaner array schema definition
      person = Zoi.object(%{
        name: Zoi.string(),
        age: Zoi.number()
      })

      array_schema = Zoi.array(person) |> ReqLLM.Schema.to_json()

      {:ok, response} = ReqLLM.generate_object(
        "openai:gpt-4o",
        "Generate 3 heroes",
        array_schema
      )

  > **Note**: Top-level non-object outputs (arrays, enums) require raw JSON Schema
  > and are only supported by providers with native JSON Schema capabilities (e.g., OpenAI).
  > Most providers only support object-type schemas. For cleaner array schema definitions,
  > consider using the Zoi library as shown above.

  """
  defdelegate generate_object(model_spec, messages, schema, opts \\ []), to: Generation

  @doc """
  Generates structured data using an AI model, returning only the object content.

  This is a convenience function that extracts just the object from the response.
  For access to usage metadata and other response data, use `generate_object/4`.

  ## Parameters

  Same as `generate_object/4`.

  ## Examples

      ReqLLM.generate_object!("anthropic:claude-3-sonnet", "Generate a person", schema)
      #=> %{name: "John Doe", age: 30}

  """
  defdelegate generate_object!(model_spec, messages, schema, opts \\ []), to: Generation

  @doc """
  Streams structured data generation using an AI model with schema validation.

  Equivalent to Vercel AI SDK's `streamObject()` function, this method
  streams structured data generation according to a provided schema.

  ## Parameters

    * `model_spec` - Model specification in various formats
    * `messages` - Text prompt or list of messages
    * `schema` - Schema definition for structured output
    * `opts` - Additional options (keyword list)

  ## Options

    Same as `generate_object/4`.

  ## Examples

      # Stream structured object generation
      schema = [
        name: [type: :string, required: true],
        description: [type: :string, required: true]
      ]
      {:ok, stream} = ReqLLM.stream_object("anthropic:claude-3-sonnet", "Generate a character", schema)
      stream |> Enum.each(&IO.inspect/1)

  """
  defdelegate stream_object(model_spec, messages, schema, opts \\ []), to: Generation

  @doc """
  **DEPRECATED**: This function will be removed in a future version.

  The streaming API has been redesigned to return a composite `StreamResponse` struct
  that provides both the stream and metadata. Use `stream_object/4` instead:

      {:ok, response} = ReqLLM.stream_object(model, messages, schema)
      response.stream |> Enum.each(&IO.inspect/1)

  For simple object extraction, use:

      object = ReqLLM.StreamResponse.object(response)

  ## Legacy Parameters

  Same as `stream_object/4`.

  ## Legacy Examples

      ReqLLM.stream_object!("anthropic:claude-3-sonnet", "Generate a character", schema)
      |> Enum.each(&IO.inspect/1)

  """
  @deprecated "Use stream_object/4 with StreamResponse instead"
  def stream_object!(_model_spec, _messages, _schema, _opts \\ []) do
    IO.warn("""
    ReqLLM.stream_object!/4 is deprecated and will be removed in a future version.

    Please migrate to the new streaming API:

    Old code:
        ReqLLM.stream_object!(model, messages, schema) |> Enum.each(&IO.inspect/1)

    New code:
        {:ok, response} = ReqLLM.stream_object(model, messages, schema)
        response.stream |> Enum.each(&IO.inspect/1)

    Or for simple object extraction:
        object = ReqLLM.StreamResponse.object(response)
    """)

    :ok
  end

  # ===========================================================================
  # Embedding API - Delegated to ReqLLM.Embedding
  # ===========================================================================

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
    * `:provider_options` - Provider-specific options

  ## Examples

      # Single text input
      {:ok, embedding} = ReqLLM.embed("openai:text-embedding-3-small", "Hello world")
      #=> {:ok, [0.1, -0.2, 0.3, ...]}

      # Multiple text inputs
      {:ok, embeddings} = ReqLLM.embed(
        "openai:text-embedding-3-small",
        ["Hello", "World"]
      )
      #=> {:ok, [[0.1, -0.2, ...], [0.3, 0.4, ...]]}

  """
  defdelegate embed(model_spec, input, opts \\ []), to: Embedding

  # ===========================================================================
  # Vercel AI SDK Utility API - Delegated to ReqLLM.Utils
  # ===========================================================================

  @doc """
  Creates a Tool struct for AI model function calling.

  Equivalent to Vercel AI SDK's `tool()` helper, providing type-safe tool
  definitions with parameter validation. This is a convenience function
  for creating ReqLLM.Tool structs.

  ## Parameters

    * `opts` - Tool definition options (keyword list)

  ## Options

    * `:name` - Tool name (required, must be valid identifier)
    * `:description` - Tool description for AI model (required)
    * `:parameters` - Parameter schema as NimbleOptions keyword list (optional)
    * `:callback` - Callback function or MFA tuple (required)

  ## Examples

      # Simple tool with no parameters
      tool = ReqLLM.tool(
        name: "get_time",
        description: "Get the current time",
        callback: fn _args -> {:ok, DateTime.utc_now()} end
      )

      # Tool with parameters
      weather_tool = ReqLLM.tool(
        name: "get_weather",
        description: "Get current weather for a location",
        parameters: [
          location: [type: :string, required: true, doc: "City name"],
          units: [type: :string, default: "metric", doc: "Temperature units"]
        ],
        callback: {WeatherAPI, :fetch_weather}
      )

  """
  @spec tool(keyword()) :: Tool.t()
  def tool(opts) when is_list(opts) do
    Tool.new!(opts)
  end

  @doc """
  Creates a JSON schema object compatible with ReqLLM.

  Equivalent to Vercel AI SDK's `jsonSchema()` helper, this function
  creates schema objects for structured data generation and validation.

  ## Parameters

    * `schema` - NimbleOptions schema definition (keyword list)
    * `opts` - Additional options (optional)

  ## Options

    * `:validate` - Custom validation function (optional)

  ## Examples

      # Basic schema
      schema = ReqLLM.json_schema([
        name: [type: :string, required: true, doc: "User name"],
        age: [type: :integer, doc: "User age"]
      ])

      # Schema with custom validation
      schema = ReqLLM.json_schema(
        [email: [type: :string, required: true]],
        validate: fn value ->
          if String.contains?(value["email"], "@") do
            {:ok, value}
          else
            {:error, "Invalid email format"}
          end
        end
      )

  """
  @spec json_schema(keyword(), keyword()) :: map()
  def json_schema(schema, opts \\ []) when is_list(schema) and is_list(opts) do
    json_schema = Schema.to_json(schema)

    case opts[:validate] do
      nil ->
        json_schema

      validator when is_function(validator, 1) ->
        Map.put(json_schema, :validate, validator)
    end
  end

  @doc """
  Calculates cosine similarity between two embedding vectors.

  Equivalent to Vercel AI SDK's `cosineSimilarity()` function.
  Returns a similarity score between -1 and 1, where:
  - 1.0 indicates identical vectors (maximum similarity)
  - 0.0 indicates orthogonal vectors (no similarity)
  - -1.0 indicates opposite vectors (maximum dissimilarity)

  ## Parameters

    * `embedding_a` - First embedding vector (list of numbers)
    * `embedding_b` - Second embedding vector (list of numbers)

  ## Examples

      # Identical vectors
      ReqLLM.cosine_similarity([1.0, 0.0, 0.0], [1.0, 0.0, 0.0])
      #=> 1.0

      # Orthogonal vectors
      ReqLLM.cosine_similarity([1.0, 0.0], [0.0, 1.0])
      #=> 0.0

      # Opposite vectors
      ReqLLM.cosine_similarity([1.0, 0.0], [-1.0, 0.0])
      #=> -1.0

      # Similar vectors
      ReqLLM.cosine_similarity([0.5, 0.8, 0.3], [0.6, 0.7, 0.4])
      #=> 0.9487...

  """
  @spec cosine_similarity([number()], [number()]) :: float()
  def cosine_similarity(embedding_a, embedding_b)
      when is_list(embedding_a) and is_list(embedding_b) do
    if length(embedding_a) != length(embedding_b) do
      raise ArgumentError, "Embedding vectors must have the same length"
    end

    if embedding_a == [] do
      0.0
    else
      dot_product =
        embedding_a
        |> Enum.zip(embedding_b)
        |> Enum.reduce(0, fn {a, b}, acc -> acc + a * b end)

      magnitude_a = :math.sqrt(Enum.reduce(embedding_a, 0, fn x, acc -> acc + x * x end))
      magnitude_b = :math.sqrt(Enum.reduce(embedding_b, 0, fn x, acc -> acc + x * x end))

      if magnitude_a == 0 or magnitude_b == 0 do
        0.0
      else
        dot_product / (magnitude_a * magnitude_b)
      end
    end
  end
end
