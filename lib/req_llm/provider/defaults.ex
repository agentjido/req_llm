defmodule ReqLLM.Provider.Defaults do
  @moduledoc """
  Default implementations for common provider behavior patterns.

  This module extracts shared logic between OpenAI-compatible providers (OpenAI, Groq, etc.)
  into reusable runtime functions and a `__using__` macro that provides default callback
  implementations.

  ## Usage

      defmodule MyProvider do
        @behaviour ReqLLM.Provider
        use ReqLLM.Provider.DSL, [...]
        use ReqLLM.Provider.Defaults

        # All default implementations are available and overridable
        # Override only what you need to customize
      end

  ## Design Principles

  - Runtime functions are pure and testable
  - Provider module is passed as first argument to access attributes
  - All defaults are `defoverridable` for selective customization
  - Providers can override individual methods or use helper functions directly

  ## Default Implementations

  The following methods get default implementations:

  - `prepare_request/4` - Standard chat/object/embedding request preparation
  - `attach/3` - OAuth Bearer authentication and standard pipeline steps
  - `encode_body/1` - OpenAI-compatible request body encoding
  - `decode_response/1` - Standard response decoding with error handling
  - `extract_usage/2` - Usage extraction from standard `usage` field
  - `translate_options/3` - No-op translation (pass-through)

  ## Runtime Functions

  All default implementations delegate to pure runtime functions that can be
  called independently:

  - `prepare_chat_request/4`
  - `prepare_object_request/4`
  - `prepare_embedding_request/4`
  - `default_attach/3`
  - `default_encode_body/1`
  - `default_decode_response/1`
  - `default_extract_usage/2`
  - `default_translate_options/3`

  ## Customization Examples

      # Override just the body encoding while keeping everything else
      def encode_body(request) do
        request
        |> ReqLLM.Provider.Defaults.default_encode_body()
        |> add_custom_headers()
      end

      # Use runtime functions directly for testing
      test "encoding produces correct format" do
        request = build_test_request()
        encoded = ReqLLM.Provider.Defaults.default_encode_body(request)
        assert encoded.body =~ ~s("model":")
      end
  """

  import ReqLLM.Provider.Utils, only: [maybe_put: 3, ensure_parsed_body: 1]

  require Logger

  @doc """
  Provides default implementations for common provider patterns.

  All methods are `defoverridable`, so providers can selectively override
  only the methods they need to customize.
  """
  defmacro __using__(_opts) do
    quote do
      @doc """
      Default implementation of prepare_request/4.

      Handles :chat, :object, and :embedding operations using OpenAI-compatible patterns.
      """
      @impl ReqLLM.Provider
      def prepare_request(operation, model_spec, input, opts) do
        ReqLLM.Provider.Defaults.prepare_request(__MODULE__, operation, model_spec, input, opts)
      end

      @doc """
      Default implementation of attach/3.

      Sets up Bearer token authentication and standard pipeline steps.
      """
      @impl ReqLLM.Provider
      def attach(request, model_input, user_opts \\ []) do
        ReqLLM.Provider.Defaults.default_attach(__MODULE__, request, model_input, user_opts)
      end

      @doc """
      Default implementation of encode_body/1.

      Encodes request body using OpenAI-compatible format for chat and embedding operations.
      """
      @impl ReqLLM.Provider
      def encode_body(request) do
        ReqLLM.Provider.Defaults.default_encode_body(request)
      end

      @doc """
      Default implementation of decode_response/1.

      Handles success/error responses with standard ReqLLM.Response creation.
      """
      @impl ReqLLM.Provider
      def decode_response(request_response) do
        ReqLLM.Provider.Defaults.default_decode_response(request_response)
      end

      @doc """
      Default implementation of extract_usage/2.

      Extracts usage data from standard `usage` field in response body.
      """
      @impl ReqLLM.Provider
      def extract_usage(body, model) do
        ReqLLM.Provider.Defaults.default_extract_usage(body, model)
      end

      @doc """
      Default implementation of translate_options/3.

      Pass-through implementation that returns options unchanged.
      """
      @impl ReqLLM.Provider
      def translate_options(operation, model, opts) do
        ReqLLM.Provider.Defaults.default_translate_options(operation, model, opts)
      end

      @doc """
      Default implementation of decode_sse_event/2.

      Decodes SSE events using OpenAI-compatible format.
      """
      @impl ReqLLM.Provider
      def decode_sse_event(event, model) do
        ReqLLM.Provider.Defaults.default_decode_sse_event(event, model)
      end

      # Make all default implementations overridable
      defoverridable prepare_request: 4,
                     attach: 3,
                     encode_body: 1,
                     decode_response: 1,
                     extract_usage: 2,
                     translate_options: 3,
                     decode_sse_event: 2
    end
  end

  # Runtime implementation functions (pure and testable)

  @doc """
  Runtime implementation of prepare_request/4.

  Delegates to operation-specific preparation functions.
  """
  @spec prepare_request(module(), atom(), term(), term(), keyword()) ::
          {:ok, Req.Request.t()} | {:error, Exception.t()}
  def prepare_request(provider_mod, operation, model_spec, input, opts) do
    case operation do
      :chat ->
        prepare_chat_request(provider_mod, model_spec, input, opts)

      :response ->
        prepare_response_request(provider_mod, model_spec, input, opts)

      :object ->
        prepare_object_request(provider_mod, model_spec, input, opts)

      :embedding ->
        prepare_embedding_request(provider_mod, model_spec, input, opts)

      _ ->
        supported_operations = [:chat, :response, :object, :embedding]

        {:error,
         ReqLLM.Error.Invalid.Parameter.exception(
           parameter:
             "operation: #{inspect(operation)} not supported by #{inspect(provider_mod)}. Supported operations: #{inspect(supported_operations)}"
         )}
    end
  end

  @doc """
  Prepares a chat completion request.
  """
  @spec prepare_chat_request(module(), term(), term(), keyword()) ::
          {:ok, Req.Request.t()} | {:error, Exception.t()}
  def prepare_chat_request(provider_mod, model_spec, prompt, opts) do
    with {:ok, model} <- ReqLLM.Model.from(model_spec),
         {:ok, context} <- ReqLLM.Context.normalize(prompt, opts),
         opts_with_context = Keyword.put(opts, :context, context),
         http_opts = Keyword.get(opts, :req_http_options, []),
         {:ok, processed_opts} <-
           ReqLLM.Provider.Options.process(provider_mod, :chat, model, opts_with_context) do
      req_keys =
        provider_mod.supported_provider_options() ++
          [:context, :operation, :text, :stream, :model, :provider_options]

      request =
        Req.new(
          [
            url: "/chat/completions",
            method: :post,
            receive_timeout: Keyword.get(processed_opts, :receive_timeout, 30_000)
          ] ++ http_opts
        )
        |> Req.Request.register_options(req_keys)
        |> Req.Request.merge_options(
          Keyword.take(processed_opts, req_keys) ++
            [
              model: model.model,
              base_url: Keyword.get(processed_opts, :base_url, provider_mod.default_base_url())
            ]
        )
        |> provider_mod.attach(model, processed_opts)

      {:ok, request}
    end
  end

  @doc """
  Prepares a response completion request for OpenAI Responses API.
  """
  @spec prepare_response_request(module(), term(), term(), keyword()) ::
          {:ok, Req.Request.t()} | {:error, Exception.t()}
  def prepare_response_request(provider_mod, model_spec, prompt, opts) do
    with {:ok, model} <- ReqLLM.Model.from(model_spec),
         {:ok, context} <- ReqLLM.Context.normalize(prompt, opts),
         opts_with_context = Keyword.put(opts, :context, context),
         http_opts = Keyword.get(opts, :req_http_options, []),
         {:ok, processed_opts} <-
           ReqLLM.Provider.Options.process(provider_mod, :response, model, opts_with_context) do
      req_keys =
        provider_mod.supported_provider_options() ++
          [:context, :operation, :input, :stream, :model, :provider_options]

      # Use custom endpoint path if provided, otherwise default to /responses
      endpoint_path = Keyword.get(processed_opts, :endpoint_path, "/responses")

      request =
        Req.new(
          [
            url: endpoint_path,
            method: :post,
            receive_timeout: Keyword.get(processed_opts, :receive_timeout, 30_000)
          ] ++ http_opts
        )
        |> Req.Request.register_options(req_keys)
        |> Req.Request.merge_options(
          Keyword.take(processed_opts, req_keys) ++
            [
              model: model.model,
              operation: :response,
              base_url: Keyword.get(processed_opts, :base_url, provider_mod.default_base_url())
            ]
        )
        |> provider_mod.attach(model, processed_opts)

      {:ok, request}
    end
  end

  @doc """
  Prepares an object generation request using tool calling.
  """
  @spec prepare_object_request(module(), term(), term(), keyword()) ::
          {:ok, Req.Request.t()} | {:error, Exception.t()}
  def prepare_object_request(provider_mod, model_spec, prompt, opts) do
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
      |> Keyword.put(:operation, :object)

    prepare_chat_request(provider_mod, model_spec, prompt, opts_with_tool)
  end

  @doc """
  Prepares an embedding generation request.
  """
  @spec prepare_embedding_request(module(), term(), term(), keyword()) ::
          {:ok, Req.Request.t()} | {:error, Exception.t()}
  def prepare_embedding_request(provider_mod, model_spec, text, opts) do
    with {:ok, model} <- ReqLLM.Model.from(model_spec),
         opts_with_text = Keyword.merge(opts, text: text, operation: :embedding),
         http_opts = Keyword.get(opts, :req_http_options, []),
         {:ok, processed_opts} <-
           ReqLLM.Provider.Options.process(provider_mod, :embedding, model, opts_with_text) do
      req_keys =
        provider_mod.supported_provider_options() ++
          [:context, :operation, :text, :stream, :model, :provider_options]

      request =
        Req.new(
          [
            url: "/embeddings",
            method: :post,
            receive_timeout: Keyword.get(processed_opts, :receive_timeout, 30_000)
          ] ++ http_opts
        )
        |> Req.Request.register_options(req_keys)
        |> Req.Request.merge_options(
          Keyword.take(processed_opts, req_keys) ++
            [
              model: model.model,
              base_url: Keyword.get(processed_opts, :base_url, provider_mod.default_base_url())
            ]
        )
        |> provider_mod.attach(model, processed_opts)

      {:ok, request}
    end
  end

  @doc """
  Default attachment implementation with Bearer token auth and standard pipeline steps.
  """
  @spec default_attach(module(), Req.Request.t(), term(), keyword()) :: Req.Request.t()
  def default_attach(provider_mod, %Req.Request{} = request, model_input, user_opts) do
    %ReqLLM.Model{} = model = ReqLLM.Model.from!(model_input)

    if model.provider != provider_mod.provider_id() do
      raise ReqLLM.Error.Invalid.Provider.exception(provider: model.provider)
    end

    api_key = ReqLLM.Keys.get!(model, user_opts)

    # Register options that might be passed by users but aren't standard Req options
    extra_option_keys =
      [:model, :compiled_schema, :temperature, :max_tokens, :app_referer, :app_title, :fixture] ++
        provider_mod.supported_provider_options()

    request
    |> Req.Request.put_header("content-type", "application/json")
    |> Req.Request.put_header("authorization", "Bearer #{api_key}")
    |> Req.Request.register_options(extra_option_keys)
    |> Req.Request.merge_options([model: model.model, auth: {:bearer, api_key}] ++ user_opts)
    |> ReqLLM.Step.Error.attach()
    |> Req.Request.append_request_steps(llm_encode_body: &provider_mod.encode_body/1)
    |> ReqLLM.Step.Stream.maybe_attach(user_opts[:stream] == true, model)
    |> Req.Request.append_response_steps(llm_decode_response: &provider_mod.decode_response/1)
    |> ReqLLM.Step.Usage.attach(model)
    |> ReqLLM.Step.Fixture.maybe_attach(model, user_opts)
  end

  @doc """
  Default body encoding for OpenAI-compatible APIs.
  """
  @spec default_encode_body(Req.Request.t()) :: Req.Request.t()
  def default_encode_body(request) do
    body =
      case request.options[:operation] do
        :embedding ->
          encode_embedding_body(request)

        :response ->
          encode_response_body(request)

        _ ->
          encode_chat_body(request)
      end

    try do
      encoded_body = Jason.encode!(body)

      request
      |> Req.Request.put_header("content-type", "application/json")
      |> Map.put(:body, encoded_body)
    rescue
      error ->
        reraise error, __STACKTRACE__
    end
  end

  @doc """
  Default response decoding with success/error handling.
  """
  @spec default_decode_response({Req.Request.t(), Req.Response.t()}) ::
          {Req.Request.t(), Req.Response.t() | Exception.t()}
  def default_decode_response({req, resp}) do
    case resp.status do
      200 ->
        decode_success_response(req, resp)

      status ->
        decode_error_response(req, resp, status)
    end
  end

  @doc """
  Default usage extraction from standard `usage` field.
  """
  @spec default_extract_usage(term(), ReqLLM.Model.t() | nil) :: {:ok, map()} | {:error, term()}
  def default_extract_usage(body, _model) when is_map(body) do
    case body do
      %{"usage" => usage} -> {:ok, usage}
      _ -> {:error, :no_usage_found}
    end
  end

  def default_extract_usage(_, _), do: {:error, :invalid_body}

  @doc """
  Default options translation (pass-through).
  """
  @spec default_translate_options(atom(), ReqLLM.Model.t(), keyword()) ::
          {keyword(), [String.t()]}
  def default_translate_options(_operation, _model, opts) do
    {opts, []}
  end

  # Private helper functions

  @doc """
  Encodes ReqLLM.Context to OpenAI-compatible format.

  This function moves the logic from ReqLLM.Context.Codec.Map directly into 
  Provider.Defaults for the protocol removal refactoring.
  """
  @spec encode_context_to_openai_format(ReqLLM.Context.t(), String.t()) :: map()
  def encode_context_to_openai_format(%ReqLLM.Context{messages: messages}, _model_name) do
    %{
      messages: encode_openai_messages(messages)
    }
  end

  defp encode_openai_messages(messages) do
    Enum.map(messages, &encode_openai_message/1)
  end

  defp encode_openai_message(%ReqLLM.Message{
         role: role,
         content: content,
         tool_calls: tool_calls
       }) do
    base_message = %{
      role: to_string(role),
      content: encode_openai_content(content)
    }

    # Add tool_calls if present and not nil
    case tool_calls do
      nil -> base_message
      [] -> base_message
      calls -> Map.put(base_message, :tool_calls, calls)
    end
  end

  defp encode_openai_content(content) when is_binary(content), do: content

  defp encode_openai_content(content) when is_list(content) do
    content
    |> Enum.map(&encode_openai_content_part/1)
    |> maybe_flatten_single_text()
  end

  # Flatten single text content to a string for cleaner wire format
  defp maybe_flatten_single_text([%{type: "text", text: text}]), do: text

  defp maybe_flatten_single_text(content) do
    # Filter out nil values first
    filtered = Enum.reject(content, &is_nil/1)

    case filtered do
      [%{type: "text", text: text}] -> text
      _ -> filtered
    end
  end

  defp encode_openai_content_part(%ReqLLM.Message.ContentPart{type: :text, text: text}) do
    %{type: "text", text: text}
  end

  defp encode_openai_content_part(%ReqLLM.Message.ContentPart{
         type: :tool_call,
         tool_name: name,
         input: input,
         tool_call_id: id
       }) do
    %{
      id: id,
      type: "function",
      function: %{
        name: name,
        arguments: Jason.encode!(input)
      }
    }
  end

  defp encode_openai_content_part(_), do: nil

  @doc """
  Decodes OpenAI-format response body to ReqLLM.Response.

  This function moves the logic from ReqLLM.Response.Codec.Map directly into
  Provider.Defaults for the protocol removal refactoring.
  """
  @spec decode_response_body_openai_format(map(), ReqLLM.Model.t()) ::
          {:ok, ReqLLM.Response.t()} | {:error, term()}
  def decode_response_body_openai_format(data, model) when is_map(data) do
    id = Map.get(data, "id", "unknown")
    model_name = Map.get(data, "model", model.model || "unknown")
    usage = parse_openai_usage(Map.get(data, "usage"))

    choices = Map.get(data, "choices", [])
    first_choice = Enum.at(choices, 0, %{})

    finish_reason = parse_openai_finish_reason(Map.get(first_choice, "finish_reason"))

    content_chunks =
      case first_choice do
        %{"message" => message} -> decode_openai_message(message)
        %{"delta" => delta} -> decode_openai_delta(delta)
        _ -> []
      end

    message = build_openai_message_from_chunks(content_chunks)

    context = %ReqLLM.Context{
      messages: if(message, do: [message], else: [])
    }

    response = %ReqLLM.Response{
      id: id,
      model: model_name,
      context: context,
      message: message,
      stream?: false,
      stream: nil,
      usage: usage,
      finish_reason: finish_reason,
      provider_meta: Map.drop(data, ["id", "model", "choices", "usage"])
    }

    {:ok, response}
  end

  @doc """
  Default SSE event decoding for OpenAI-compatible providers.

  This function moves the logic from ReqLLM.Response.Codec.Map directly into
  Provider.Defaults for the protocol removal refactoring.
  """
  @spec default_decode_sse_event(map(), ReqLLM.Model.t()) :: [ReqLLM.StreamChunk.t()]
  def default_decode_sse_event(%{data: data}, _model) when is_map(data) do
    case data do
      %{"choices" => [%{"delta" => delta} | _]} -> decode_openai_delta(delta)
      _ -> []
    end
  end

  def default_decode_sse_event(_, _model), do: []

  defp decode_openai_message(%{"content" => content}) when is_binary(content) and content != "" do
    [ReqLLM.StreamChunk.text(content)]
  end

  defp decode_openai_message(%{"content" => content}) when is_list(content) do
    content
    |> Enum.map(&decode_openai_content_part/1)
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  defp decode_openai_message(%{"tool_calls" => tool_calls}) when is_list(tool_calls) do
    tool_calls
    |> Enum.map(&decode_openai_tool_call/1)
    |> Enum.reject(&is_nil/1)
  end

  defp decode_openai_message(_), do: []

  defp decode_openai_content_part(%{"type" => "text", "text" => text}) do
    [ReqLLM.StreamChunk.text(text)]
  end

  defp decode_openai_content_part(_), do: []

  defp decode_openai_tool_call(%{
         "id" => id,
         "type" => "function",
         "function" => %{"name" => name, "arguments" => args_json}
       }) do
    case Jason.decode(args_json || "{}") do
      {:ok, args} -> ReqLLM.StreamChunk.tool_call(name, args, %{id: id})
      {:error, _} -> nil
    end
  end

  defp decode_openai_tool_call(_), do: nil

  defp decode_openai_delta(%{"content" => content}) when is_binary(content) and content != "" do
    [ReqLLM.StreamChunk.text(content)]
  end

  defp decode_openai_delta(%{"tool_calls" => tool_calls}) when is_list(tool_calls) do
    tool_calls
    |> Enum.map(&decode_openai_tool_call_delta/1)
    |> Enum.reject(&is_nil/1)
  end

  defp decode_openai_delta(_), do: []

  defp decode_openai_tool_call_delta(%{
         "id" => id,
         "type" => "function",
         "function" => %{"name" => name, "arguments" => args_json}
       }) do
    case Jason.decode(args_json || "{}") do
      {:ok, args} -> ReqLLM.StreamChunk.tool_call(name, args, %{id: id})
      {:error, _} -> ReqLLM.StreamChunk.tool_call(name, %{}, %{id: id})
    end
  end

  defp decode_openai_tool_call_delta(_), do: nil

  defp build_openai_message_from_chunks([]), do: nil

  defp build_openai_message_from_chunks(chunks) do
    content_parts =
      chunks
      |> Enum.map(&openai_chunk_to_content_part/1)
      |> Enum.reject(&is_nil/1)

    if content_parts != [] do
      %ReqLLM.Message{
        role: :assistant,
        content: content_parts,
        metadata: %{}
      }
    end
  end

  defp openai_chunk_to_content_part(%ReqLLM.StreamChunk{type: :content, text: text}) do
    %ReqLLM.Message.ContentPart{type: :text, text: text}
  end

  defp openai_chunk_to_content_part(%ReqLLM.StreamChunk{
         type: :tool_call,
         name: name,
         arguments: args,
         metadata: meta
       }) do
    %ReqLLM.Message.ContentPart{
      type: :tool_call,
      tool_name: name,
      input: args,
      tool_call_id: Map.get(meta, :id)
    }
  end

  defp openai_chunk_to_content_part(_), do: nil

  defp parse_openai_usage(%{
         "prompt_tokens" => input,
         "completion_tokens" => output,
         "total_tokens" => total
       }) do
    %{
      input_tokens: input,
      output_tokens: output,
      total_tokens: total
    }
  end

  defp parse_openai_usage(_), do: %{input_tokens: 0, output_tokens: 0, total_tokens: 0}

  defp parse_openai_finish_reason("stop"), do: :stop
  defp parse_openai_finish_reason("length"), do: :length
  defp parse_openai_finish_reason("tool_calls"), do: :tool_calls
  defp parse_openai_finish_reason("content_filter"), do: :content_filter
  defp parse_openai_finish_reason(reason) when is_binary(reason), do: reason
  defp parse_openai_finish_reason(_), do: nil

  @doc """
  Build a complete OpenAI-style chat body from a Req request.

  This helper function encodes context, adds common options (temperature, max_tokens, etc.),
  converts tools to OpenAI schema, and handles stream flags. Providers can use this as a
  starting point and add provider-specific fields.

  ## Example

      def encode_body(req) do
        body = Defaults.build_openai_chat_body(req)
        |> Map.put(:my_provider_field, req.options[:my_provider_field])
        
        req
        |> Req.Request.put_header("content-type", "application/json")
        |> Map.put(:body, Jason.encode!(body))
      end
  """
  def build_openai_chat_body(request), do: encode_chat_body(request)

  defp encode_chat_body(request) do
    context_data =
      case request.options[:context] do
        %ReqLLM.Context{} = ctx ->
          model_name = request.options[:model]
          encode_context_to_openai_format(ctx, model_name)

        _ ->
          %{messages: request.options[:messages] || []}
      end

    model_name = request.options[:model]

    body =
      %{model: model_name}
      |> Map.merge(context_data)
      |> add_basic_options(request.options)
      |> maybe_put(:stream, request.options[:stream])
      |> maybe_put(:max_tokens, request.options[:max_tokens])

    body =
      case request.options[:tools] do
        tools when is_list(tools) and tools != [] ->
          body = Map.put(body, :tools, Enum.map(tools, &ReqLLM.Tool.to_schema(&1, :openai)))

          case request.options[:tool_choice] do
            nil -> body
            choice -> Map.put(body, :tool_choice, choice)
          end

        _ ->
          body
      end

    case request.options[:response_format] do
      format when is_map(format) -> Map.put(body, :response_format, format)
      _ -> body
    end
  end

  defp encode_embedding_body(request) do
    input = request.options[:text]
    provider_opts = request.options[:provider_options] || []

    %{
      model: request.options[:model],
      input: input
    }
    |> maybe_put(:user, request.options[:user])
    |> maybe_put(:dimensions, provider_opts[:dimensions])
    |> maybe_put(:encoding_format, provider_opts[:encoding_format])
  end

  defp encode_response_body(request) do
    # For Responses API, we need to convert the context to a prompt
    prompt = case request.options[:context] do
      %ReqLLM.Context{} = context ->
        # Convert context messages to a single prompt string
        context
        |> Enum.map(fn
          %ReqLLM.Message{role: :system, content: content} ->
            "System: #{extract_text_from_content(content)}"
          %ReqLLM.Message{role: :user, content: content} ->
            "User: #{extract_text_from_content(content)}"
          %ReqLLM.Message{role: :assistant, content: content} ->
            "Assistant: #{extract_text_from_content(content)}"
        end)
        |> Enum.join("\n\n")

      _ ->
        # Fallback to input if context not available
        request.options[:input] || ""
    end

    base_body = %{
      model: request.options[:model],
      input: prompt
    }

    # Add basic options that are supported by Responses API
    base_body
    |> maybe_put(:temperature, request.options[:temperature])
    |> maybe_put(:max_tokens, request.options[:max_tokens])
    |> maybe_put(:stream, request.options[:stream])
    |> maybe_put(:user, request.options[:user])
  end

  # Helper function to extract text content from message content parts
  defp extract_text_from_content(content) when is_binary(content), do: content
  defp extract_text_from_content(content) when is_list(content) do
    content
    |> Enum.filter(&match?(%{type: :text}, &1))
    |> Enum.map(&Map.get(&1, :text, ""))
    |> Enum.join(" ")
  end
  defp extract_text_from_content(_), do: ""

  defp add_basic_options(body, request_options) do
    body_options = [
      :temperature,
      :top_p,
      :frequency_penalty,
      :presence_penalty,
      :user,
      :seed,
      :stop
    ]

    Enum.reduce(body_options, body, fn key, acc ->
      maybe_put(acc, key, request_options[key])
    end)
  end

  defp decode_success_response(req, resp) do
    operation = req.options[:operation]

    case operation do
      :embedding ->
        decode_embedding_response(req, resp)

      _ ->
        decode_chat_response(req, resp, operation)
    end
  end

  defp decode_error_response(req, resp, status) do
    # Get provider name from the stored model or fallback to parsing model string
    provider_name =
      case req.private[:req_llm_model] do
        %ReqLLM.Model{provider: provider_id} ->
          case provider_id do
            :openrouter -> "OpenRouter"
            other -> other |> Atom.to_string() |> String.capitalize()
          end

        _ ->
          # Fallback to parsing model name if req_llm_model not available
          case req.options[:model] do
            nil ->
              "Unknown"

            model_str ->
              prefix = model_str |> String.split(":") |> List.first()

              case prefix do
                "openrouter" -> "OpenRouter"
                other -> String.capitalize(other)
              end
          end
      end

    err =
      ReqLLM.Error.API.Response.exception(
        reason: "#{provider_name} API error",
        status: status,
        response_body: resp.body
      )

    {req, err}
  end

  defp decode_embedding_response(req, resp) do
    body = ensure_parsed_body(resp.body)
    {req, %{resp | body: body}}
  end

  defp decode_chat_response(req, resp, operation) do
    model_name = req.options[:model]

    # Handle case where model_name might be nil (for tests or edge cases)
    {_provider_id, model} =
      case model_name do
        nil ->
          # Fallback to private req_llm_model or extract from stored model
          case req.private[:req_llm_model] do
            %ReqLLM.Model{} = stored_model -> {stored_model.provider, stored_model}
            _ -> {:unknown, %ReqLLM.Model{provider: :unknown, model: "unknown"}}
          end

        model_name when is_binary(model_name) ->
          provider_id = String.split(model_name, ":") |> List.first() |> String.to_atom()
          model = %ReqLLM.Model{provider: provider_id, model: model_name}
          {provider_id, model}
      end

    is_streaming = req.options[:stream] == true

    if is_streaming do
      decode_streaming_response(req, resp, model_name)
    else
      decode_non_streaming_response(req, resp, model, operation)
    end
  end

  defp decode_streaming_response(req, resp, model_name) do
    # Check if response body already has a stream (e.g., from tests)
    {stream, provider_meta} =
      case resp.body do
        %Stream{} = existing_stream ->
          # Test scenario - use existing stream, no http_task needed
          {existing_stream, %{}}

        _ ->
          # Real-time streaming - use the stream created by Stream step
          # The request has already been initiated by the initial Req.request call
          # We just need to return the configured stream, not make another request
          real_time_stream = Req.Request.get_private(req, :real_time_stream, [])

          {real_time_stream, %{}}
      end

    response = %ReqLLM.Response{
      id: "stream-#{System.unique_integer([:positive])}",
      model: model_name,
      context: req.options[:context] || %ReqLLM.Context{messages: []},
      message: nil,
      stream?: true,
      stream: stream,
      usage: %{input_tokens: 0, output_tokens: 0, total_tokens: 0},
      finish_reason: nil,
      provider_meta: provider_meta
    }

    {req, %{resp | body: response}}
  end

  defp decode_non_streaming_response(req, resp, model, operation) do
    body = ensure_parsed_body(resp.body)
    {:ok, response} = decode_response_body_openai_format(body, model)

    final_response =
      case operation do
        :object ->
          extract_and_set_object(response)

        _ ->
          response
      end

    merged_response = merge_response_with_context(req, final_response)
    {req, %{resp | body: merged_response}}
  end

  defp extract_and_set_object(response) do
    extracted_object =
      case ReqLLM.Response.tool_calls(response) do
        [] ->
          nil

        tool_calls ->
          case Enum.find(tool_calls, &(&1.name == "structured_output")) do
            nil -> nil
            %{arguments: object} -> object
          end
      end

    %{response | object: extracted_object}
  end

  defp merge_response_with_context(req, response) do
    context = req.options[:context] || %ReqLLM.Context{messages: []}
    ReqLLM.Context.merge_response(context, response)
  end
end
