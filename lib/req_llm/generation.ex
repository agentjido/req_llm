defmodule ReqLLM.Generation do
  @moduledoc """
  Text generation functionality for ReqLLM.

  This module provides the core text generation capabilities including:
  - Text generation with full response metadata
  - Text streaming with metadata
  - Usage and cost extraction utilities

  All functions follow Vercel AI SDK patterns and return structured responses
  with proper error handling.
  """

  alias ReqLLM.{Model, Context, Response}

  @base_schema NimbleOptions.new!(
                 temperature: [
                   type: :float,
                   doc: "Controls randomness in the output (0.0 to 2.0)"
                 ],
                 max_tokens: [
                   type: :pos_integer,
                   doc: "Maximum number of tokens to generate"
                 ],
                 top_p: [
                   type: :float,
                   doc: "Nucleus sampling parameter"
                 ],
                 top_k: [
                   type: :pos_integer,
                   doc: "Top-k sampling parameter"
                 ],
                 presence_penalty: [
                   type: :float,
                   doc: "Penalize new tokens based on presence"
                 ],
                 frequency_penalty: [
                   type: :float,
                   doc: "Penalize new tokens based on frequency"
                 ],
                 stop_sequences: [
                   type: {:list, :string},
                   doc: "Stop sequences to halt generation"
                 ],
                 response_format: [
                   type: :map,
                   doc: "Format for the response (e.g., JSON mode)"
                 ],
                 thinking: [
                   type: :boolean,
                   doc: "Enable thinking/reasoning tokens (beta feature)"
                 ],
                 tools: [
                   type: :any,
                   doc: "List of tool definitions"
                 ],
                 tool_choice: [
                   type: {:or, [:string, :atom, :map]},
                   doc: "Tool choice strategy"
                 ],
                 system_prompt: [
                   type: :string,
                   doc: "System prompt to prepend"
                 ],
                 provider_options: [
                   type: {:or, [:map, {:list, :any}]},
                   doc: "Provider-specific options (keyword list or map)",
                   default: []
                 ],
                 reasoning: [
                   type: {:in, [nil, false, true, "low", "auto", "high"]},
                   doc: "Request reasoning tokens from the model"
                 ],
                 seed: [
                   type: :pos_integer,
                   doc: "Seed for deterministic outputs"
                 ],
                 user: [
                   type: :string,
                   doc: "User identifier for tracking/abuse detection"
                 ]
               )

  @doc """
  Returns the base generation options schema.

  This schema contains only vendor-neutral options. Provider-specific options
  should be validated separately by each provider.
  """
  @spec schema :: NimbleOptions.t()
  def schema, do: @base_schema

  @doc """
  Builds a dynamic schema by composing the base schema with provider-specific options.

  This function takes a provider module and creates a unified schema where provider-specific
  options are nested under the :provider_options key with proper validation.

  ## Parameters

    * `provider_mod` - Provider module that defines provider_schema/0 function

  ## Examples

      schema = ReqLLM.Generation.dynamic_schema(ReqLLM.Providers.Groq)
      NimbleOptions.validate([temperature: 0.7, provider_options: [service_tier: "auto"]], schema)
      #=> {:ok, [temperature: 0.7, provider_options: [service_tier: "auto"]]}

  """
  @spec dynamic_schema(module()) :: NimbleOptions.t()
  def dynamic_schema(provider_mod) do
    if function_exported?(provider_mod, :provider_schema, 0) do
      provider_keys = provider_mod.provider_schema().schema

      # Update the :provider_options key with provider-specific nested schema
      updated_schema =
        Keyword.update!(@base_schema.schema, :provider_options, fn opt ->
          Keyword.merge(opt,
            type: :keyword_list,
            keys: provider_keys,
            default: []
          )
        end)

      NimbleOptions.new!(updated_schema)
    else
      @base_schema
    end
  end

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

      {:ok, response} = ReqLLM.Generation.generate_text("anthropic:claude-3-sonnet", "Hello world")
      ReqLLM.Response.text(response)
      #=> "Hello! How can I assist you today?"

      # Access usage metadata
      ReqLLM.Response.usage(response)
      #=> %{input_tokens: 10, output_tokens: 8}

  """
  @spec generate_text(
          String.t() | {atom(), keyword()} | struct(),
          String.t() | list(),
          keyword()
        ) :: {:ok, Response.t()} | {:error, term()}
  def generate_text(model_spec, messages, opts \\ []) do
    with {:ok, model} <- Model.from(model_spec),
         {:ok, provider_module} <- ReqLLM.provider(model.provider),
         schema = dynamic_schema(provider_module),
         {:ok, validated_opts} <- NimbleOptions.validate(opts, schema),
         context = build_context(messages, validated_opts),
         {:ok, configured_request} <-
           provider_module.prepare_request(:chat, model, context, validated_opts),
         {:ok, %Req.Response{body: decoded_response}} <- Req.request(configured_request) do
      Response.decode_response(decoded_response, model)
    end
  end

  @doc """
  Generates text using an AI model, returning only the text content.

  This is a convenience function that extracts just the text from the response.
  For access to usage metadata and other response data, use `generate_text/3`.
  Raises on error.

  ## Parameters

  Same as `generate_text/3`.

  ## Examples

      ReqLLM.Generation.generate_text!("anthropic:claude-3-sonnet", "Hello world")
      #=> "Hello! How can I assist you today?"

  """
  @spec generate_text!(
          String.t() | {atom(), keyword()} | struct(),
          String.t() | list(),
          keyword()
        ) :: String.t() | no_return()
  def generate_text!(model_spec, messages, opts \\ []) do
    case generate_text(model_spec, messages, opts) do
      {:ok, response} -> Response.text(response)
      {:error, error} -> raise error
    end
  end

  @doc """
  Streams text generation using an AI model with full response metadata.

  Returns a canonical ReqLLM.Response containing usage data and stream.
  For simple streaming without metadata, use `stream_text!/3`.

  ## Parameters

  Same as `generate_text/3`.

  ## Examples

      {:ok, response} = ReqLLM.Generation.stream_text("anthropic:claude-3-sonnet", "Tell me a story")
      ReqLLM.Response.text_stream(response) |> Enum.each(&IO.write/1)

      # Access usage metadata after streaming
      ReqLLM.Response.usage(response)
      #=> %{input_tokens: 15, output_tokens: 42}

  """
  @spec stream_text(
          String.t() | {atom(), keyword()} | struct(),
          String.t() | list(),
          keyword()
        ) :: {:ok, Response.t()} | {:error, term()}
  def stream_text(model_spec, messages, opts \\ []) do
    with {:ok, model} <- Model.from(model_spec),
         {:ok, provider_module} <- ReqLLM.provider(model.provider),
         schema = dynamic_schema(provider_module),
         {:ok, validated_opts} <- NimbleOptions.validate(opts, schema),
         stream_opts = Keyword.put(validated_opts, :stream, true),
         context = build_context(messages, stream_opts),
         {:ok, configured_request} <-
           provider_module.prepare_request(:chat, model, context, stream_opts),
         {:ok, %Req.Response{body: decoded_response}} <- Req.request(configured_request) do
      Response.decode_response(decoded_response, model)
    end
  end

  @doc """
  Streams text generation using an AI model, returning only the stream.

  This is a convenience function that extracts just the stream from the response.
  For access to usage metadata and other response data, use `stream_text/3`.
  Raises on error.

  ## Parameters

  Same as `stream_text/3`.

  ## Examples

      ReqLLM.Generation.stream_text!("anthropic:claude-3-sonnet", "Tell me a story")
      |> Enum.each(&IO.write/1)

  """
  @spec stream_text!(
          String.t() | {atom(), keyword()} | struct(),
          String.t() | list(),
          keyword()
        ) :: Enumerable.t() | no_return()
  def stream_text!(model_spec, messages, opts \\ []) do
    case stream_text(model_spec, messages, opts) do
      {:ok, response} -> Response.text_stream(response)
      {:error, error} -> raise error
    end
  end

  # Private helper functions

  defp build_context(messages, opts) when is_binary(messages) do
    context = Context.new([Context.user(messages)])
    add_system_prompt(context, opts)
  end

  defp build_context(%Context{} = context, opts) do
    add_system_prompt(context, opts)
  end

  defp build_context(messages, opts) when is_list(messages) do
    # Convert plain message maps to Context if needed
    message_structs =
      Enum.map(messages, fn
        %ReqLLM.Message{} = message ->
          message

        %{role: role, content: content} = message ->
          Context.text(
            String.to_existing_atom(to_string(role)),
            content,
            Map.get(message, :metadata, %{})
          )

        other ->
          other
      end)

    context = Context.new(message_structs)
    add_system_prompt(context, opts)
  end

  defp add_system_prompt(%Context{} = context, opts) do
    case opts[:system_prompt] do
      nil ->
        context

      system_text when is_binary(system_text) ->
        system_msg = Context.system(system_text)
        Context.new([system_msg | Context.to_list(context)])
    end
  end

  @doc """
  Generates structured data using an AI model with schema validation.

  Returns a canonical ReqLLM.Response which includes the generated object, usage data,
  context, and metadata. For simple object-only results, use `generate_object!/4`.

  ## Parameters

    * `model_spec` - Model specification in various formats
    * `messages` - Text prompt or list of messages
    * `schema` - Schema definition for structured output (keyword list)
    * `opts` - Additional options (keyword list)

  ## Options

    * `:temperature` - Control randomness in responses (0.0 to 2.0)
    * `:max_tokens` - Limit the length of the response
    * `:top_p` - Nucleus sampling parameter
    * `:presence_penalty` - Penalize new tokens based on presence
    * `:frequency_penalty` - Penalize new tokens based on frequency
    * `:system_prompt` - System prompt to prepend
    * `:provider_options` - Provider-specific options

  ## Examples

      {:ok, response} = ReqLLM.Generation.generate_object("anthropic:claude-3-sonnet", "Generate a person", person_schema)
      ReqLLM.Response.object(response)
      #=> %{name: "Alice Smith", age: 30, occupation: "Engineer"}

      # Access usage metadata
      ReqLLM.Response.usage(response)
      #=> %{input_tokens: 25, output_tokens: 15}

  """
  @spec generate_object(
          String.t() | {atom(), keyword()} | struct(),
          String.t() | list(),
          keyword(),
          keyword()
        ) :: {:ok, Response.t()} | {:error, term()}
  def generate_object(model_spec, messages, object_schema, opts \\ []) do
    with {:ok, model} <- Model.from(model_spec),
         {:ok, provider_module} <- ReqLLM.provider(model.provider),
         options_schema = dynamic_schema(provider_module),
         {:ok, validated_opts} <- NimbleOptions.validate(opts, options_schema),
         {:ok, compiled_schema} <- ReqLLM.Schema.compile(object_schema),
         context = build_context(messages, validated_opts),
         {:ok, configured_request} <-
           provider_module.prepare_request(
             :object,
             model,
             context,
             compiled_schema,
             validated_opts
           ),
         {:ok, %Req.Response{body: decoded_response}} <- Req.request(configured_request) do
      Response.decode_object(decoded_response, model, object_schema)
    end
  end

  @doc """
  Streams structured data generation using an AI model with schema validation.

  Returns a canonical ReqLLM.Response containing usage data and object stream.
  For simple object streaming without metadata, use `stream_object!/4`.

  ## Parameters

    * `model_spec` - Model specification in various formats
    * `messages` - Text prompt or list of messages
    * `schema` - Schema definition for structured output (keyword list)
    * `opts` - Additional options (keyword list)

  ## Options

  Same as `generate_object/4`.

  ## Examples

      {:ok, response} = ReqLLM.Generation.stream_object("anthropic:claude-3-sonnet", "Generate a person", person_schema)
      ReqLLM.Response.object_stream(response) |> Enum.each(&IO.inspect/1)

      # Access usage metadata after streaming
      ReqLLM.Response.usage(response)
      #=> %{input_tokens: 25, output_tokens: 15}

  """
  @spec stream_object(
          String.t() | {atom(), keyword()} | struct(),
          String.t() | list(),
          keyword(),
          keyword()
        ) :: {:ok, Response.t()} | {:error, term()}
  def stream_object(model_spec, messages, object_schema, opts \\ []) do
    with {:ok, model} <- Model.from(model_spec),
         {:ok, provider_module} <- ReqLLM.provider(model.provider),
         options_schema = dynamic_schema(provider_module),
         {:ok, validated_opts} <- NimbleOptions.validate(opts, options_schema),
         {:ok, compiled_schema} <- ReqLLM.Schema.compile(object_schema),
         stream_opts = Keyword.put(validated_opts, :stream, true),
         context = build_context(messages, stream_opts),
         {:ok, configured_request} <-
           provider_module.prepare_request(:object, model, context, compiled_schema, stream_opts),
         {:ok, %Req.Response{body: decoded_response}} <- Req.request(configured_request) do
      Response.decode_object_stream(decoded_response, model, object_schema)
    end
  end

  @doc """
  Generates structured data using an AI model, returning only the object content.

  This is a convenience function that extracts just the object from the response.
  For access to usage metadata and other response data, use `generate_object/4`.
  Raises on error.

  ## Parameters

  Same as `generate_object/4`.

  ## Examples

      ReqLLM.Generation.generate_object!("anthropic:claude-3-sonnet", "Generate a person", person_schema)
      #=> %{name: "Alice Smith", age: 30, occupation: "Engineer"}

  """
  @spec generate_object!(
          String.t() | {atom(), keyword()} | struct(),
          String.t() | list(),
          keyword(),
          keyword()
        ) :: map() | no_return()
  def generate_object!(model_spec, messages, object_schema, opts \\ []) do
    case generate_object(model_spec, messages, object_schema, opts) do
      {:ok, response} -> Response.object(response)
      {:error, error} -> raise error
    end
  end

  @doc """
  Streams structured data generation using an AI model, returning only the stream.

  This is a convenience function that extracts just the stream from the response.
  For access to usage metadata and other response data, use `stream_object/4`.
  Raises on error.

  ## Parameters

  Same as `stream_object/4`.

  ## Examples

      ReqLLM.Generation.stream_object!("anthropic:claude-3-sonnet", "Generate a person", person_schema)
      |> Enum.each(&IO.inspect/1)

  """
  @spec stream_object!(
          String.t() | {atom(), keyword()} | struct(),
          String.t() | list(),
          keyword(),
          keyword()
        ) :: Enumerable.t() | no_return()
  def stream_object!(model_spec, messages, object_schema, opts \\ []) do
    case stream_object(model_spec, messages, object_schema, opts) do
      {:ok, response} -> Response.object_stream(response)
      {:error, error} -> raise error
    end
  end
end
