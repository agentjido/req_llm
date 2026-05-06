defmodule ReqLLM.Context do
  @moduledoc """
  Context represents a conversation history as a collection of messages.

  Provides canonical message constructor functions that can be imported
  for clean, readable message creation. Supports standard roles:
  `:user`, `:assistant`, `:system`, and `:tool`.

  ## Example

      import ReqLLM.Context

      context = Context.new([
        system("You are a helpful assistant"),
        user("What's the weather like?"),
        assistant("I'll check that for you")
      ])

      Context.validate!(context)

  ## Redacting context on inspect

  Set `config :req_llm, redact_context: true` to hide message contents
  from `inspect/2` output. When enabled, only the message count is shown:

      #Context<4 messages [REDACTED]>

  This prevents sensitive prompts from leaking into logs or crash reports.
  """

  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.ToolCall
  alias ReqLLM.ToolResult

  @schema Zoi.struct(__MODULE__, %{
            messages: Zoi.list(Zoi.any()) |> Zoi.default([]),
            tools: Zoi.list(Zoi.any()) |> Zoi.default([])
          })

  @derive Jason.Encoder
  @type t :: unquote(Zoi.type_spec(@schema))

  @typedoc """
  Any input accepted by `Context.normalize/2` as a prompt or messages parameter.

  Includes plain strings, single `Message` structs, `Context` structs,
  loose maps with `:role`/`:content` keys, and lists of any of those types.
  """
  @type prompt ::
          String.t()
          | Message.t()
          | t()
          | map()
          | [String.t() | Message.t() | t() | map()]

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  def schema, do: @schema

  # Canonical public interface

  @doc "Create a new Context from a list of messages (defaults to empty)."
  @spec new([Message.t()]) :: t()
  def new(list \\ []), do: %__MODULE__{messages: list}

  @doc "Return the underlying message list."
  @spec to_list(t()) :: [Message.t()]
  def to_list(%__MODULE__{messages: msgs}), do: msgs

  @doc "Append a message to the context."
  @spec append(t(), Message.t()) :: t()
  def append(%__MODULE__{messages: msgs} = ctx, %Message{} = msg) do
    %{ctx | messages: msgs ++ [msg]}
  end

  @spec append(t(), [Message.t()]) :: t()
  def append(%__MODULE__{} = ctx, msgs) when is_list(msgs) do
    %{ctx | messages: ctx.messages ++ msgs}
  end

  @doc "Prepend a message to the context."
  @spec prepend(t(), Message.t()) :: t()
  def prepend(%__MODULE__{messages: msgs} = ctx, %Message{} = msg) do
    %{ctx | messages: [msg | msgs]}
  end

  @doc "Concatenate two contexts."
  @spec concat(t(), t()) :: t()
  def concat(%__MODULE__{} = ctx, %__MODULE__{} = other) do
    %{ctx | messages: ctx.messages ++ other.messages}
  end

  @doc """
  Normalize any "prompt-ish" input into a validated ReqLLM.Context.

  Accepts various input types and converts them to a proper Context struct:
  - String: converts to user message
  - Message struct: wraps in Context
  - Context struct: passes through
  - List: processes each item and creates Context from all messages
  - Loose maps: converts to Message if they have role/content keys

  ## Options

    * `:system_prompt` - String to add as system message if none exists
    * `:validate` - Boolean to run validation (default: true)
    * `:convert_loose` - Boolean to allow loose maps with role/content (default: true)

  ## Examples

      # String to user message
      Context.normalize("Hello")
      #=> {:ok, %Context{messages: [%Message{role: :user, content: [%ContentPart{text: "Hello"}]}]}}

      # Add system prompt
      Context.normalize("Hello", system_prompt: "You are helpful")
      #=> {:ok, %Context{messages: [%Message{role: :system}, %Message{role: :user}]}}

      # List of mixed types
      Context.normalize([%Message{role: :system}, "Hello"])

  """
  @spec normalize(
          String.t()
          | Message.t()
          | t()
          | map()
          | [String.t() | Message.t() | t() | map()],
          keyword()
        ) :: {:ok, t()} | {:error, term()}
  def normalize(prompt, opts \\ []) do
    validate? = Keyword.get(opts, :validate, true)
    system_prompt = Keyword.get(opts, :system_prompt)
    convert_loose? = Keyword.get(opts, :convert_loose, true)

    with {:ok, ctx0} <- to_context(prompt, convert_loose?) do
      ctx1 = maybe_add_system(ctx0, system_prompt)

      if validate? do
        case validate(ctx1) do
          {:ok, ctx1} -> {:ok, ctx1}
          {:error, _} = error -> error
        end
      else
        {:ok, ctx1}
      end
    end
  end

  @doc """
  Bang version of normalize/2 that raises on error.
  """
  @spec normalize!(
          String.t()
          | Message.t()
          | t()
          | map()
          | [String.t() | Message.t() | t() | map()],
          keyword()
        ) :: t()
  def normalize!(prompt, opts \\ []) do
    case normalize(prompt, opts) do
      {:ok, context} -> context
      {:error, reason} -> raise ArgumentError, "Failed to normalize context: #{inspect(reason)}"
    end
  end

  @doc """
  Merges the original context with a response to create an updated context.

  Takes a context and a response, then creates a new context containing
  the original messages plus the assistant response message.

  ## Parameters

    * `context` - Original ReqLLM.Context
    * `response` - ReqLLM.Response containing the assistant message

  ## Returns

    * Updated response with merged context

  ## Examples

      context = ReqLLM.Context.new([user("Hello")])
      response = %ReqLLM.Response{message: assistant("Hi there!")}
      updated_response = ReqLLM.Context.merge_response(context, response)
      # response.context now contains both user and assistant messages

  """
  @spec merge_response(t(), ReqLLM.Response.t(), keyword()) :: ReqLLM.Response.t()
  def merge_response(context, response, opts \\ []) do
    case {context, response.message} do
      {%__MODULE__{} = ctx, %Message{} = msg} ->
        updated_messages = ctx.messages ++ [msg]
        tools = persist_tools(ctx.tools, Keyword.get(opts, :tools))
        updated_context = %__MODULE__{messages: updated_messages, tools: tools}
        %{response | context: updated_context}

      _ ->
        response
    end
  end

  # Role helpers

  @doc """
  Create a user message with optional metadata.

  Accepts a string or content parts list. Second argument can be a map (legacy)
  or keyword list with options.

  ## Options

    * `:metadata` - Map of metadata to attach to the message (default: %{})

  ## Examples

      user("Hello")
      user("Hello", %{source: "api"})
      user("Hello", metadata: %{source: "api"})
      user([ContentPart.text("Hello")], metadata: %{})

  """
  @spec user([ContentPart.t()] | String.t(), map() | keyword()) :: Message.t()
  def user(content, meta_or_opts \\ %{})

  def user(content, meta) when is_binary(content) and is_map(meta), do: text(:user, content, meta)

  def user(content, opts) when is_binary(content) and is_list(opts) do
    meta = Keyword.get(opts, :metadata, %{})
    text(:user, content, meta)
  end

  def user(content, meta) when is_list(content) and is_map(meta) do
    %Message{role: :user, content: content, metadata: meta}
  end

  def user(content, opts) when is_list(content) and is_list(opts) do
    meta = Keyword.get(opts, :metadata, %{})
    %Message{role: :user, content: content, metadata: meta}
  end

  @doc """
  Create an assistant message with optional tool calls and metadata.

  Accepts a string or content parts list. Second argument can be a map (legacy)
  or keyword list with options including tool_calls.

  ## Options

    * `:tool_calls` - List of tool calls (ToolCall structs, tuples, or maps)
    * `:metadata` - Map of metadata to attach to the message (default: %{})

  ## Examples

      assistant("Hello")
      assistant("", tool_calls: [ToolCall.new("id", "get_weather", ~s({"location":"SF"}))])
      assistant("Let me check", tool_calls: [{"get_weather", %{location: "SF"}}])
      assistant([ContentPart.text("Hi")], metadata: %{})

  """
  @spec assistant([ContentPart.t()] | String.t(), map() | keyword()) :: Message.t()
  def assistant(content \\ "", meta_or_opts \\ %{})

  def assistant(content, meta) when is_binary(content) and is_map(meta),
    do: text(:assistant, content, meta)

  def assistant(content, opts) when is_binary(content) and is_list(opts) do
    meta = Keyword.get(opts, :metadata, %{})
    tool_calls = opts |> Keyword.get(:tool_calls) |> normalize_tool_calls()
    parts = to_parts(content)

    %Message{
      role: :assistant,
      content: parts,
      metadata: meta,
      tool_calls: tool_calls
    }
  end

  def assistant(content, meta) when is_list(content) and is_map(meta) do
    %Message{role: :assistant, content: content, metadata: meta}
  end

  def assistant(content, opts) when is_list(content) and is_list(opts) do
    meta = Keyword.get(opts, :metadata, %{})
    tool_calls = opts |> Keyword.get(:tool_calls) |> normalize_tool_calls()

    %Message{
      role: :assistant,
      content: content,
      metadata: meta,
      tool_calls: tool_calls
    }
  end

  @doc """
  Create a system message with optional metadata.

  Accepts a string or content parts list. Second argument can be a map (legacy)
  or keyword list with options.

  ## Options

    * `:metadata` - Map of metadata to attach to the message (default: %{})

  ## Examples

      system("You are helpful")
      system("You are helpful", %{version: 1})
      system("You are helpful", metadata: %{version: 1})

  """
  @spec system([ContentPart.t()] | String.t(), map() | keyword()) :: Message.t()
  def system(content, meta_or_opts \\ %{})

  def system(content, meta) when is_binary(content) and is_map(meta),
    do: text(:system, content, meta)

  def system(content, opts) when is_binary(content) and is_list(opts) do
    meta = Keyword.get(opts, :metadata, %{})
    text(:system, content, meta)
  end

  def system(content, meta) when is_list(content) and is_map(meta) do
    %Message{role: :system, content: content, metadata: meta}
  end

  def system(content, opts) when is_list(content) and is_list(opts) do
    meta = Keyword.get(opts, :metadata, %{})
    %Message{role: :system, content: content, metadata: meta}
  end

  @deprecated "Use assistant(content, tool_calls: [...]) instead"
  @doc "Create an assistant message with tool calls."
  @spec assistant_with_tools([ToolCall.t()], String.t() | nil) :: Message.t()
  def assistant_with_tools(tool_calls, text \\ nil) when is_list(tool_calls) do
    assistant(text || "", tool_calls: tool_calls)
  end

  @doc """
  Create a tool result message with tool_call_id and content.

  Accepts plain text, content parts, or a `ReqLLM.ToolResult` for structured and
  multi-part outputs.
  """
  @spec tool_result(String.t(), String.t() | [ContentPart.t()] | ToolResult.t() | term()) ::
          Message.t()
  def tool_result(tool_call_id, %ToolResult{} = result) do
    tool_result_from_struct(tool_call_id, nil, result)
  end

  def tool_result(tool_call_id, content) when is_list(content) do
    %Message{
      role: :tool,
      content: normalize_content_parts(content),
      tool_call_id: tool_call_id
    }
  end

  def tool_result(tool_call_id, content) when is_binary(content) do
    %Message{
      role: :tool,
      content: [ContentPart.text(content)],
      tool_call_id: tool_call_id
    }
  end

  def tool_result(tool_call_id, output) do
    tool_result_message(nil, tool_call_id, output)
  end

  @doc """
  Create a tool result message with tool_call_id, name, and content.

  Accepts plain text, content parts, or a `ReqLLM.ToolResult` for structured and
  multi-part outputs.
  """
  @spec tool_result(
          String.t(),
          String.t(),
          String.t() | [ContentPart.t()] | ToolResult.t() | term()
        ) ::
          Message.t()
  def tool_result(tool_call_id, name, %ToolResult{} = result) do
    tool_result_from_struct(tool_call_id, name, result)
  end

  def tool_result(tool_call_id, name, content) when is_list(content) do
    %Message{
      role: :tool,
      name: name,
      content: normalize_content_parts(content),
      tool_call_id: tool_call_id
    }
  end

  def tool_result(tool_call_id, name, content) when is_binary(content) do
    %Message{
      role: :tool,
      name: name,
      content: [ContentPart.text(content)],
      tool_call_id: tool_call_id
    }
  end

  def tool_result(tool_call_id, name, output) do
    tool_result_message(name, tool_call_id, output)
  end

  @deprecated "Use assistant(\"\", tool_calls: [{name, input}]) instead"
  @doc "Build an assistant message with a tool call."
  @spec assistant_tool_call(String.t(), term(), keyword()) :: Message.t()
  def assistant_tool_call(name, input, opts \\ []) do
    id = opts[:id]
    meta = Keyword.get(opts, :meta, %{})
    assistant("", tool_calls: [{name, input, id: id}], metadata: meta)
  end

  @deprecated "Use assistant(\"\", tool_calls: [...]) instead"
  @doc "Build an assistant message with multiple tool calls."
  @spec assistant_tool_calls([%{id: String.t(), name: String.t(), input: term()}], map()) ::
          Message.t()
  def assistant_tool_calls(calls, meta \\ %{}) do
    tool_calls = Enum.map(calls, fn call -> {call.name, call.input, id: call.id} end)
    assistant("", tool_calls: tool_calls, metadata: meta)
  end

  @doc """
  Build a tool result message.

  The model-visible contract lives in the message content. When `output` is a
  non-text value, ReqLLM encodes it into a JSON text content part and also
  preserves the original value in metadata for provider adapters and local
  tooling.

  Prefer putting canonical success/failure semantics in the content body, for
  example:

      %{ok: true, result: %{temp_f: 72}}
      %{ok: false, error: %{type: :timeout, message: "Tool timed out"}}

  Metadata is supplementary and should not be the only place a model-facing tool
  result is represented.
  """
  @spec tool_result_message(String.t() | nil, String.t(), term(), map()) :: Message.t()
  def tool_result_message(tool_name, tool_call_id, output, meta \\ %{}) do
    {content, output_meta} = normalize_tool_result_input(output)
    metadata = Map.merge(meta, output_meta)

    message = %Message{
      role: :tool,
      name: tool_name,
      tool_call_id: tool_call_id,
      content: content,
      metadata: metadata
    }

    if is_nil(tool_name), do: %{message | name: nil}, else: message
  end

  @doc """
  Execute a list of tool calls and append their results to the context.

  Takes a list of tool call maps (with :id, :name, :arguments keys) and a list
  of available tools, executes each call, and appends the results as tool messages.
  Tool callbacks may return plain text, structured data, content parts, or a
  `ReqLLM.ToolResult`.

  ## Parameters

    * `context` - The context to append results to
    * `tool_calls` - List of tool call maps with :id, :name, :arguments
    * `available_tools` - List of ReqLLM.Tool structs to execute against

  ## Returns

  Updated context with tool result messages appended.

  ## Examples

      tool_calls = [%{id: "call_1", name: "calculator", arguments: %{"operation" => "add", "a" => 2, "b" => 3}}]
      context = Context.execute_and_append_tools(context, tool_calls, tools)

  """
  @spec execute_and_append_tools(t(), [map()], [ReqLLM.Tool.t()]) :: t()
  def execute_and_append_tools(context, tool_calls, available_tools) do
    Enum.reduce(tool_calls, context, fn tool_call, ctx ->
      {name, id} = extract_tool_call_info(tool_call)

      case find_and_execute_tool(tool_call, available_tools) do
        {:ok, result} ->
          tool_result_msg = tool_result_message(name, id, result)
          append(ctx, tool_result_msg)

        {:error, %ToolResult{} = result} ->
          tool_result_msg = tool_result_message(name, id, result)

          tool_result_msg = %{
            tool_result_msg
            | metadata: Map.put(tool_result_msg.metadata, :is_error, true)
          }

          append(ctx, tool_result_msg)

        {:error, error} ->
          error_result = %{error: to_string(error)}
          tool_result_msg = tool_result_message(name, id, error_result, %{is_error: true})
          append(ctx, tool_result_msg)
      end
    end)
  end

  defp extract_tool_call_info(%ReqLLM.ToolCall{id: id, function: %{name: name}}), do: {name, id}
  defp extract_tool_call_info(%{name: name, id: id}), do: {name, id}

  defp find_and_execute_tool(
         %ReqLLM.ToolCall{function: %{name: name, arguments: args_json}},
         available_tools
       ) do
    args = Jason.decode!(args_json)
    execute_tool_by_name(name, args, available_tools)
  end

  defp find_and_execute_tool(%{name: name, arguments: args}, available_tools) do
    execute_tool_by_name(name, args, available_tools)
  end

  defp execute_tool_by_name(name, args, available_tools) do
    case Enum.find(available_tools, fn tool -> tool.name == name end) do
      nil ->
        {:error, "Tool #{name} not found"}

      tool ->
        ReqLLM.Tool.execute(tool, args)
    end
  end

  @doc "Build a text-only message for the given role."
  @spec text(atom(), String.t(), map()) :: Message.t()
  def text(role, content, meta \\ %{}) when is_binary(content) do
    %Message{
      role: role,
      content: [ContentPart.text(content)],
      metadata: meta
    }
  end

  @doc "Build a message with text and an image URL for the given role."
  @spec with_image(atom(), String.t(), String.t(), map()) :: Message.t()
  def with_image(role, text, url, meta \\ %{}) do
    %Message{
      role: role,
      content: [ContentPart.text(text), ContentPart.image_url(url)],
      metadata: meta
    }
  end

  @doc "Build a message from role and content parts (metadata optional)."
  @spec build(atom(), [ContentPart.t()], map()) :: Message.t()
  def build(role, content, meta \\ %{}) when is_list(content) do
    %Message{role: role, content: content, metadata: meta}
  end

  # Validation and wrap/encode helpers

  @doc "Validate context: ensures valid messages and tool message constraints."
  @spec validate(t()) :: {:ok, t()} | {:error, String.t()}
  def validate(%__MODULE__{messages: msgs} = context) do
    with :ok <- validate_message_structure(msgs),
         :ok <- validate_tool_messages(msgs) do
      {:ok, context}
    end
  end

  @doc "Bang version of validate/1; raises ReqLLM.Error.Validation.Error on invalid context."
  @spec validate!(t()) :: t()
  def validate!(context) do
    case validate(context) do
      {:ok, context} ->
        context

      {:error, reason} ->
        raise ReqLLM.Error.Validation.Error.exception(
                tag: :invalid_context,
                reason: "Invalid context: #{reason}",
                context: [context: context]
              )
    end
  end

  @doc """
  Wrap a context with provider-specific tagged struct.

  Takes a `ReqLLM.Context` and `ReqLLM.Model` and wraps the context
  in the appropriate provider-specific struct for encoding/decoding.

  ## Parameters

    * `context` - A `ReqLLM.Context` to wrap
    * `model` - A `ReqLLM.Model` indicating the provider

  ## Returns

    * Provider-specific tagged struct ready for encoding

  ## Examples

      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])
      model = ReqLLM.model("anthropic:claude-3-haiku-20240307")
      tagged = ReqLLM.Context.wrap(context, model)
      #=> %ReqLLM.Providers.Anthropic.Context{context: context}

  """
  @spec wrap(t(), LLMDB.Model.t()) :: term()
  def wrap(%__MODULE__{} = ctx, %LLMDB.Model{provider: provider_atom}) do
    case ReqLLM.provider(provider_atom) do
      {:ok, provider_mod} ->
        if function_exported?(provider_mod, :wrap_context, 1) do
          provider_mod.wrap_context(ctx)
        else
          ctx
        end

      {:error, _} ->
        ctx
    end
  end

  # Enumerable/Collectable implementations

  defimpl Enumerable do
    def count(%ReqLLM.Context{messages: messages}), do: {:ok, length(messages)}

    def member?(%ReqLLM.Context{messages: messages}, element) do
      {:ok, Enum.member?(messages, element)}
    end

    def reduce(%ReqLLM.Context{messages: messages}, acc, fun) do
      Enumerable.reduce(messages, acc, fun)
    end

    def slice(%ReqLLM.Context{messages: messages}) do
      {:ok, length(messages), &Enum.slice(messages, &1, &2)}
    end
  end

  defimpl Collectable do
    def into(%ReqLLM.Context{messages: messages}) do
      collector = fn
        list, {:cont, message} -> [message | list]
        list, :done -> %ReqLLM.Context{messages: messages ++ Enum.reverse(list)}
        _list, :halt -> :ok
      end

      {[], collector}
    end
  end

  defimpl Inspect do
    def inspect(%{messages: msgs}, opts) when is_list(msgs) do
      msg_count = length(msgs)

      if redact_context?() do
        Inspect.Algebra.concat([
          "#Context<",
          Inspect.Algebra.to_doc(msg_count, opts),
          " messages [REDACTED]>"
        ])
      else
        format_messages(msgs, msg_count, opts)
      end
    end

    def inspect(_context, _opts) do
      Inspect.Algebra.concat(["#Context<", "(truncated)", ">"])
    end

    defp format_messages(msgs, msg_count, opts) when msg_count <= 2 do
      role_previews =
        msgs
        |> Enum.map_join(", ", fn msg ->
          "#{msg.role}:\"#{content_preview(msg, 40)}\""
        end)

      Inspect.Algebra.concat([
        "#Context<",
        Inspect.Algebra.to_doc(msg_count, opts),
        " msgs: ",
        role_previews,
        ">"
      ])
    end

    defp format_messages(msgs, msg_count, opts) do
      msg_docs =
        msgs
        |> Enum.with_index()
        |> Enum.map(fn {msg, idx} ->
          "  [#{idx}] #{msg.role}: \"#{content_preview(msg, 60)}\""
        end)

      Inspect.Algebra.concat([
        "#Context<",
        Inspect.Algebra.to_doc(msg_count, opts),
        " messages:",
        Inspect.Algebra.line(),
        Inspect.Algebra.concat(Enum.intersperse(msg_docs, Inspect.Algebra.line())),
        Inspect.Algebra.line(),
        ">"
      ])
    end

    defp redact_context? do
      Application.get_env(:req_llm, :redact_context, false)
    end

    defp content_preview(msg, max_len) do
      with content when is_list(content) <- msg.content,
           %{text: text} when is_binary(text) <- List.first(content) do
        trimmed = String.slice(text, 0, max_len)
        if String.length(text) > max_len, do: trimmed <> "...", else: trimmed
      else
        _ -> ""
      end
    end
  end

  # Private functions

  # Determine which tools to persist in context based on opts
  defp persist_tools(context_tools, opts_tools) do
    case opts_tools do
      # No tools in opts, keep existing context tools
      nil -> context_tools
      # Empty list means explicitly no tools
      [] -> []
      # New tools provided, use them
      tools when is_list(tools) -> tools
    end
  end

  defp generate_id do
    Uniq.UUID.uuid7()
  end

  defp to_parts(s) when is_binary(s) do
    if String.trim(s) == "" do
      []
    else
      [ContentPart.text(s)]
    end
  end

  defp to_parts(list) when is_list(list) do
    Enum.flat_map(list, &to_part_list/1)
  end

  defp normalize_tool_calls(nil), do: nil
  defp normalize_tool_calls([]), do: nil

  defp normalize_tool_calls(%ToolCall{} = tc), do: [tc]

  defp normalize_tool_calls(list) when is_list(list) do
    Enum.map(list, &normalize_tool_call/1)
  end

  defp normalize_tool_calls(other), do: [normalize_tool_call(other)]

  defp normalize_tool_call(%ToolCall{} = tc), do: tc

  defp normalize_tool_call({name, input}) when is_binary(name) do
    ToolCall.new(generate_id(), name, json(input))
  end

  defp normalize_tool_call({name, input, opts}) when is_binary(name) and is_list(opts) do
    id = opts[:id] || generate_id()
    ToolCall.new(id, name, json(input))
  end

  defp normalize_tool_call(%{name: name, arguments: input} = m) do
    id = Map.get(m, :id, generate_id())
    ToolCall.new(id, name, json(input))
  end

  defp normalize_tool_call(%{name: name, input: input} = m) do
    id = Map.get(m, :id, generate_id())
    ToolCall.new(id, name, json(input))
  end

  defp normalize_tool_call(%{"name" => name, "arguments" => input} = m) do
    id = Map.get(m, "id") || generate_id()
    ToolCall.new(id, name, json(input))
  end

  defp normalize_tool_call(%{"name" => name, "input" => input} = m) do
    id = Map.get(m, "id") || generate_id()
    ToolCall.new(id, name, json(input))
  end

  defp normalize_tool_call(other) do
    raise ArgumentError, "invalid tool_call: #{inspect(other)}"
  end

  defp json(v) when is_binary(v), do: v
  defp json(v), do: Jason.encode!(v)

  defp to_context(%__MODULE__{} = context, _convert_loose?), do: {:ok, context}

  defp to_context(prompt, _convert_loose?) when is_binary(prompt) do
    {:ok, new([user(prompt)])}
  end

  defp to_context(%Message{} = message, _convert_loose?) do
    {:ok, new([message])}
  end

  defp to_context(list, convert_loose?) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {item, _idx}, {:ok, acc} ->
      case convert_item(item, convert_loose?) do
        {:ok, msg} when is_struct(msg, Message) ->
          {:cont, {:ok, acc ++ [msg]}}

        {:ok, msgs} when is_list(msgs) ->
          {:cont, {:ok, acc ++ msgs}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
    |> case do
      {:ok, msgs} -> {:ok, new(msgs)}
      error -> error
    end
  end

  defp to_context(map, true) when is_map(map) do
    case convert_loose_map(map) do
      {:ok, message} -> {:ok, new([message])}
      error -> error
    end
  end

  defp to_context(_prompt, _convert_loose?), do: {:error, :invalid_prompt}

  defp convert_item(%__MODULE__{} = context, _convert_loose?) do
    case to_list(context) do
      [] -> {:error, :empty_context}
      messages -> {:ok, messages}
    end
  end

  defp convert_item(item, convert_loose?) do
    case to_context(item, convert_loose?) do
      {:ok, context} ->
        case to_list(context) do
          [message] -> {:ok, message}
          messages when is_list(messages) -> {:ok, messages}
        end

      error ->
        error
    end
  end

  defp convert_loose_map(%{role: :assistant, tool_calls: tool_calls} = msg)
       when is_list(tool_calls) do
    content = Map.get(msg, :content, "") || ""
    meta = Map.get(msg, :metadata, %{})
    reasoning_details = Map.get(msg, :reasoning_details)

    {:ok,
     %Message{
       role: :assistant,
       content: to_parts(content),
       metadata: meta,
       tool_calls: normalize_tool_calls(tool_calls),
       reasoning_details: reasoning_details
     }}
  end

  defp convert_loose_map(%{role: :tool, tool_call_id: id, content: content} = msg)
       when is_binary(id) and is_list(content) do
    name = Map.get(msg, :name)

    if name do
      {:ok, tool_result(id, name, content)}
    else
      {:ok, tool_result(id, content)}
    end
  end

  defp convert_loose_map(%{role: :tool, tool_call_id: id, output: output} = msg)
       when is_binary(id) do
    name = Map.get(msg, :name)
    meta = Map.get(msg, :metadata, %{})

    {:ok, tool_result_message(name, id, output, meta)}
  end

  defp convert_loose_map(%{role: :tool, tool_call_id: id, content: content} = msg)
       when is_binary(id) and is_binary(content) do
    name = Map.get(msg, :name)

    if name do
      {:ok, tool_result(id, name, content)}
    else
      {:ok, tool_result(id, content)}
    end
  end

  defp convert_loose_map(%{role: role, content: content} = msg)
       when is_atom(role) and is_list(content) do
    {:ok,
     %Message{
       role: role,
       content: to_parts(content),
       metadata: Map.get(msg, :metadata, %{})
     }
     |> maybe_put_reasoning_details(Map.get(msg, :reasoning_details))}
  end

  defp convert_loose_map(%{role: role, content: content} = msg)
       when is_atom(role) and is_binary(content) do
    {:ok,
     text(role, content, Map.get(msg, :metadata, %{}))
     |> maybe_put_reasoning_details(Map.get(msg, :reasoning_details))}
  end

  defp convert_loose_map(%{role: role, content: content} = msg)
       when is_binary(role) and is_list(content) do
    convert_loose_role_list_content(
      role,
      content,
      Map.get(msg, :metadata, %{}),
      Map.get(msg, :reasoning_details)
    )
  end

  defp convert_loose_map(%{role: role, content: content} = msg)
       when is_binary(role) and is_binary(content) do
    metadata = Map.get(msg, :metadata, %{})
    reasoning_details = Map.get(msg, :reasoning_details)

    case role do
      "user" ->
        {:ok, text(:user, content, metadata)}

      "assistant" ->
        {:ok,
         text(:assistant, content, metadata) |> maybe_put_reasoning_details(reasoning_details)}

      "system" ->
        {:ok, text(:system, content, metadata)}

      _ ->
        {:error, ReqLLM.Error.Invalid.Role.exception(role: role)}
    end
  end

  defp convert_loose_map(%{"role" => role, "content" => content} = msg)
       when is_binary(role) and is_list(content) do
    convert_loose_role_list_content(
      role,
      content,
      Map.get(msg, "metadata", %{}),
      Map.get(msg, "reasoning_details")
    )
  end

  defp convert_loose_map(%{"role" => role, "content" => content} = msg)
       when is_binary(role) and is_binary(content) do
    metadata = Map.get(msg, "metadata", %{})
    reasoning_details = Map.get(msg, "reasoning_details")

    case role do
      "user" ->
        {:ok, text(:user, content, metadata)}

      "assistant" ->
        {:ok,
         text(:assistant, content, metadata) |> maybe_put_reasoning_details(reasoning_details)}

      "system" ->
        {:ok, text(:system, content, metadata)}

      _ ->
        {:error, ReqLLM.Error.Invalid.Role.exception(role: role)}
    end
  end

  defp convert_loose_map(_map), do: {:error, :invalid_loose_map}

  defp to_part_list(%ContentPart{} = part), do: [part]

  defp to_part_list(%{"type" => type} = part) do
    case type do
      "text" ->
        text = part["text"]

        if is_binary(text) and text != "" do
          [ContentPart.text(text)]
        else
          []
        end

      "thinking" ->
        text = part["text"] || part["thinking"]

        if is_binary(text) and text != "" do
          [ContentPart.thinking(text)]
        else
          []
        end

      "image_url" ->
        case url_content_part(part, "image_url") do
          {:ok, url_part} -> [url_part]
          :error -> []
        end

      "video_url" ->
        case url_content_part(part, "video_url") do
          {:ok, url_part} -> [url_part]
          :error -> []
        end

      type when type in ["file", "file_id", "document", "image"] ->
        case file_content_part(part) do
          {:ok, file_part} -> [file_part]
          :error -> []
        end

      _ ->
        []
    end
  end

  defp to_part_list(%{type: type} = part) do
    case type do
      :text ->
        text = part[:text]

        if is_binary(text) and text != "" do
          [ContentPart.text(text)]
        else
          []
        end

      :thinking ->
        text = part[:text] || part[:thinking]

        if is_binary(text) and text != "" do
          [ContentPart.thinking(text)]
        else
          []
        end

      :image_url ->
        case url_content_part(part, :image_url) do
          {:ok, url_part} -> [url_part]
          :error -> []
        end

      :video_url ->
        case url_content_part(part, :video_url) do
          {:ok, url_part} -> [url_part]
          :error -> []
        end

      type
      when type in [:file, "file", :file_id, "file_id", :document, "document", :image, "image"] ->
        case file_content_part(part) do
          {:ok, file_part} -> [file_part]
          :error -> []
        end

      _ ->
        []
    end
  end

  defp to_part_list(_part), do: []

  defp url_content_part(part, kind) when is_binary(kind) do
    metadata = part["metadata"] || %{}
    nested = part[kind]

    url =
      part["url"] ||
        if(is_map(nested), do: nested["url"])

    media_type =
      part["media_type"] ||
        if(is_map(nested), do: nested["media_type"])

    if is_binary(url) and url != "" do
      atom_kind = String.to_existing_atom(kind)

      content_part =
        case atom_kind do
          :image_url -> ContentPart.image_url(url, metadata)
          :video_url -> ContentPart.video_url(url, metadata)
        end

      {:ok, maybe_put_url_media_type(content_part, media_type)}
    else
      :error
    end
  end

  defp url_content_part(part, kind) when is_atom(kind) do
    metadata = part[:metadata] || %{}
    nested = part[kind]

    url =
      part[:url] ||
        if(is_map(nested), do: nested[:url])

    media_type =
      part[:media_type] ||
        if(is_map(nested), do: nested[:media_type])

    if is_binary(url) and url != "" do
      content_part =
        case kind do
          :image_url -> ContentPart.image_url(url, metadata)
          :video_url -> ContentPart.video_url(url, metadata)
        end

      {:ok, maybe_put_url_media_type(content_part, media_type)}
    else
      :error
    end
  end

  defp maybe_put_url_media_type(%ContentPart{} = part, media_type)
       when is_binary(media_type) and media_type != "" do
    %{part | media_type: media_type}
  end

  defp maybe_put_url_media_type(%ContentPart{} = part, _media_type), do: part

  defp file_content_part(part) do
    metadata = file_content_metadata(part)

    nested =
      Map.get(part, :file) ||
        Map.get(part, "file") ||
        Map.get(part, :document) ||
        Map.get(part, "document") ||
        Map.get(part, :source) ||
        Map.get(part, "source")

    file_id =
      Map.get(part, :file_id) ||
        Map.get(part, "file_id") ||
        if(is_map(nested), do: Map.get(nested, :file_id) || Map.get(nested, "file_id"))

    media_type =
      Map.get(part, :media_type) ||
        Map.get(part, "media_type") ||
        if(is_map(nested), do: Map.get(nested, :media_type) || Map.get(nested, "media_type"))

    filename =
      Map.get(part, :filename) ||
        Map.get(part, "filename") ||
        if(is_map(nested), do: Map.get(nested, :filename) || Map.get(nested, "filename"))

    if is_binary(file_id) and file_id != "" do
      file_part = ContentPart.file_id(file_id, media_type || "application/pdf", metadata)
      {:ok, maybe_put_file_filename(file_part, filename)}
    else
      case file_content_data(part, nested, media_type) do
        {:ok, data, media_type} ->
          file_part =
            data
            |> ContentPart.file(filename || "file", media_type)
            |> Map.put(:metadata, metadata)

          {:ok, file_part}

        :error ->
          :error
      end
    end
  end

  defp file_content_data(part, nested, media_type) do
    data =
      Map.get(part, :file_data) ||
        Map.get(part, "file_data") ||
        if(is_map(nested), do: Map.get(nested, :file_data) || Map.get(nested, "file_data"))

    case data do
      data when is_binary(data) ->
        decode_file_data(data, media_type)

      _ ->
        :error
    end
  end

  defp decode_file_data("data:" <> _ = data_uri, media_type) do
    case Regex.run(~r/^data:([^;,]*)(?:;[^,]*)*;base64,(.*)$/s, data_uri) do
      [_, uri_media_type, encoded] ->
        decoded = String.replace(encoded, ~r/\s+/, "")

        case Base.decode64(decoded) do
          {:ok, data} -> {:ok, data, file_data_media_type(uri_media_type, media_type)}
          :error -> :error
        end

      _ ->
        :error
    end
  end

  defp decode_file_data(data, media_type) when is_binary(data) do
    {:ok, data, media_type || "application/octet-stream"}
  end

  defp file_data_media_type(uri_media_type, _media_type)
       when is_binary(uri_media_type) and uri_media_type != "" do
    uri_media_type
  end

  defp file_data_media_type(_uri_media_type, media_type)
       when is_binary(media_type) and media_type != "" do
    media_type
  end

  defp file_data_media_type(_uri_media_type, _media_type), do: "application/octet-stream"

  defp maybe_put_file_filename(%ContentPart{} = part, filename)
       when is_binary(filename) and filename != "" do
    %{part | filename: filename}
  end

  defp maybe_put_file_filename(%ContentPart{} = part, _filename), do: part

  defp file_content_metadata(part) do
    metadata = Map.get(part, :metadata) || Map.get(part, "metadata") || %{}

    Enum.reduce([:title, :context, :citations], metadata, fn key, acc ->
      value = Map.get(part, key) || Map.get(part, Atom.to_string(key))

      if is_nil(value) do
        acc
      else
        Map.put_new(acc, key, value)
      end
    end)
  end

  defp convert_loose_role_list_content(role, content, metadata, reasoning_details) do
    case role do
      "user" ->
        {:ok, %Message{role: :user, content: to_parts(content), metadata: metadata}}

      "assistant" ->
        {:ok,
         %Message{role: :assistant, content: to_parts(content), metadata: metadata}
         |> maybe_put_reasoning_details(reasoning_details)}

      "system" ->
        {:ok, %Message{role: :system, content: to_parts(content), metadata: metadata}}

      _ ->
        {:error, ReqLLM.Error.Invalid.Role.exception(role: role)}
    end
  end

  defp maybe_add_system(context, nil), do: context

  defp maybe_add_system(%__MODULE__{messages: messages} = context, system_prompt)
       when is_binary(system_prompt) do
    has_system? = Enum.any?(messages, &(&1.role == :system))

    if has_system? do
      context
    else
      %__MODULE__{messages: [system(system_prompt) | messages]}
    end
  end

  defp maybe_add_system(context, _), do: context

  defp validate_message_structure(messages) do
    Enum.reduce_while(messages, :ok, fn msg, :ok ->
      cond do
        not Message.valid?(msg) ->
          {:halt, {:error, "Context contains invalid messages"}}

        not is_list(msg.content) ->
          {:halt, {:error, "Message content must be a list of ContentParts"}}

        msg.role == :assistant and msg.tool_calls != nil and not is_list(msg.tool_calls) ->
          {:halt, {:error, "tool_calls must be a list or nil"}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp validate_tool_messages(messages) do
    messages
    |> Enum.filter(&(&1.role == :tool))
    |> Enum.reduce_while(:ok, fn msg, :ok ->
      if is_nil(msg.tool_call_id) do
        {:halt, {:error, "Tool message requires tool_call_id"}}
      else
        {:cont, :ok}
      end
    end)
  end

  defp tool_result_from_struct(tool_call_id, tool_name, %ToolResult{} = result) do
    {content, output_meta} = normalize_tool_result_struct(result)

    message = %Message{
      role: :tool,
      name: tool_name,
      tool_call_id: tool_call_id,
      content: content,
      metadata: output_meta
    }

    if is_nil(tool_name), do: %{message | name: nil}, else: message
  end

  defp normalize_tool_result_struct(%ToolResult{} = result) do
    content = normalize_tool_result_content(result.content, result.output)
    metadata = ToolResult.put_output_metadata(result.metadata, result.output)
    {content, metadata}
  end

  defp normalize_tool_result_input(%ToolResult{} = result) do
    normalize_tool_result_struct(result)
  end

  defp normalize_tool_result_input(content) when is_list(content) do
    {normalize_content_parts(content), %{}}
  end

  defp normalize_tool_result_input(content) when is_binary(content) do
    {[ContentPart.text(content)], %{}}
  end

  defp normalize_tool_result_input(output) do
    encoded = encode_tool_output(output)
    {[ContentPart.text(encoded)], %{ToolResult.metadata_key() => output}}
  end

  defp normalize_tool_result_content(nil, nil), do: []

  defp normalize_tool_result_content(nil, output) do
    [ContentPart.text(encode_tool_output(output))]
  end

  defp normalize_tool_result_content(content, _output) when is_list(content) do
    normalize_content_parts(content)
  end

  defp normalize_tool_result_content(content, _output) when is_binary(content) do
    [ContentPart.text(content)]
  end

  defp normalize_tool_result_content(content, _output) do
    [ContentPart.text(to_string(content))]
  end

  defp normalize_content_parts(parts) do
    Enum.flat_map(parts, fn
      %ContentPart{} = part -> [part]
      text when is_binary(text) -> [ContentPart.text(text)]
      part -> [ContentPart.text(to_string(part))]
    end)
  end

  defp encode_tool_output(output) when is_binary(output), do: output

  defp encode_tool_output(output) when is_map(output) or is_list(output),
    do: Jason.encode!(output)

  defp encode_tool_output(output), do: to_string(output)

  defp maybe_put_reasoning_details(%Message{} = message, nil), do: message

  defp maybe_put_reasoning_details(%Message{} = message, reasoning_details) do
    %{message | reasoning_details: reasoning_details}
  end
end
