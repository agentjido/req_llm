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

  alias ReqLLM.{Context, Model, Response}

  require Logger

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
                 ],
                 on_unsupported: [
                   type: {:in, [:warn, :error, :ignore]},
                   doc: "How to handle unsupported parameter translations",
                   default: :warn
                 ],
                 req_options: [
                   type: {:or, [:map, {:list, :any}]},
                   doc: "Req-specific options (keyword list or map)",
                   default: []
                 ],
                 fixture: [
                   type: {:or, [:string, {:tuple, [:atom, :string]}]},
                   doc: "HTTP fixture for testing (provider inferred from model if string)"
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
         schema = ReqLLM.Utils.compose_schema(@base_schema, provider_module),
         {:ok, validated_opts} <- NimbleOptions.validate(opts, schema),
         {translated_opts, warnings} <-
           translate_provider_options(provider_module, :chat, model, validated_opts),
         :ok <- handle_warnings(translated_opts, warnings),
         {:ok, context} <- build_context(messages, translated_opts),
         {:ok, configured_request} <-
           provider_module.prepare_request(:chat, model, context, translated_opts),
         request_with_options =
           configured_request
           |> ReqLLM.Step.Error.attach()
           |> add_instrumentation_step()
           |> ReqLLM.Utils.merge_req_options(translated_opts)
           |> ReqLLM.Utils.attach_fixture(model, translated_opts),
         {:ok, %Req.Response{status: status, body: decoded_response}} when status in 200..299 <-
           Req.request(request_with_options) do
      {:ok, decoded_response}
    else
      {:ok, %Req.Response{status: status, body: body}} ->
        {:error,
         ReqLLM.Error.API.Request.exception(
           reason: "HTTP #{status}: Request failed",
           status: status,
           response_body: body
         )}

      {:error, %ReqLLM.Error.API.Request{}} = error ->
        error

      {:error, %ReqLLM.Error.Invalid.Provider{}} = error ->
        error

      {:error, %ReqLLM.Error.Invalid.Role{}} = error ->
        error

      {:error, %ReqLLM.Error.Invalid.Message{}} = error ->
        error

      {:error, %ReqLLM.Error.Validation.Error{}} = error ->
        error

      {:error, %Mint.TransportError{} = error} ->
        {:error,
         ReqLLM.Error.API.Request.exception(
           reason: "Network error: #{Exception.message(error)}",
           cause: error
         )}

      {:error, %Req.Response{status: status, body: body}} ->
        {:error,
         ReqLLM.Error.API.Request.exception(
           reason: "HTTP #{status}: Request failed",
           status: status,
           response_body: body
         )}

      {:error, reason} when is_binary(reason) ->
        {:error, ReqLLM.Error.API.Request.exception(reason: reason)}

      {:error, other} ->
        {:error, ReqLLM.Error.Unknown.Unknown.exception(error: other)}
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
         schema = ReqLLM.Utils.compose_schema(@base_schema, provider_module),
         {:ok, validated_opts} <- NimbleOptions.validate(opts, schema),
         {translated_opts, warnings} <-
           translate_provider_options(provider_module, :chat, model, validated_opts),
         :ok <- handle_warnings(translated_opts, warnings),
         stream_opts = Keyword.put(translated_opts, :stream, true),
         {:ok, context} <- build_context(messages, stream_opts),
         {:ok, configured_request} <-
           provider_module.prepare_request(:chat, model, context, stream_opts),
         request_with_options =
           configured_request
           |> ReqLLM.Step.Error.attach()
           |> add_instrumentation_step()
           |> ReqLLM.Utils.merge_req_options(stream_opts)
           |> ReqLLM.Utils.attach_fixture(model, stream_opts),
         {:ok, %Req.Response{status: status, body: decoded_response}} when status in 200..299 <-
           Req.request(request_with_options) do
      {:ok, decoded_response}
    else
      {:ok, %Req.Response{status: status, body: body}} ->
        {:error,
         ReqLLM.Error.API.Request.exception(
           reason: "HTTP #{status}: Request failed",
           status: status,
           response_body: body
         )}

      {:error, %ReqLLM.Error.API.Request{}} = error ->
        error

      {:error, %ReqLLM.Error.Invalid.Provider{}} = error ->
        error

      {:error, %ReqLLM.Error.Invalid.Role{}} = error ->
        error

      {:error, %ReqLLM.Error.Invalid.Message{}} = error ->
        error

      {:error, %ReqLLM.Error.Validation.Error{}} = error ->
        error

      {:error, %Mint.TransportError{} = error} ->
        {:error,
         ReqLLM.Error.API.Request.exception(
           reason: "Network error: #{Exception.message(error)}",
           cause: error
         )}

      {:error, %Req.Response{status: status, body: body}} ->
        {:error,
         ReqLLM.Error.API.Request.exception(
           reason: "HTTP #{status}: Request failed",
           status: status,
           response_body: body
         )}

      {:error, reason} when is_binary(reason) ->
        {:error, ReqLLM.Error.API.Request.exception(reason: reason)}

      {:error, other} ->
        {:error, ReqLLM.Error.Unknown.Unknown.exception(error: other)}
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

  defp add_instrumentation_step(request) do
    Req.Request.append_request_steps(request,
      llm_instrumentation: fn req ->
        Logger.debug("ReqLLM: Making request to #{req.url}")
        req
      end
    )
  end

  defp translate_provider_options(provider_mod, operation, model, opts) do
    if function_exported?(provider_mod, :translate_options, 3) do
      provider_mod.translate_options(operation, model, opts)
    else
      {opts, []}
    end
  end

  defp handle_warnings(opts, warnings) do
    case opts[:on_unsupported] || :warn do
      :ignore ->
        :ok

      :warn ->
        Enum.each(warnings, &Logger.warning/1)
        :ok

      :error ->
        if warnings == [], do: :ok, else: {:error, {:unsupported_options, warnings}}
    end
  end

  defp build_context(messages, opts) when is_binary(messages) do
    context = Context.new([Context.user(messages)])
    {:ok, add_system_prompt(context, opts)}
  end

  defp build_context(%Context{} = context, opts) do
    {:ok, add_system_prompt(context, opts)}
  end

  defp build_context(messages, opts) when is_list(messages) do
    # Convert plain message maps to Context if needed
    case convert_message_list(messages) do
      {:ok, message_structs} ->
        context = Context.new(message_structs)
        {:ok, add_system_prompt(context, opts)}

      {:error, _} = error ->
        error
    end
  end

  defp convert_message_list(messages) do
    messages
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {message, index}, {:ok, acc} ->
      case convert_single_message(message, index) do
        {:ok, converted} -> {:cont, {:ok, [converted | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, messages} -> {:ok, Enum.reverse(messages)}
      {:error, _} = error -> error
    end
  end

  defp convert_single_message(%ReqLLM.Message{} = message, _index) do
    {:ok, message}
  end

  defp convert_single_message(%{role: role, content: content} = message, _index) do
    case validate_role(role) do
      {:ok, role_atom} ->
        converted = Context.text(role_atom, content, Map.get(message, :metadata, %{}))
        {:ok, converted}

      {:error, _} ->
        {:error, ReqLLM.Error.Invalid.Role.exception(role: role)}
    end
  end

  defp convert_single_message(_other, index) do
    {:error,
     ReqLLM.Error.Invalid.Message.exception(
       reason: "Invalid message format at index #{index}",
       index: index
     )}
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

  # Validate role and convert to atom safely
  defp validate_role(role) when role in [:user, :system, :assistant, :tool], do: {:ok, role}

  defp validate_role(role) when is_binary(role) do
    case String.downcase(role) do
      role_str when role_str in ~w(user system assistant tool) ->
        {:ok, String.to_atom(role_str)}

      _ ->
        {:error, :invalid_role}
    end
  end

  defp validate_role(_), do: {:error, :invalid_role}

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
         options_schema = ReqLLM.Utils.compose_schema(@base_schema, provider_module),
         {:ok, validated_opts} <- NimbleOptions.validate(opts, options_schema),
         {translated_opts, warnings} <-
           translate_provider_options(provider_module, :object, model, validated_opts),
         :ok <- handle_warnings(translated_opts, warnings),
         {:ok, compiled_schema} <- ReqLLM.Schema.compile(object_schema),
         context = build_context(messages, translated_opts),
         {:ok, configured_request} <-
           provider_module.prepare_request(
             :object,
             model,
             context,
             compiled_schema,
             translated_opts
           ),
         request_with_options =
           configured_request
           |> ReqLLM.Utils.merge_req_options(translated_opts)
           |> ReqLLM.Utils.attach_fixture(model, translated_opts),
         {:ok, %Req.Response{body: decoded_response}} <- Req.request(request_with_options) do
      # Provider already decoded to ReqLLM.Response, now extract object from tool calls
      case ReqLLM.Response.tool_calls(decoded_response) do
        [] ->
          {:error, %ReqLLM.Error.API.Response{reason: "No structured output found in response"}}

        tool_calls ->
          case Enum.find(tool_calls, &(&1.name == "structured_output")) do
            nil ->
              {:error, %ReqLLM.Error.API.Response{reason: "No structured_output tool call found"}}

            %{arguments: object} ->
              {:ok, %{decoded_response | object: object}}
          end
      end
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
         options_schema = ReqLLM.Utils.compose_schema(@base_schema, provider_module),
         {:ok, validated_opts} <- NimbleOptions.validate(opts, options_schema),
         {translated_opts, warnings} <-
           translate_provider_options(provider_module, :object, model, validated_opts),
         :ok <- handle_warnings(translated_opts, warnings),
         {:ok, compiled_schema} <- ReqLLM.Schema.compile(object_schema),
         stream_opts = Keyword.put(translated_opts, :stream, true),
         context = build_context(messages, stream_opts),
         opts_with_schema = Keyword.put(stream_opts, :compiled_schema, compiled_schema),
         {:ok, configured_request} <-
           provider_module.prepare_request(:object, model, context, opts_with_schema),
         request_with_options =
           configured_request
           |> ReqLLM.Utils.merge_req_options(stream_opts)
           |> ReqLLM.Utils.attach_fixture(model, stream_opts),
         {:ok, %Req.Response{body: decoded_response}} <- Req.request(request_with_options) do
      {:ok, decoded_response}
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
