defmodule ReqLLM.Response do
  @moduledoc """
  High-level representation of an LLM turn.

  Always contains a Context (full conversation history **including**
  the newly-generated assistant/tool messages) plus rich metadata and, when
  streaming, a lazy `Stream` of `ReqLLM.StreamChunk`s.

  This struct eliminates the need for manual message extraction and context building
  in multi-turn conversations and tool calling workflows.

  ## Examples

      # Basic response usage
      {:ok, response} = ReqLLM.generate_text("anthropic:claude-3-sonnet", context)
      response.text()  #=> "Hello! I'm Claude."
      response.usage()  #=> %{input_tokens: 12, output_tokens: 4, total_cost: 0.016}

      # Multi-turn conversation (no manual context building)
      {:ok, response2} = ReqLLM.generate_text("anthropic:claude-3-sonnet", response.context)

      # Tool calling loop
      {:ok, final_response} = ReqLLM.Response.handle_tools(response, tools)

  """

  use TypedStruct

  alias ReqLLM.{Context, Message}

  @derive {Jason.Encoder, except: [:stream]}

  typedstruct enforce: true do
    # ---------- Core ----------
    # Provider id of the turn
    field(:id, String.t())
    # Model that produced the turn
    field(:model, String.t())
    # History incl. new assistant msg
    field(:context, Context.t())
    # The assistant/tool message created by this turn
    field(:message, Message.t() | nil)
    # Structured object for object generation
    field(:object, map() | nil, default: nil)

    # ---------- Streams ----------
    field(:stream?, boolean(), default: false)
    # Stream of StreamChunk when stream? == true
    field(:stream, Enumerable.t() | nil, default: nil)

    # ---------- Metadata ----------
    field(:usage, map() | nil)
    field(:finish_reason, :stop | :length | :tool_calls | :content_filter | :error | nil)
    # Raw provider extras
    field(:provider_meta, map(), default: %{})

    # ---------- Errors ----------
    field(:error, Exception.t() | nil, default: nil)
  end

  @doc """
  Extract text content from the response message.

  Returns the concatenated text from all content parts in the assistant message.
  Returns nil when no message is present. For streaming responses, this may be nil
  until the stream is joined.

  ## Examples

      iex> ReqLLM.Response.text(response)
      "Hello! I'm Claude and I can help you with questions."

  """
  @spec text(t()) :: String.t() | nil
  def text(%__MODULE__{message: nil}), do: nil

  def text(%__MODULE__{message: %Message{content: content}}) do
    content
    |> Enum.filter(&(&1.type == :text))
    |> Enum.map_join("", & &1.text)
  end

  @doc """
  Extract thinking/reasoning content from the response message.

  Returns the concatenated thinking content if the message contains thinking parts, empty string otherwise.

  ## Examples

      iex> ReqLLM.Response.thinking(response)
      "The user is asking about the weather..."

  """
  @spec thinking(t()) :: String.t() | nil
  def thinking(%__MODULE__{message: nil}), do: nil

  def thinking(%__MODULE__{message: %Message{content: content}}) do
    content
    |> Enum.filter(&(&1.type == :thinking))
    |> Enum.map_join("", & &1.text)
  end

  @doc """
  Extract tool calls from the response message.

  Returns a list of tool calls if the message contains them, empty list otherwise.
  Always returns normalized maps with `.name` and `.arguments` fields.

  ## Examples

      iex> ReqLLM.Response.tool_calls(response)
      [%{name: "get_weather", arguments: %{location: "San Francisco"}}]

  """
  @spec tool_calls(t()) :: [term()]
  def tool_calls(%__MODULE__{message: nil}), do: []

  def tool_calls(%__MODULE__{message: %Message{tool_calls: tool_calls}})
      when is_list(tool_calls) do
    tool_calls
  end

  def tool_calls(%__MODULE__{message: %Message{tool_calls: nil}}), do: []

  @doc """
  Get the finish reason for this response.

  ## Examples

      iex> ReqLLM.Response.finish_reason(response)
      :stop

  """
  @spec finish_reason(t()) :: :stop | :length | :tool_calls | :content_filter | :error | nil
  def finish_reason(%__MODULE__{finish_reason: reason}), do: reason

  @doc """
  Get usage statistics for this response.

  ## Examples

      iex> ReqLLM.Response.usage(response)
      %{input_tokens: 12, output_tokens: 8, total_tokens: 20, reasoning_tokens: 64, input_cost: 0.01, output_cost: 0.02, total_cost: 0.03}

  """
  @spec usage(t()) :: map() | nil
  def usage(%__MODULE__{usage: usage}), do: usage

  @doc """
  Get reasoning token count from the response usage.

  Returns the number of reasoning tokens used by reasoning models (GPT-5, o1, o3, etc.)
  during their internal thinking process. Returns 0 if no reasoning tokens were used.

  ## Examples

      iex> ReqLLM.Response.reasoning_tokens(response)
      64

  """
  @spec reasoning_tokens(t()) :: integer()
  def reasoning_tokens(%__MODULE__{usage: %{reasoning_tokens: tokens}}) when is_integer(tokens),
    do: tokens

  def reasoning_tokens(%__MODULE__{usage: usage}) when is_map(usage) do
    # Try various possible keys for reasoning tokens
    usage[:reasoning_tokens] || usage["reasoning_tokens"] || usage[:reasoning] ||
      usage["reasoning"] || get_in(usage, [:completion_tokens_details, :reasoning_tokens]) ||
      get_in(usage, ["completion_tokens_details", "reasoning_tokens"]) || 0
  end

  def reasoning_tokens(%__MODULE__{}), do: 0

  @doc """
  Check if the response completed successfully without errors.

  ## Examples

      iex> ReqLLM.Response.ok?(response)
      true

  """
  @spec ok?(t()) :: boolean()
  def ok?(%__MODULE__{error: nil}), do: true
  def ok?(%__MODULE__{error: _error}), do: false

  @doc """
  Create a stream of text content chunks from a streaming response.

  Only yields content from :content type stream chunks, filtering out
  metadata and other chunk types.

  ## Examples

      response
      |> ReqLLM.Response.text_stream()
      |> Stream.each(&IO.write/1)
      |> Stream.run()

  """
  @spec text_stream(t()) :: Enumerable.t()
  def text_stream(%__MODULE__{stream?: false}), do: []
  def text_stream(%__MODULE__{stream: nil}), do: []

  def text_stream(%__MODULE__{stream: stream}) do
    stream
    |> Stream.filter(&(&1.type == :content))
    |> Stream.map(& &1.text)
  end

  # ---------- Stream Helpers ----------

  @doc """
  Create a stream of structured objects from a streaming response.

  Only yields valid objects from tool call stream chunks, filtering out
  metadata and other chunk types.

  ## Examples

      response
      |> ReqLLM.Response.object_stream()
      |> Stream.each(&IO.inspect/1)
      |> Stream.run()

  """
  @spec object_stream(t()) :: Enumerable.t()
  def object_stream(%__MODULE__{stream?: false}), do: []
  def object_stream(%__MODULE__{stream: nil}), do: []

  def object_stream(%__MODULE__{stream: stream}) do
    stream
    |> Stream.filter(&(&1.type == :tool_call))
    |> Stream.filter(&(&1.name == "structured_output"))
    |> Stream.map(& &1.arguments)
  end

  @doc """
  Materialize a streaming response into a complete response.

  Consumes the entire stream, builds the complete message, and returns
  a new response with the stream consumed and message populated.

  ## Examples

      {:ok, complete_response} = ReqLLM.Response.join_stream(streaming_response)

  """
  @spec join_stream(t()) :: {:ok, t()} | {:error, term()}
  def join_stream(%__MODULE__{stream?: false} = response), do: {:ok, response}
  def join_stream(%__MODULE__{stream: nil} = response), do: {:ok, response}

  def join_stream(%__MODULE__{stream: stream} = response) do
    ReqLLM.Response.Stream.join(stream, response)
  end

  @doc """
  Decode provider response data into a canonical ReqLLM.Response.

  This is a façade function that accepts raw provider data and a model specification,
  and directly calls the provider's decode_response/1 callback for zero-ceremony decoding.

  Supports Model struct, string, and tuple inputs, automatically resolving model
  specifications using ReqLLM.model/1.

  ## Parameters

    * `raw_data` - Raw provider response data or Stream
    * `model_spec` - Model specification in any format supported by ReqLLM.model/1:
      - String: `"anthropic:claude-3-sonnet"`
      - Tuple: `{:anthropic, "claude-3-sonnet", temperature: 0.7}`
      - LLMDB.Model struct: `%LLMDB.Model{provider: :anthropic, id: "claude-3-sonnet"}`

  ## Returns

    * `{:ok, %ReqLLM.Response{}}` on success
    * `{:error, reason}` on failure

  ## Examples

      {:ok, response} = ReqLLM.Response.decode_response(raw_json, "anthropic:claude-3-sonnet")
      {:ok, response} = ReqLLM.Response.decode_response(raw_json, model_struct)
      {:ok, response} = ReqLLM.Response.decode_response(raw_json, {:anthropic, "claude-3-sonnet"})

  """
  @spec decode_response(
          term(),
          LLMDB.Model.t() | String.t() | {atom(), String.t(), keyword()} | {atom(), keyword()}
        ) :: {:ok, t()} | {:error, term()}
  @dialyzer {:nowarn_function, decode_response: 2}
  def decode_response(raw_data, model_spec) do
    with {:ok, model} <- ReqLLM.model(model_spec),
         {:ok, provider_mod} <- ReqLLM.provider(model.provider) do
      wrapped_data =
        if function_exported?(provider_mod, :wrap_response, 1) do
          provider_mod.wrap_response(raw_data)
        else
          raw_data
        end

      fixture_request = %Req.Request{
        private: %{req_llm_model: model},
        options: %{model: model.id}
      }

      fixture_response = %Req.Response{body: wrapped_data, status: 200}
      {_req, result} = provider_mod.decode_response({fixture_request, fixture_response})

      case result do
        %Req.Response{body: %ReqLLM.Response{}} = resp ->
          {_req, final_resp} = ReqLLM.Step.Usage.handle({fixture_request, resp})
          {:ok, final_resp.body}

        error ->
          {:error, error}
      end
    end
  end

  @doc """
  Decode provider response data into a Response with structured object.

  Similar to decode_response/2 but specifically for object generation responses.
  Extracts the structured object from tool calls and validates it against the schema.

  ## Parameters

    * `raw_data` - Raw provider response data
    * `model_spec` - Model specification (supports all formats from ReqLLM.model/1)
    * `schema` - Schema definition for validation

  ## Returns

    * `{:ok, %ReqLLM.Response{}}` with object field populated on success
    * `{:error, reason}` on failure

  """
  @spec decode_object(
          term(),
          LLMDB.Model.t() | String.t() | {atom(), String.t(), keyword()} | {atom(), keyword()},
          keyword()
        ) ::
          {:ok, t()} | {:error, term()}
  def decode_object(raw_data, model_spec, schema) do
    with {:ok, response} <- decode_response(raw_data, model_spec),
         {:ok, object} <- extract_object_from_response(response, schema) do
      {:ok, %{response | object: object}}
    end
  end

  @doc """
  Decode provider streaming response data into a Response with object stream.

  Similar to decode_response/2 but for streaming object generation.
  The response will contain a stream of structured objects.

  ## Parameters

    * `raw_data` - Raw provider streaming response data
    * `model_spec` - Model specification (supports all formats from ReqLLM.model/1)
    * `schema` - Schema definition for validation

  ## Returns

    * `{:ok, %ReqLLM.Response{}}` with stream populated on success
    * `{:error, reason}` on failure

  """
  @spec decode_object_stream(
          term(),
          LLMDB.Model.t() | String.t() | {atom(), String.t(), keyword()} | {atom(), keyword()},
          keyword()
        ) ::
          {:ok, t()} | {:error, term()}
  def decode_object_stream(raw_data, model_spec, _schema) do
    decode_response(raw_data, model_spec)
  end

  # Helper function to extract structured object from tool calls
  defp extract_object_from_response(response, schema) do
    case tool_calls(response) do
      [] ->
        {:error, %ReqLLM.Error.API.Response{reason: "No structured output found in response"}}

      tool_calls ->
        # Find the structured_output tool call
        case Enum.find(tool_calls, &(&1.name == "structured_output")) do
          nil ->
            {:error, %ReqLLM.Error.API.Response{reason: "No structured_output tool call found"}}

          %{arguments: object} ->
            # Validate the extracted object against the original schema
            case ReqLLM.Schema.validate(object, schema) do
              {:ok, _validated_data} ->
                {:ok, object}

              {:error, validation_error} ->
                {:error,
                 %ReqLLM.Error.API.Response{
                   reason:
                     "Structured output failed schema validation: #{Exception.message(validation_error)}",
                   status: 422,
                   response_body: object
                 }}
            end
        end
    end
  end

  @doc """
  Extracts the generated object from a Response.
  """
  @spec object(t()) :: map() | nil
  def object(%__MODULE__{object: object}) do
    object
  end

  @doc """
  Unwraps the object from a structured output response, regardless of mode used.

  Handles extraction from:
  - json_schema mode: parses from content
  - tool modes: extracts from tool call arguments

  ## Examples

      {:ok, object} = ReqLLM.Response.unwrap_object(response)
      #=> {:ok, %{"name" => "John", "age" => 30}}

  """
  @spec unwrap_object(t()) :: {:ok, map()} | {:error, term()}
  def unwrap_object(%__MODULE__{object: object}) when not is_nil(object) do
    {:ok, object}
  end

  def unwrap_object(%__MODULE__{message: nil}) do
    {:error, %ReqLLM.Error.API.Response{reason: "No message in response"}}
  end

  def unwrap_object(%__MODULE__{message: %Message{content: content}}) do
    text_content =
      content
      |> Enum.filter(&(&1.type == :text))
      |> Enum.map_join("", & &1.text)

    tool_call_content =
      content
      |> Enum.find(&(&1.type == :tool_call && &1.tool_name == "structured_output"))

    cond do
      tool_call_content != nil ->
        {:ok, tool_call_content.input}

      text_content != "" ->
        case Jason.decode(text_content) do
          {:ok, object} when is_map(object) ->
            {:ok, object}

          {:ok, _other} ->
            {:error, %ReqLLM.Error.API.Response{reason: "Decoded JSON is not an object"}}

          {:error, _} ->
            {:error, %ReqLLM.Error.API.Response{reason: "Failed to parse JSON from text content"}}
        end

      true ->
        {:error, %ReqLLM.Error.API.Response{reason: "No structured output found in response"}}
    end
  end
end
