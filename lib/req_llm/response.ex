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
      ReqLLM.Response.text(response)  #=> "Hello! I'm Claude."
      ReqLLM.Response.usage(response)  #=> %{input_tokens: 12, output_tokens: 4, total_cost: 0.016}

      # Multi-turn conversation (no manual context building)
      {:ok, response2} = ReqLLM.generate_text("anthropic:claude-3-sonnet", response.context)

  """

  alias ReqLLM.Message
  alias ReqLLM.Response.OutputItem
  alias ReqLLM.ToolCall

  @derive {Jason.Encoder, except: [:stream]}

  @schema Zoi.struct(__MODULE__, %{
            id: Zoi.string(),
            model: Zoi.string(),
            context: Zoi.any(),
            message: Zoi.any() |> Zoi.default(nil),
            object: Zoi.union([Zoi.map(), Zoi.null()]) |> Zoi.default(nil),
            stream?: Zoi.boolean() |> Zoi.default(false),
            stream: Zoi.any() |> Zoi.default(nil),
            usage: Zoi.union([Zoi.map(), Zoi.null()]) |> Zoi.default(nil),
            finish_reason:
              Zoi.union([
                Zoi.literal(:stop),
                Zoi.literal(:length),
                Zoi.literal(:tool_calls),
                Zoi.literal(:content_filter),
                Zoi.literal(:error),
                Zoi.literal(:cancelled),
                Zoi.literal(:incomplete),
                Zoi.literal(:unknown),
                Zoi.null()
              ])
              |> Zoi.default(nil),
            provider_meta: Zoi.map() |> Zoi.default(%{}),
            error: Zoi.any() |> Zoi.default(nil)
          })

  @type t :: unquote(Zoi.type_spec(@schema))

  @typedoc """
  Computed metadata for one model interaction.

  Optional keys are present only when their values were retained by the
  provider path. `attempts` never includes separate model interactions from
  the response context.
  """
  @type call_metadata :: %{
          required(:response_id) => String.t(),
          required(:model) => String.t(),
          optional(:finish_reason) => atom(),
          optional(:usage) => map(),
          optional(:request_id) => String.t(),
          optional(:raw_finish_reason) => String.t() | atom(),
          optional(:warnings) => [String.t()],
          optional(:attempts) => non_neg_integer(),
          optional(:timings) => map(),
          optional(:provider_metadata) => map()
        }

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  def schema, do: @schema

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
  Projects the value described by a `ReqLLM.Output` descriptor.

  This is a computed view over the unchanged response. Plain text delegates to
  `text/1`; object output uses the existing `object` value; array, choice, and
  JSON outputs unwrap the private compatibility envelope used by providers that
  require a top-level object schema.

  Raw text, structured tool-call arguments, usage, and provider metadata remain
  available through their existing accessors. This projection follows the
  current V1 structured-output validation and repair behavior.
  """
  @spec output(t(), ReqLLM.Output.t()) :: term()
  def output(%__MODULE__{} = response, %ReqLLM.Output{} = descriptor) do
    ReqLLM.Output.value(descriptor, response)
  end

  @doc """
  Extract image content parts from the response message.

  Returns a list of `ReqLLM.Message.ContentPart` where `type` is `:image` or `:image_url`.
  """
  @spec images(t()) :: [ReqLLM.Message.ContentPart.t()]
  def images(%__MODULE__{message: nil}), do: []

  def images(%__MODULE__{message: %Message{content: content}}) do
    content
    |> Enum.filter(&(&1.type in [:image, :image_url]))
  end

  @doc """
  Returns the first image content part (or nil if none).
  """
  @spec image(t()) :: ReqLLM.Message.ContentPart.t() | nil
  def image(%__MODULE__{} = response) do
    response
    |> images()
    |> List.first()
  end

  @doc """
  Returns the binary data of the first `:image` part (or nil).
  """
  @spec image_data(t()) :: binary() | nil
  def image_data(%__MODULE__{} = response) do
    case response |> images() |> Enum.find(&(&1.type == :image)) do
      nil -> nil
      part -> part.data
    end
  end

  @doc """
  Returns the URL of the first `:image_url` part (or nil).
  """
  @spec image_url(t()) :: String.t() | nil
  def image_url(%__MODULE__{} = response) do
    case response |> images() |> Enum.find(&(&1.type == :image_url)) do
      nil -> nil
      part -> part.url
    end
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
  Provider responses expose tool calls as `ReqLLM.ToolCall` structs. Use struct
  field access such as `call.id` and `call.function.name`, or call
  `ReqLLM.ToolCall.to_map/1` when you need decoded arguments in a plain map.
  Use `classify/1` when you want response text, finish reason, and normalized
  tool call maps in one value.

  ## Examples

      iex> ReqLLM.Response.tool_calls(response)
      [%ReqLLM.ToolCall{id: "call_123", type: "function", function: %{name: "get_weather", arguments: ~s({"location":"San Francisco"})}}]

  """
  @spec tool_calls(t()) :: [ToolCall.t()]
  def tool_calls(%__MODULE__{message: nil}), do: []

  def tool_calls(%__MODULE__{message: %Message{tool_calls: tool_calls}})
      when is_list(tool_calls) do
    tool_calls
  end

  def tool_calls(%__MODULE__{message: %Message{tool_calls: nil}}), do: []

  @doc """
  Return a deterministic canonical projection of values retained by this response.

  Message content keeps its existing order. Tool calls follow content because
  the V1 `ReqLLM.Message` contract stores tool calls separately and does not
  retain their original interleaving. Sources, annotations, refusals, and
  provider-native items retained only in metadata follow the message values.

  This function does not add fields to or mutate `ReqLLM.Response`.
  """
  @spec output_items(t()) :: [OutputItem.t()]
  def output_items(%__MODULE__{} = response) do
    ReqLLM.Response.Projection.output_items(response)
  end

  @doc "Returns canonical output items grouped into stable result channels."
  @spec channels(t()) :: %{OutputItem.channel() => [OutputItem.t()]}
  def channels(%__MODULE__{} = response) do
    items = output_items(response)

    Map.new(OutputItem.channels(), fn channel ->
      {channel, Enum.filter(items, &(OutputItem.channel(&1) == channel))}
    end)
  end

  @doc "Returns canonical output items for one stable result channel."
  @spec channel_items(t(), OutputItem.channel()) :: [OutputItem.t()]
  def channel_items(%__MODULE__{} = response, channel) do
    response
    |> output_items()
    |> Enum.filter(&(OutputItem.channel(&1) == channel))
  end

  @doc "Returns generated file content parts retained by this response."
  @spec files(t()) :: [ReqLLM.Message.ContentPart.t()]
  def files(%__MODULE__{} = response) do
    response
    |> output_items()
    |> Enum.flat_map(fn
      %OutputItem{type: :file, data: %ReqLLM.Message.ContentPart{} = part} -> [part]
      _item -> []
    end)
  end

  @doc "Returns source values retained by content or provider metadata."
  @spec sources(t()) :: [term()]
  def sources(%__MODULE__{} = response) do
    response
    |> channel_items(:sources)
    |> Enum.map(& &1.data)
  end

  @doc "Returns annotation values retained by content or provider metadata."
  @spec annotations(t()) :: [term()]
  def annotations(%__MODULE__{} = response) do
    response
    |> channel_items(:annotations)
    |> Enum.map(& &1.data)
  end

  @doc "Returns refusal values retained by content or provider metadata."
  @spec refusals(t()) :: [term()]
  def refusals(%__MODULE__{} = response) do
    response
    |> channel_items(:refusals)
    |> Enum.map(& &1.data)
  end

  @doc "Returns provider-native output values retained by this response."
  @spec provider_items(t()) :: [term()]
  def provider_items(%__MODULE__{} = response) do
    response
    |> channel_items(:provider)
    |> Enum.map(& &1.data)
  end

  @doc """
  Return a redacted call-metadata projection over existing response values.

  The projection includes response identity, normalized finish reason, usage,
  and safe provider metadata when available. Request IDs, raw finish reasons,
  warnings, attempt counts, and timings are omitted unless the provider path
  already retained them. Credentials, prompts, file payloads, and hidden
  reasoning metadata are redacted recursively.

  This function does not enable additional provider capture or alter legacy
  response serialization.
  """
  @spec call_metadata(t()) :: call_metadata()
  def call_metadata(%__MODULE__{} = response) do
    ReqLLM.Response.Projection.call_metadata(response)
  end

  @typedoc """
  Result of classifying a non-streaming response.

  - `type` - `:tool_calls` when tools should be executed, `:final_answer` otherwise
  - `text` - Assistant text content
  - `thinking` - Assistant thinking content
  - `tool_calls` - Normalized tool call maps with `:id`, `:name`, and `:arguments`
  - `finish_reason` - Normalized finish reason atom
  """
  @type classify_result :: %{
          type: :tool_calls | :final_answer,
          text: String.t(),
          thinking: String.t(),
          tool_calls: [map()],
          finish_reason:
            :stop
            | :length
            | :tool_calls
            | :content_filter
            | :error
            | :cancelled
            | :incomplete
            | :unknown
            | nil
        }

  @doc """
  Classify a non-streaming response for tool-calling workflows.

  Returns a map with stream-parity shape:
  `%{type, text, thinking, tool_calls, finish_reason}`.
  """
  @spec classify(t()) :: classify_result()
  def classify(%__MODULE__{} = response) do
    text = text(response) || ""
    thinking = thinking(response) || ""
    normalized_tool_calls = normalize_tool_calls_for_classify(tool_calls(response))

    raw_finish_reason =
      response
      |> Map.from_struct()
      |> Map.get(:finish_reason)

    normalized_finish_reason =
      raw_finish_reason
      |> reason_to_string_for_classify()
      |> normalize_finish_reason_for_classify()

    actionable_tool_calls = Enum.reject(normalized_tool_calls, &ToolCall.flagged_builtin?/1)

    type =
      cond do
        actionable_tool_calls != [] -> :tool_calls
        normalized_finish_reason == :tool_calls -> :tool_calls
        true -> :final_answer
      end

    %{
      type: type,
      text: text,
      thinking: thinking,
      tool_calls: normalized_tool_calls,
      finish_reason: normalized_finish_reason
    }
  end

  @doc """
  Get the finish reason for this response.

  ## Examples

      iex> ReqLLM.Response.finish_reason(response)
      :stop

  """
  @spec finish_reason(t()) ::
          :stop
          | :length
          | :tool_calls
          | :content_filter
          | :error
          | :cancelled
          | :incomplete
          | :unknown
          | nil
  def finish_reason(%__MODULE__{finish_reason: reason}), do: reason

  @doc """
  Get usage statistics for this response.

  Provider-native cache reads are reported in `usage.cached_tokens` because the
  request still hit the upstream API. Application-layer response cache hits
  instead return a zeroed usage map and set
  `response.provider_meta.response_cache_hit` to `true`.

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
    usage[:reasoning_tokens] || usage[:reasoning] ||
      get_in(usage, [:completion_tokens_details, :reasoning_tokens]) || 0
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

  Supports inline model maps, `%LLMDB.Model{}` structs, strings, and tuples, automatically resolving model
  specifications using ReqLLM.model/1.

  ## Parameters

    * `raw_data` - Raw provider response data or Stream
    * `model_spec` - Model specification in any format supported by ReqLLM.model/1:
      - String: `"anthropic:claude-3-sonnet"`
      - Tuple: `{:anthropic, "claude-3-sonnet", temperature: 0.7}`
      - Map: `%{provider: :openai, id: "gpt-6-mini"}`
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
          ReqLLM.model_input()
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
          ReqLLM.model_input(),
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
          ReqLLM.model_input(),
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
  @spec unwrap_object(t(), keyword()) :: {:ok, map() | list()} | {:error, term()}
  def unwrap_object(response, opts \\ [])

  def unwrap_object(%__MODULE__{object: object}, _opts) when not is_nil(object) do
    {:ok, object}
  end

  def unwrap_object(%__MODULE__{message: nil}, _opts) do
    {:error, %ReqLLM.Error.API.Response{reason: "No message in response"}}
  end

  def unwrap_object(%__MODULE__{message: %Message{content: content}}, opts) do
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
        case ReqLLM.JSON.decode(text_content, opts) do
          {:ok, object} when is_map(object) ->
            {:ok, object}

          {:ok, array} when is_list(array) ->
            {:ok, array}

          {:ok, _other} ->
            {:error, %ReqLLM.Error.API.Response{reason: "Decoded JSON is not an object"}}

          {:error, _} ->
            {:error, %ReqLLM.Error.API.Response{reason: "Failed to parse JSON from text content"}}
        end

      true ->
        {:error, %ReqLLM.Error.API.Response{reason: "No structured output found in response"}}
    end
  end

  defp normalize_tool_calls_for_classify(tool_calls) when is_list(tool_calls) do
    tool_calls
    |> Enum.map(&normalize_tool_call_for_classify/1)
    |> Enum.filter(&(is_map(&1) and is_binary(Map.get(&1, :name))))
  end

  defp normalize_tool_call_for_classify(%ToolCall{} = tool_call) do
    tool_call
    |> ToolCall.to_map()
    |> ToolCall.put_builtin_flag(ToolCall.builtin?(tool_call))
  end

  defp normalize_tool_call_for_classify(%{id: id, name: name, arguments: args} = m) do
    %{
      id: normalize_tool_call_id(id),
      name: name,
      arguments: parse_tool_call_arguments(args)
    }
    |> ToolCall.put_builtin_flag(ToolCall.flagged_builtin?(m))
  end

  defp normalize_tool_call_for_classify(%{"id" => id, "name" => name, "arguments" => args} = m) do
    %{
      id: normalize_tool_call_id(id),
      name: name,
      arguments: parse_tool_call_arguments(args)
    }
    |> ToolCall.put_builtin_flag(ToolCall.flagged_builtin?(m))
  end

  defp normalize_tool_call_for_classify(
         %{function: %{name: name, arguments: args} = function} = tool_call
       ) do
    id = Map.get(tool_call, :id)

    %{
      id: normalize_tool_call_id(id),
      name: name,
      arguments: parse_tool_call_arguments(args)
    }
    |> ToolCall.put_builtin_flag(
      ToolCall.flagged_builtin?(tool_call) or ToolCall.flagged_builtin?(function)
    )
  end

  defp normalize_tool_call_for_classify(
         %{"function" => %{"name" => name, "arguments" => args} = function} = tool_call
       ) do
    id = Map.get(tool_call, "id")

    %{
      id: normalize_tool_call_id(id),
      name: name,
      arguments: parse_tool_call_arguments(args)
    }
    |> ToolCall.put_builtin_flag(
      ToolCall.flagged_builtin?(tool_call) or ToolCall.flagged_builtin?(function)
    )
  end

  defp normalize_tool_call_for_classify(_), do: nil

  defp normalize_tool_call_id(nil), do: ""
  defp normalize_tool_call_id(id) when is_binary(id), do: id
  defp normalize_tool_call_id(id) when is_atom(id), do: Atom.to_string(id)
  defp normalize_tool_call_id(id) when is_number(id), do: to_string(id)
  defp normalize_tool_call_id(id), do: inspect(id)

  defp parse_tool_call_arguments(arguments) when is_map(arguments), do: arguments

  defp parse_tool_call_arguments(arguments) when is_binary(arguments) do
    case Jason.decode(arguments) do
      {:ok, parsed} when is_map(parsed) -> parsed
      _ -> %{}
    end
  end

  defp parse_tool_call_arguments(_), do: %{}

  defp reason_to_string_for_classify(nil), do: nil
  defp reason_to_string_for_classify(reason) when is_binary(reason), do: reason
  defp reason_to_string_for_classify(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_to_string_for_classify(_), do: "__unknown__"

  defp normalize_finish_reason_for_classify(nil), do: nil
  defp normalize_finish_reason_for_classify("stop"), do: :stop
  defp normalize_finish_reason_for_classify("completed"), do: :stop
  defp normalize_finish_reason_for_classify("tool_calls"), do: :tool_calls
  defp normalize_finish_reason_for_classify("tool_use"), do: :tool_calls
  defp normalize_finish_reason_for_classify("length"), do: :length
  defp normalize_finish_reason_for_classify("max_tokens"), do: :length
  defp normalize_finish_reason_for_classify("max_output_tokens"), do: :length
  defp normalize_finish_reason_for_classify("content_filter"), do: :content_filter
  defp normalize_finish_reason_for_classify("end_turn"), do: :stop
  defp normalize_finish_reason_for_classify("error"), do: :error
  defp normalize_finish_reason_for_classify("cancelled"), do: :cancelled
  defp normalize_finish_reason_for_classify("incomplete"), do: :incomplete
  defp normalize_finish_reason_for_classify("unknown"), do: :unknown
  defp normalize_finish_reason_for_classify(_), do: :unknown
end
