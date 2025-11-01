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
  - `decode_stream_event/2` - OpenAI-compatible SSE event decoding
  - `attach_stream/4` - OpenAI-compatible streaming request building
  - `display_name/0` - Human-readable provider name from provider_id

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
  - `default_decode_stream_event/2`
  - `default_attach_stream/5`
  - `default_display_name/1`

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
      def attach(request, model_input, user_opts) do
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
      Default implementation of decode_stream_event/2.

      Decodes SSE events using OpenAI-compatible format.
      """
      @impl ReqLLM.Provider
      def decode_stream_event(event, model) do
        ReqLLM.Provider.Defaults.default_decode_stream_event(event, model)
      end

      @doc """
      Default implementation of attach_stream/4.

      Builds complete streaming requests using OpenAI-compatible format.
      """
      @impl ReqLLM.Provider
      def attach_stream(model, context, opts, finch_name) do
        ReqLLM.Provider.Defaults.default_attach_stream(
          __MODULE__,
          model,
          context,
          opts,
          finch_name
        )
      end

      # Make all default implementations overridable
      defoverridable prepare_request: 4,
                     attach: 3,
                     encode_body: 1,
                     decode_response: 1,
                     extract_usage: 2,
                     translate_options: 3,
                     decode_stream_event: 2,
                     attach_stream: 4
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

      :object ->
        prepare_object_request(provider_mod, model_spec, input, opts)

      :embedding ->
        prepare_embedding_request(provider_mod, model_spec, input, opts)

      _ ->
        supported_operations = [:chat, :object, :embedding]

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
      [
        :model,
        :compiled_schema,
        :temperature,
        :max_tokens,
        :app_referer,
        :app_title,
        :fixture,
        :api_key
      ] ++
        provider_mod.supported_provider_options()

    request
    |> Req.Request.put_header("content-type", "application/json")
    |> Req.Request.put_header("authorization", "Bearer #{api_key}")
    |> Req.Request.register_options(extra_option_keys)
    |> Req.Request.merge_options([model: model.model, auth: {:bearer, api_key}] ++ user_opts)
    |> ReqLLM.Step.Retry.attach()
    |> ReqLLM.Step.Error.attach()
    |> Req.Request.append_request_steps(llm_encode_body: &provider_mod.encode_body/1)
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

  @doc """
  Default implementation of attach_stream/4.

  Builds complete streaming requests using OpenAI-compatible format and returns
  a complete Finch.Request.t() ready for streaming execution.
  """
  @spec default_attach_stream(
          module(),
          ReqLLM.Model.t(),
          ReqLLM.Context.t(),
          keyword(),
          atom()
        ) :: {:ok, Finch.Request.t()} | {:error, Exception.t()}
  def default_attach_stream(provider_mod, model, context, opts, _finch_name) do
    # Get API key
    api_key = ReqLLM.Keys.get!(model, opts)

    # Get streaming HTTP configuration using legacy streaming_http/3
    # This will be called on providers that define streaming_http/3
    stream_config =
      if function_exported?(provider_mod, :streaming_http, 3) do
        provider_mod.streaming_http(model, api_key, opts)
      else
        # Fallback to default OpenAI-compatible config
        %{
          path: "/chat/completions",
          headers: [
            {"Authorization", "Bearer " <> api_key},
            {"Content-Type", "application/json"}
          ]
        }
      end

    path = Map.fetch!(stream_config, :path)
    base_headers = Map.fetch!(stream_config, :headers)

    # Merge headers from streaming config
    headers = base_headers ++ [{"Accept", "text/event-stream"}]

    # Build URL
    method = :post

    base_url = ReqLLM.Provider.Options.effective_base_url(provider_mod, model, opts)
    url = "#{base_url}#{path}"

    # Build request body using provider's encode logic
    body = build_streaming_body(provider_mod, model, context, opts)

    # Create Finch request
    finch_request = Finch.build(method, url, headers, body)
    {:ok, finch_request}
  rescue
    error ->
      {:error,
       ReqLLM.Error.API.Request.exception(
         reason: "Failed to build stream request: #{inspect(error)}"
       )}
  end

  @doc """
  Default display name implementation.

  Returns a human-readable display name based on the provider_id from DSL,
  or falls back to capitalizing the module name.
  """
  @spec default_display_name(module()) :: String.t()
  def default_display_name(provider_mod) do
    # Try to get provider_id from DSL metadata first
    case function_exported?(provider_mod, :provider_id, 0) do
      true ->
        provider_mod.provider_id()
        |> Atom.to_string()
        |> String.capitalize()

      false ->
        # Fallback to module name
        provider_mod
        |> Module.split()
        |> List.last()
        |> String.replace("Provider", "")
    end
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
         role: r,
         content: c,
         tool_calls: tc,
         tool_call_id: tcid,
         name: name
       }) do
    base_message = %{
      role: to_string(r),
      content: encode_openai_content(c)
    }

    base_message
    |> maybe_add_field(:tool_calls, tc)
    |> maybe_add_field(:tool_call_id, tcid)
    |> maybe_add_field(:name, name)
  end

  defp maybe_add_field(message, _key, nil), do: message
  defp maybe_add_field(message, _key, []), do: message
  defp maybe_add_field(message, key, value), do: Map.put(message, key, value)

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
         type: :image,
         data: data,
         media_type: media_type
       }) do
    base64 = Base.encode64(data)

    %{
      type: "image_url",
      image_url: %{
        url: "data:#{media_type};base64,#{base64}"
      }
    }
  end

  defp encode_openai_content_part(%ReqLLM.Message.ContentPart{type: :image_url, url: url}) do
    %{
      type: "image_url",
      image_url: %{
        url: url
      }
    }
  end

  defp encode_openai_content_part(%ReqLLM.Message.ContentPart{
         type: :file,
         data: data,
         media_type: media_type
       })
       when is_binary(data) do
    # Encode file as image_url data URI (OpenAI format supports various media types this way)
    base64 = Base.encode64(data)

    %{
      type: "image_url",
      image_url: %{
        url: "data:#{media_type};base64,#{base64}"
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
      messages: if(is_nil(message), do: [], else: [message])
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
  @spec default_decode_stream_event(map(), ReqLLM.Model.t()) :: [ReqLLM.StreamChunk.t()]
  def default_decode_stream_event(%{data: data}, model) when is_map(data) do
    case data do
      %{"choices" => [%{"delta" => delta} | _], "usage" => usage} ->
        # Stream chunk with usage metadata
        chunks = decode_openai_delta(delta)
        usage_chunk = ReqLLM.StreamChunk.meta(%{usage: usage, model: model.model})
        chunks ++ [usage_chunk]

      %{"choices" => [], "usage" => usage} ->
        # Final usage-only chunk (OpenAI streaming with stream_options.include_usage)
        [ReqLLM.StreamChunk.meta(%{usage: usage, model: model.model, terminal?: true})]

      %{"choices" => [%{"delta" => delta, "finish_reason" => finish_reason} | _]}
      when finish_reason != nil ->
        # Final chunk with finish reason
        chunks = decode_openai_delta(delta)
        normalized_reason = parse_openai_finish_reason(finish_reason)
        meta_chunk = ReqLLM.StreamChunk.meta(%{finish_reason: normalized_reason, terminal?: true})
        chunks ++ [meta_chunk]

      %{"choices" => [%{"delta" => delta} | _]} ->
        decode_openai_delta(delta)

      _ ->
        []
    end
  end

  # Handle terminal [DONE] event
  def default_decode_stream_event(%{data: "[DONE]"}, _model) do
    [ReqLLM.StreamChunk.meta(%{terminal?: true})]
  end

  def default_decode_stream_event(_, _model), do: []

  defp decode_openai_message(message) when is_map(message) do
    content_chunks = decode_openai_content(message)
    reasoning_chunks = decode_openai_reasoning(message)
    tool_call_chunks = decode_openai_tool_calls(message)
    content_chunks ++ reasoning_chunks ++ tool_call_chunks
  end

  defp decode_openai_message(_), do: []

  defp decode_openai_content(%{"content" => content}) when is_binary(content) and content != "" do
    [ReqLLM.StreamChunk.text(content)]
  end

  defp decode_openai_content(%{"content" => content}) when is_list(content) do
    content
    |> Enum.map(&decode_openai_content_part/1)
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  defp decode_openai_content(_), do: []

  defp decode_openai_reasoning(%{"reasoning" => reasoning})
       when is_binary(reasoning) and reasoning != "" do
    [ReqLLM.StreamChunk.thinking(reasoning)]
  end

  defp decode_openai_reasoning(%{"reasoning_content" => reasoning})
       when is_binary(reasoning) and reasoning != "" do
    [ReqLLM.StreamChunk.thinking(reasoning)]
  end

  defp decode_openai_reasoning(_), do: []

  defp decode_openai_tool_calls(%{"tool_calls" => tool_calls}) when is_list(tool_calls) do
    tool_calls
    |> Enum.map(&decode_openai_tool_call/1)
    |> Enum.reject(&is_nil/1)
  end

  defp decode_openai_tool_calls(_), do: []

  defp decode_openai_content_part(%{"type" => "text", "text" => text}) do
    [ReqLLM.StreamChunk.text(text)]
  end

  defp decode_openai_content_part(%{"type" => "thinking", "thinking" => thinking}) do
    [ReqLLM.StreamChunk.thinking(thinking)]
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

  defp decode_openai_delta(%{"content" => parts}) when is_list(parts) do
    parts
    |> Enum.flat_map(&decode_openai_content_part/1)
    |> Enum.reject(&is_nil/1)
  end

  defp decode_openai_delta(%{"reasoning_content" => reasoning})
       when is_binary(reasoning) and reasoning != "" do
    [ReqLLM.StreamChunk.thinking(reasoning)]
  end

  defp decode_openai_delta(%{"reasoning" => reasoning})
       when is_binary(reasoning) and reasoning != "" do
    [ReqLLM.StreamChunk.thinking(reasoning)]
  end

  defp decode_openai_delta(%{"tool_calls" => tool_calls}) when is_list(tool_calls) do
    tool_calls
    |> Enum.map(&decode_openai_tool_call_delta/1)
    |> Enum.reject(&is_nil/1)
  end

  defp decode_openai_delta(_), do: []

  # Handle complete tool call delta with all fields
  defp decode_openai_tool_call_delta(%{
         "id" => id,
         "type" => "function",
         "index" => index,
         "function" => %{"name" => name, "arguments" => args_json}
       })
       when is_binary(name) do
    case Jason.decode(args_json || "{}") do
      {:ok, args} -> ReqLLM.StreamChunk.tool_call(name, args, %{id: id, index: index})
      {:error, _} -> ReqLLM.StreamChunk.tool_call(name, %{}, %{id: id, index: index})
    end
  end

  # Handle tool call delta with only name (arguments may come in later chunks)
  defp decode_openai_tool_call_delta(%{
         "id" => id,
         "type" => "function",
         "index" => index,
         "function" => %{"name" => name}
       })
       when is_binary(name) do
    ReqLLM.StreamChunk.tool_call(name, %{}, %{id: id, index: index})
  end

  # Handle partial argument chunks by storing them as metadata
  defp decode_openai_tool_call_delta(%{
         "function" => %{"arguments" => args_fragment},
         "index" => index
       }) do
    # Create a meta chunk that carries argument fragments for accumulation
    ReqLLM.StreamChunk.meta(%{
      tool_call_args: %{
        index: index,
        fragment: args_fragment
      }
    })
  end

  # Handle tool call without index field (legacy or non-streaming format)
  defp decode_openai_tool_call_delta(%{
         "id" => id,
         "type" => "function",
         "function" => %{"name" => name, "arguments" => args_json}
       })
       when is_binary(name) do
    case Jason.decode(args_json || "{}") do
      {:ok, args} -> ReqLLM.StreamChunk.tool_call(name, args, %{id: id})
      {:error, _} -> ReqLLM.StreamChunk.tool_call(name, %{}, %{id: id})
    end
  end

  # Handle malformed tool call deltas (some APIs send incomplete structures)
  defp decode_openai_tool_call_delta(%{"type" => "function", "function" => %{"name" => nil}}) do
    nil
  end

  defp decode_openai_tool_call_delta(%{"type" => "function", "function" => %{}}) do
    nil
  end

  defp decode_openai_tool_call_delta(_), do: nil

  defp build_openai_message_from_chunks(chunks) when is_list(chunks) and chunks != [] do
    content_parts =
      chunks
      |> Enum.filter(&(&1.type in [:content, :thinking]))
      |> Enum.map(&openai_chunk_to_content_part/1)
      |> Enum.reject(&is_nil/1)

    tool_calls =
      chunks
      |> Enum.filter(&(&1.type == :tool_call))
      |> Enum.map(&openai_chunk_to_tool_call/1)
      |> Enum.reject(&is_nil/1)

    %ReqLLM.Message{
      role: :assistant,
      content: content_parts,
      tool_calls: if(tool_calls != [], do: tool_calls),
      metadata: %{}
    }
  end

  defp build_openai_message_from_chunks(_), do: nil

  defp openai_chunk_to_content_part(%ReqLLM.StreamChunk{type: :content, text: text}) do
    %ReqLLM.Message.ContentPart{type: :text, text: text}
  end

  defp openai_chunk_to_content_part(%ReqLLM.StreamChunk{type: :thinking, text: text}) do
    %ReqLLM.Message.ContentPart{type: :thinking, text: text}
  end

  defp openai_chunk_to_content_part(_), do: nil

  defp openai_chunk_to_tool_call(%ReqLLM.StreamChunk{
         type: :tool_call,
         name: name,
         arguments: args,
         metadata: meta
       }) do
    args_json = if is_binary(args), do: args, else: Jason.encode!(args)
    id = Map.get(meta, :id)
    ReqLLM.ToolCall.new(id, name, args_json)
  end

  defp openai_chunk_to_tool_call(_), do: nil

  defp parse_openai_usage(
         %{"prompt_tokens" => input, "completion_tokens" => output, "total_tokens" => total} =
           usage
       ) do
    reasoning_tokens = get_in(usage, ["completion_tokens_details", "reasoning_tokens"]) || 0
    cached_tokens = get_in(usage, ["prompt_tokens_details", "cached_tokens"]) || 0

    %{
      input_tokens: input,
      output_tokens: output,
      total_tokens: total,
      cached_tokens: cached_tokens,
      reasoning_tokens: reasoning_tokens
    }
  end

  defp parse_openai_usage(_),
    do: %{
      input_tokens: 0,
      output_tokens: 0,
      total_tokens: 0,
      cached_tokens: 0,
      reasoning_tokens: 0
    }

  defp parse_openai_finish_reason("stop"), do: :stop
  defp parse_openai_finish_reason("length"), do: :length
  defp parse_openai_finish_reason("tool_calls"), do: :tool_calls
  defp parse_openai_finish_reason("content_filter"), do: :content_filter
  defp parse_openai_finish_reason("max_tokens"), do: :length
  defp parse_openai_finish_reason("max_output_tokens"), do: :length
  defp parse_openai_finish_reason(reason) when is_binary(reason), do: :error
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
      |> then(fn body ->
        if request.options[:stream],
          do: Map.put(body, :stream_options, %{include_usage: true}),
          else: body
      end)
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

    provider_opts = request.options[:provider_options] || []
    response_format = request.options[:response_format] || provider_opts[:response_format]

    case response_format do
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
    # Get provider name using the display_name/0 callback
    provider_name =
      case req.private[:req_llm_model] do
        %ReqLLM.Model{provider: provider_id} ->
          get_provider_display_name(provider_id)

        _ ->
          # Fallback to parsing model name if req_llm_model not available
          case req.options[:model] do
            nil ->
              "Unknown"

            model_str ->
              provider_id = model_str |> String.split(":") |> List.first() |> String.to_atom()
              get_provider_display_name(provider_id)
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
    {_provider_id, model, model_string} =
      case model_name do
        nil ->
          # Fallback to private req_llm_model or extract from stored model
          case req.private[:req_llm_model] do
            %ReqLLM.Model{} = stored_model ->
              {stored_model.provider, stored_model, stored_model.model}

            _ ->
              {:unknown, %ReqLLM.Model{provider: :unknown, model: "unknown"}, "unknown"}
          end

        %ReqLLM.Model{} = model_struct ->
          {model_struct.provider, model_struct, model_struct.model}

        model_name when is_binary(model_name) ->
          provider_id =
            String.split(model_name, ":", parts: 2) |> List.first() |> String.to_atom()

          model = %ReqLLM.Model{provider: provider_id, model: model_name}
          {provider_id, model, model_name}
      end

    is_streaming = req.options[:stream] == true

    if is_streaming do
      decode_streaming_response(req, resp, model_string)
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
      usage: %{
        input_tokens: 0,
        output_tokens: 0,
        total_tokens: 0,
        cached_tokens: 0,
        reasoning_tokens: 0
      },
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
          extract_and_set_object(response, req)

        _ ->
          response
      end

    merged_response = merge_response_with_context(req, final_response)
    {req, %{resp | body: merged_response}}
  end

  defp extract_and_set_object(response, req) do
    provider_opts = req.options[:provider_options] || []
    response_format = provider_opts[:response_format]

    extracted_object =
      case response_format do
        %{type: "json_schema"} ->
          extract_from_json_schema_content(response)

        %{"type" => "json_schema"} ->
          extract_from_json_schema_content(response)

        _ ->
          extract_from_tool_calls(response)
      end

    %{response | object: extracted_object}
  end

  defp extract_from_json_schema_content(response) do
    case response.message do
      %ReqLLM.Message{content: content_parts} when is_list(content_parts) ->
        text_content =
          content_parts
          |> Enum.find_value(fn
            %ReqLLM.Message.ContentPart{type: :text, text: text} when is_binary(text) -> text
            _ -> nil
          end)

        case text_content do
          nil ->
            nil

          json_string ->
            case Jason.decode(json_string) do
              {:ok, parsed_object} -> parsed_object
              {:error, _} -> nil
            end
        end

      _ ->
        nil
    end
  end

  defp extract_from_tool_calls(response) do
    response
    |> ReqLLM.Response.tool_calls()
    |> ReqLLM.ToolCall.find_args("structured_output")
  end

  defp merge_response_with_context(req, response) do
    context = req.options[:context] || %ReqLLM.Context{messages: []}
    ReqLLM.Context.merge_response(context, response)
  end

  # Helper functions for default stream request building

  defp build_streaming_body(provider_mod, model, context, opts) do
    # Create a temporary Req request to use existing encode_body logic
    req_opts =
      [
        model: model.model,
        context: context,
        stream: true
      ] ++ Keyword.delete(opts, :finch_name)

    # Create minimal request struct with required fields
    temp_request = %Req.Request{
      method: :post,
      url: URI.parse("https://example.com/temp"),
      headers: %{},
      body: {:json, %{}},
      options: Map.new(req_opts)
    }

    # Use provider's encode_body to build the JSON
    encoded_request = provider_mod.encode_body(temp_request)

    # Return the encoded body (should be JSON string)
    encoded_request.body
  rescue
    _error ->
      # Fallback to basic OpenAI-compatible streaming body structure
      build_fallback_streaming_body(model, context, opts)
  end

  defp build_fallback_streaming_body(model, context, opts) do
    # Convert context to basic OpenAI-compatible format
    messages =
      context.messages
      |> Enum.map(fn message ->
        # Extract text content from ContentPart list
        text_content =
          message.content
          |> Enum.filter(&(&1.type == :text))
          |> Enum.map_join("", & &1.text)

        %{
          role: message.role,
          content: text_content
        }
      end)

    body = %{
      model: model.model,
      messages: messages,
      stream: true
    }

    # Add optional parameters
    body
    |> maybe_add_streaming_param(:temperature, opts)
    |> maybe_add_streaming_param(:max_tokens, opts)
    |> maybe_add_streaming_param(:top_p, opts)
    |> Jason.encode!()
  end

  defp maybe_add_streaming_param(body, key, opts) do
    case Keyword.get(opts, key) do
      nil -> body
      value -> Map.put(body, key, value)
    end
  end

  # Helper function to get provider display name using display_name/0 callback
  defp get_provider_display_name(provider_id) do
    # Try to resolve the provider module
    provider_mod = ReqLLM.Provider.get!(provider_id)

    # Check if display_name/0 function exists and call it
    if function_exported?(provider_mod, :display_name, 0) do
      provider_mod.display_name()
    else
      # Fallback to capitalizing the provider_id
      provider_id |> Atom.to_string() |> String.capitalize()
    end
  rescue
    # Handle cases where provider can't be resolved
    _ ->
      provider_id |> Atom.to_string() |> String.capitalize()
  end
end
