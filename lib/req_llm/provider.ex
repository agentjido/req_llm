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

  ## Implementation Pattern

  Providers use `ReqLLM.Provider.DSL` to define their configuration and implement
  the required callbacks as Req pipeline steps.

  ## Examples

      defmodule MyProvider do
        @behaviour ReqLLM.Provider

        use ReqLLM.Provider.DSL,
          id: :myprovider,
          base_url: "https://api.example.com/v1",
          metadata: "priv/models_dev/myprovider.json"

        @impl ReqLLM.Provider
        def prepare_request(operation, model, messages, opts) do
          with {:ok, request} <- Req.new(base_url: "https://api.example.com/v1"),
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

      # Embedding operation  
      def prepare_request(:embed, model, text, opts) do
        {:ok, request} = Req.new(base_url: "https://api.anthropic.com/v1/embed")
        {:ok, add_auth_headers(request)}
      end

  """
  @callback prepare_request(
              operation(),
              ReqLLM.Model.t() | term(),
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
  @callback attach(Req.Request.t(), ReqLLM.Model.t(), keyword()) :: Req.Request.t()

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
  @callback extract_usage(term(), ReqLLM.Model.t() | nil) ::
              {:ok, map()} | {:error, term()}

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
  @callback translate_options(operation(), ReqLLM.Model.t(), keyword()) ::
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

  @optional_callbacks [extract_usage: 2, default_env_key: 0, translate_options: 3]

  @doc """
  Registry function to get provider module for a provider ID.

  ## Parameters

    * `provider_id` - Atom identifying the provider (e.g., :anthropic)

  ## Returns

    * `{:ok, module()}` - Provider module that implements this behavior
    * `{:error, term()}` - Provider not found

  """
  @spec get(atom()) :: {:ok, module()} | {:error, term()}
  def get(provider_id) do
    ReqLLM.Provider.Registry.get_provider(provider_id)
  end

  @doc """
  Registry function with bang syntax (raises on error).
  """
  @spec get!(atom()) :: module()
  def get!(provider_id) do
    case get(provider_id) do
      {:ok, module} -> module
      {:error, _reason} -> raise ReqLLM.Error.Invalid.Provider.exception(provider: provider_id)
    end
  end
end
