defmodule ReqLLM.Provider do
  @moduledoc """
  Behavior for LLM provider implementations.

  Providers implement this behavior to handle model-specific request configuration,
  body encoding, response parsing, and usage extraction. Each provider is a Req plugin
  that uses the standard Req request/response pipeline.

  ## Provider Responsibilities

  - **Request Preparation**: Configure operation-specific requests via `prepare_request/4`
  - **Request Configuration**: Set headers, base URLs, authentication via `attach/3`
  - **Body Encoding**: Transform Context to provider-specific JSON via `encode_body/1`
  - **Response Parsing**: Decode API responses via `decode_response/1`
  - **Usage Extraction**: Parse usage/cost data via `extract_usage/2` (optional)
  - **Streaming Configuration**: Build complete streaming requests via `attach_stream/4` (recommended)

  ## Implementation Pattern

  Providers use `use ReqLLM.Provider` to define their configuration and implement
  the required callbacks as Req pipeline steps.

  ## Examples

      defmodule MyProvider do
        use ReqLLM.Provider,
          id: :myprovider,
          default_base_url: "https://api.example.com/v1",
          default_env_key: "MYPROVIDER_API_KEY"

        @impl ReqLLM.Provider
        def prepare_request(operation, model, messages, opts) do
          with {:ok, request} <- Req.new(base_url: base_url()),
               request <- add_auth_headers(request),
               request <- add_operation_specific_config(request, operation) do
            {:ok, request}
          end
        end

        @impl ReqLLM.Provider
        def attach(request, model, opts) do
          request
          |> add_auth_headers()
          |> Req.Request.append_request_steps(llm_encode_body: &encode_body/1)
          |> Req.Request.append_response_steps(llm_decode_response: &decode_response/1)
        end

        @impl ReqLLM.Provider
        def attach_stream(model, context, opts, _finch_name) do
          operation = Keyword.get(opts, :operation, :chat)
          processed_opts = ReqLLM.Provider.Options.process!(__MODULE__, operation, model, Keyword.merge(opts, stream: true, context: context))
          
          with {:ok, req} <- prepare_request(operation, model, context, processed_opts),
               req <- attach(req, model, processed_opts),
               {req, _resp} <- encode_body(req) do
            url = URI.to_string(req.url)
            headers = req.headers |> Enum.map(fn {k, [v | _]} -> {k, v} end)
            body = req.body
            
            finch_request = Finch.build(:post, url, headers, body)
            {:ok, finch_request}
          end
        end

        def encode_body(request) do
          # Transform request.options[:context] to provider JSON
        end

        def decode_response({req, resp}) do
          # Parse response body and return {req, updated_resp}
        end
      end

  """

  @type operation :: :chat | :embed | :moderate | atom()

  @doc """
  Prepares a new request for a specific operation type.

  This callback creates and configures a new Req request from scratch for the
  given operation, model, and parameters. It should handle all operation-specific
  configuration including authentication, headers, and base URLs.

  ## Parameters

    * `operation` - The type of operation (:chat, :embed, :moderate, etc.)
    * `model` - The ReqLLM.Model struct or model identifier
    * `data` - Operation-specific data (messages for chat, text for embed, etc.)
    * `opts` - Additional options (stream, temperature, etc.)
      - For `:object` operations, opts includes `:compiled_schema` with the schema definition

  ## Returns

    * `{:ok, Req.Request.t()}` - Successfully configured request
    * `{:error, Exception.t()}` - Configuration error (using Splode exception types)

  ## Examples

      # Chat operation
      def prepare_request(:chat, model, messages, opts) do
        {:ok, request} = Req.new(base_url: "https://api.anthropic.com")
        request = add_auth_headers(request)
        request = put_in(request.options[:json], %{
          model: model.name,
          messages: messages,
          stream: opts[:stream] || false
        })
        {:ok, request}
      end

      # Object generation with schema
      def prepare_request(:object, model, context, opts) do
        compiled_schema = Keyword.fetch!(opts, :compiled_schema)
        # Use compiled_schema.schema for tool definitions
        prepare_request(:chat, model, context, updated_opts)
      end

      # Embedding operation  
      def prepare_request(:embed, model, text, opts) do
        {:ok, request} = Req.new(base_url: "https://api.anthropic.com/v1/embed")
        {:ok, add_auth_headers(request)}
      end

  """
  @callback prepare_request(
              operation(),
              LLMDB.Model.t() | term(),
              term(),
              keyword()
            ) :: {:ok, Req.Request.t()} | {:error, Exception.t()}

  @doc """
  Attaches provider-specific configuration to a Req request.

  This callback configures the request for the specific provider by setting up
  authentication, base URLs, and registering request/response pipeline steps.

  ## Parameters

    * `request` - The Req.Request struct to configure
    * `model` - The ReqLLM.Model struct with model specification
    * `opts` - Additional options (messages, tools, streaming, etc.)

  ## Returns

    * `Req.Request.t()` - The configured request with pipeline steps attached

  """
  @callback attach(Req.Request.t(), LLMDB.Model.t(), keyword()) :: Req.Request.t()

  @doc """
  Encodes request body for provider API.

  This callback is typically used as a Req request step that transforms the
  request options (especially `:context`) into the provider-specific JSON body.

  ## Parameters

    * `request` - The Req.Request struct with options to encode

  ## Returns

    * `Req.Request.t()` - Request with encoded body

  """
  @callback encode_body(Req.Request.t()) :: Req.Request.t()

  @doc """
  Decodes provider API response.

  This callback is typically used as a Req response step that transforms the
  raw API response into a standardized format for ReqLLM consumption.

  ## Parameters

    * `request_response` - Tuple of {Req.Request.t(), Req.Response.t()}

  ## Returns

    * `{Req.Request.t(), Req.Response.t() | Exception.t()}` - Decoded response or error

  """
  @callback decode_response({Req.Request.t(), Req.Response.t()}) ::
              {Req.Request.t(), Req.Response.t() | Exception.t()}

  @doc """
  Extracts usage/cost metadata from response body (optional).

  This callback is called by `ReqLLM.Step.Usage` if the provider module
  exports this function. It allows custom usage extraction beyond the
  standard formats.

  ## Parameters

    * `body` - The response body (typically a map)
    * `model` - The ReqLLM.Model struct (may be nil)

  ## Returns

    * `{:ok, map()}` - Usage metadata map with keys like `:input`, `:output`
    * `{:error, term()}` - Extraction error

  """
  @callback extract_usage(term(), LLMDB.Model.t() | nil) ::
              {:ok, map()} | {:error, term()}

  @doc """
  Normalizes a model ID for metadata lookup (optional).

  This callback allows providers to normalize model identifiers before looking up
  metadata in the provider's model registry. Useful when providers have multiple
  aliases or formats for the same underlying model (e.g., regional inference profiles).

  ## Parameters

    * `model_id` - The model identifier string to normalize

  ## Returns

    * `String.t()` - The normalized model ID for metadata lookup

  ## Examples

      # AWS Bedrock inference profiles - strip region prefix for metadata lookup
      def normalize_model_id("us.anthropic.claude-3-sonnet"), do: "anthropic.claude-3-sonnet"
      def normalize_model_id("eu.meta.llama-3"), do: "meta.llama-3"
      def normalize_model_id(model_id), do: model_id

  If this callback is not implemented, the model ID is used as-is for metadata lookup.
  """
  @callback normalize_model_id(String.t()) :: String.t()

  @doc """
  Translates canonical options to provider-specific parameters (optional).

  This callback allows providers to modify option keys and values before
  they are sent to the API. Useful for handling parameter name differences
  and model-specific restrictions.

  ## Parameters

    * `operation` - The operation type (:chat, :embed, etc.)
    * `model` - The ReqLLM.Model struct
    * `opts` - Canonical options after validation

  ## Returns

    * `{translated_opts, warnings}` - Tuple of translated options and warning messages

  ## Examples

      # OpenAI o1 models need max_completion_tokens instead of max_tokens
      def translate_options(:chat, %Model{model: <<"o1", _::binary>>}, opts) do
        {opts, warnings} = translate_max_tokens(opts)
        {opts, warnings}
      end

      # Drop unsupported parameters with warnings
      def translate_options(:chat, %Model{model: <<"o1", _::binary>>}, opts) do
        results = [
          translate_rename(opts, :max_tokens, :max_completion_tokens),
          translate_drop(opts, :temperature, "OpenAI o1 models do not support :temperature")
        ]
        translate_combine_warnings(results)
      end

  """
  @callback translate_options(operation(), LLMDB.Model.t(), keyword()) ::
              {keyword(), [String.t()]}

  @doc """
  Returns the default environment variable name for API authentication.

  This callback provides the fallback environment variable name when the
  provider metadata doesn't specify one. Generated automatically by the
  DSL if `default_env_key` is provided.

  ## Returns

    * `String.t()` - Environment variable name (e.g., "ANTHROPIC_API_KEY")

  """
  @callback default_env_key() :: String.t()

  @doc """
  Decode provider streaming event to list of StreamChunk structs for streaming responses.

  This is called by ReqLLM.StreamServer during real-time streaming to convert
  provider-specific streaming events into canonical StreamChunk structures. For terminal
  events (like "[DONE]"), providers should return metadata chunks with usage
  information and finish reasons.

  Different providers use different streaming protocols:
  - **OpenAI, Anthropic, Google**: Server-Sent Events (SSE) - `event` is typically `%{data: ...}`
  - **AWS Bedrock**: AWS EventStream (binary) - `event` is the decoded JSON payload

  ## Parameters

    * `event` - The streaming event data (typically a map)
    * `model` - The ReqLLM.Model struct

  ## Returns

    * `[ReqLLM.StreamChunk.t()]` - List of decoded stream chunks (may be empty)

  ## Terminal Metadata

  For terminal streaming events, providers should return metadata chunks:

      # Final usage and completion metadata
      ReqLLM.StreamChunk.meta(%{
        usage: %{input_tokens: 10, output_tokens: 25},
        finish_reason: :stop,
        terminal?: true
      })

  ## Examples

      def decode_stream_event(%{data: %{"choices" => [%{"delta" => delta}]}}, _model) do
        case delta do
          %{"content" => content} when content != "" ->
            [ReqLLM.StreamChunk.text(content)]
          _ ->
            []
        end
      end

      # Handle terminal [DONE] event
      def decode_stream_event(%{data: "[DONE]"}, _model) do
        # Provider should have accumulated usage data
        [ReqLLM.StreamChunk.meta(%{terminal?: true})]
      end

  """
  @callback decode_stream_event(map(), LLMDB.Model.t()) :: [ReqLLM.StreamChunk.t()]

  @doc """
  Initialize provider-specific streaming state (optional).

  This callback allows providers to set up stateful transformations for streaming
  responses. The returned state will be threaded through `decode_stream_event/3` calls
  and passed to `flush_stream_state/2` when the stream ends.

  ## Parameters

    * `model` - The ReqLLM.Model struct

  ## Returns

  Provider-specific state of any type. Commonly a map with transformation state.

  ## Examples

      # Initialize state for <think> tag parsing
      def init_stream_state(_model) do
        %{mode: :text, buffer: ""}
      end

  """
  @callback init_stream_state(LLMDB.Model.t()) :: any()

  @doc """
  Decode streaming event with provider-specific state (optional, alternative to decode_stream_event/2).

  This stateful variant of `decode_stream_event/2` allows providers to maintain state
  across streaming chunks. Use this when your provider needs to accumulate data or
  track parsing state across multiple streaming events.

  If both `decode_stream_event/3` and `decode_stream_event/2` are defined, the 3-arity
  version takes precedence during streaming.

  ## Parameters

    * `event` - Parsed streaming event map (SSE events have `:event`, `:data`, etc.)
    * `model` - The ReqLLM.Model struct
    * `provider_state` - Current provider state from `init_stream_state/1`

  ## Returns

  `{chunks, new_provider_state}` where:
    * `chunks` - List of StreamChunk structs to emit
    * `new_provider_state` - Updated state for next event

  ## Examples

      def decode_stream_event(event, model, state) do
        chunks = ReqLLM.Provider.Defaults.default_decode_stream_event(event, model)
        
        Enum.reduce(chunks, {[], state}, fn chunk, {acc, st} ->
          case chunk.type do
            :content ->
              {emitted, new_st} = transform_content(st, chunk.text)
              {acc ++ emitted, new_st}
            _ ->
              {acc ++ [chunk], st}
          end
        end)
      end

  """
  @callback decode_stream_event(map(), LLMDB.Model.t(), any()) ::
              {[ReqLLM.StreamChunk.t()], any()}

  @doc """
  Flush buffered provider state when stream ends (optional).

  This callback is invoked when the stream completes, allowing providers to emit
  any buffered content that hasn't been sent yet. This is useful for stateful
  transformations that may hold partial data waiting for completion signals.

  ## Parameters

    * `model` - The ReqLLM.Model struct
    * `provider_state` - Final provider state from last `decode_stream_event/3`

  ## Returns

  `{chunks, new_provider_state}` where:
    * `chunks` - List of final StreamChunk structs to emit
    * `new_provider_state` - Updated state (often with buffer cleared)

  ## Examples

      def flush_stream_state(_model, %{buffer: ""} = state) do
        {[], state}
      end

      def flush_stream_state(_model, %{mode: :thinking, buffer: text} = state) do
        {[ReqLLM.StreamChunk.thinking(text)], %{state | buffer: ""}}
      end

  """
  @callback flush_stream_state(LLMDB.Model.t(), any()) ::
              {[ReqLLM.StreamChunk.t()], any()}

  @doc """
  Parse raw binary stream protocol data into events.

  This callback allows providers to implement custom streaming protocols (SSE, AWS Event Stream,
  etc.) while maintaining a consistent interface. The default implementation uses SSE parsing.

  ## Parameters

    * `chunk` - Raw binary chunk from the HTTP stream
    * `buffer` - Accumulated buffer from previous incomplete chunks

  ## Returns

    * `{:ok, events, rest}` - Successfully parsed events with remaining buffer data
    * `{:incomplete, buffer}` - Need more data, return the accumulated buffer
    * `{:error, reason}` - Parse error

  ## Examples

      # Default SSE implementation (provided automatically)
      def parse_stream_protocol(chunk, buffer) do
        data = buffer <> chunk
        {events, new_buffer} = ReqLLM.Streaming.SSE.accumulate_and_parse(data, "")
        {:ok, events, new_buffer}
      end

      # Custom binary protocol (e.g., AWS Event Stream)
      def parse_stream_protocol(chunk, buffer) do
        data = buffer <> chunk
        case ReqLLM.AWSEventStream.parse_binary(data) do
          {:ok, events, rest} -> {:ok, events, rest}
          {:incomplete, data} -> {:incomplete, data}
          {:error, reason} -> {:error, reason}
        end
      end

  """
  @callback parse_stream_protocol(binary(), binary()) ::
              {:ok, [map()], binary()} | {:incomplete, binary()} | {:error, term()}

  @doc """
  Build complete Finch request for streaming operations.

  This callback creates a complete Finch.Request struct for streaming operations,
  allowing providers to specify their streaming endpoint, headers, and request body
  format. This consolidates streaming request preparation into a single callback.

  ## Parameters

    * `model` - The ReqLLM.Model struct
    * `context` - The Context with messages to stream
    * `opts` - Additional options (temperature, max_tokens, etc.)
    * `finch_name` - Finch process name for connection pooling

  ## Returns

    * `{:ok, Finch.Request.t()}` - Successfully built streaming request
    * `{:error, Exception.t()}` - Request building error

  ## Examples

      def attach_stream(model, context, opts, _finch_name) do
        url = "https://api.openai.com/v1/chat/completions"
        api_key = ReqLLM.Keys.get!(model, opts)
        headers = [
          {"Authorization", "Bearer " <> api_key},
          {"Content-Type", "application/json"}
        ]
        
        body = Jason.encode!(%{
          model: model.id,
          messages: encode_messages(context.messages),
          stream: true
        })
        
        request = Finch.build(:post, url, headers, body)
        {:ok, request}
      end

      # Anthropic with different endpoint and headers
      def attach_stream(model, context, opts, _finch_name) do
        url = "https://api.anthropic.com/v1/messages"
        api_key = ReqLLM.Keys.get!(model, opts)
        headers = [
          {"Authorization", "Bearer " <> api_key},
          {"Content-Type", "application/json"},
          {"anthropic-version", "2023-06-01"}
        ]
        
        body = Jason.encode!(%{
          model: model.id,
          messages: encode_anthropic_messages(context),
          stream: true
        })
        
        request = Finch.build(:post, url, headers, body)
        {:ok, request}
      end

  """
  @callback attach_stream(
              LLMDB.Model.t(),
              ReqLLM.Context.t(),
              keyword(),
              atom()
            ) :: {:ok, Finch.Request.t()} | {:error, Exception.t()}

  @doc """
  Returns thinking/reasoning constraints for models with extended thinking capability.

  Some providers (e.g., AWS Bedrock, Google Vertex AI) have platform-specific requirements
  when extended thinking is enabled:
  - Fixed temperature value (typically 1.0)
  - Minimum max_tokens to accommodate thinking budget

  Returns a map with:
  - `:required_temperature` - Temperature that must be used (float)
  - `:min_max_tokens` - Minimum max_tokens value (integer)

  Returns `:none` if no special constraints apply.

  ## Examples

      # Provider with thinking constraints
      def thinking_constraints do
        %{required_temperature: 1.0, min_max_tokens: 4001}
      end

      # Provider without thinking constraints
      def thinking_constraints, do: :none

  """
  @callback thinking_constraints() ::
              %{required_temperature: float(), min_max_tokens: pos_integer()} | :none

  @doc """
  Checks if an exception indicates missing credentials for this provider.

  This optional callback allows providers to identify credential-related errors
  so the fixture system can fall back to existing fixtures during recording when
  credentials are unavailable.

  ## Parameters

    * `exception` - The exception to check

  ## Returns

    * `true` - Exception indicates missing credentials
    * `false` - Exception is not credential-related

  ## Examples

      # Google provider checking for missing API key
      def credential_missing?(%ReqLLM.Error.Invalid.Parameter{parameter: param}) do
        String.contains?(param, "api_key") and
          String.contains?(param, "GOOGLE_API_KEY")
      end
      def credential_missing?(_), do: false
  """
  @callback credential_missing?(Exception.t()) :: boolean()

  @optional_callbacks [
    normalize_model_id: 1,
    extract_usage: 2,
    default_env_key: 0,
    translate_options: 3,
    decode_stream_event: 2,
    decode_stream_event: 3,
    init_stream_state: 1,
    flush_stream_state: 2,
    parse_stream_protocol: 2,
    attach_stream: 4,
    thinking_constraints: 0,
    credential_missing?: 1
  ]

  defmacro __before_compile__(_env) do
    quote do
      def provider_schema do
        schema = @provider_schema
        NimbleOptions.new!(schema)
      end

      def supported_provider_options do
        schema = @provider_schema
        Keyword.keys(schema)
      end

      def provider_extended_generation_schema do
        base_schema = ReqLLM.Provider.Options.generation_schema().schema
        provider_specific = @provider_schema

        merged_schema = Keyword.merge(base_schema, provider_specific)
        NimbleOptions.new!(merged_schema)
      end
    end
  end

  defmacro __using__(opts) do
    provider_id = Keyword.fetch!(opts, :id)
    default_base_url = Keyword.fetch!(opts, :default_base_url)
    default_env_key = Keyword.get(opts, :default_env_key)

    if !is_atom(provider_id) do
      raise ArgumentError, "Provider :id must be an atom, got: #{inspect(provider_id)}"
    end

    if !is_binary(default_base_url) do
      raise ArgumentError,
            "Provider :default_base_url must be a string, got: #{inspect(default_base_url)}"
    end

    if default_env_key && !is_binary(default_env_key) do
      raise ArgumentError,
            "Provider :default_env_key must be a string, got: #{inspect(default_env_key)}"
    end

    quote do
      @behaviour ReqLLM.Provider

      use ReqLLM.Provider.Defaults

      Module.register_attribute(__MODULE__, :provider_schema, accumulate: false)
      @provider_schema []

      def provider_id, do: unquote(provider_id)
      def default_base_url, do: unquote(default_base_url)
      def base_url, do: default_base_url()

      unquote(
        if default_env_key do
          quote do
            def default_env_key, do: unquote(default_env_key)
          end
        end
      )

      defoverridable default_base_url: 0

      @before_compile ReqLLM.Provider
    end
  end

  @doc """
  Default implementation of parse_stream_protocol using SSE parsing.

  Providers can override this to implement custom streaming protocols.
  """
  def parse_stream_protocol(chunk, buffer) do
    _data = buffer <> chunk
    {events, new_buffer} = ReqLLM.Streaming.SSE.accumulate_and_parse(chunk, buffer)
    {:ok, events, new_buffer}
  end

  @doc """
  Registry function with bang syntax (raises on error).
  """
  @spec get!(atom()) :: module()
  def get!(provider_id) do
    case ReqLLM.provider(provider_id) do
      {:ok, module} ->
        module

      {:error, error} ->
        raise error
    end
  end
end
