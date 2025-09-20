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
  """

  use TypedStruct

  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart

  @derive Jason.Encoder

  typedstruct enforce: true do
    field(:messages, [Message.t()], default: [])
  end

  # Canonical public interface

  @doc "Create a new Context from a list of messages (defaults to empty)."
  @spec new([Message.t()]) :: t()
  def new(list \\ []), do: %__MODULE__{messages: list}

  @doc "Return the underlying message list."
  @spec to_list(t()) :: [Message.t()]
  def to_list(%__MODULE__{messages: msgs}), do: msgs

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
  @spec merge_response(t(), ReqLLM.Response.t()) :: ReqLLM.Response.t()
  def merge_response(context, response) do
    case {context, response.message} do
      {%__MODULE__{} = ctx, %Message{} = msg} ->
        updated_messages = ctx.messages ++ [msg]
        updated_context = %__MODULE__{messages: updated_messages}
        %{response | context: updated_context}

      _ ->
        response
    end
  end

  # Role helpers

  @doc "Shortcut for a user message; accepts a string or content parts list."
  @spec user([ContentPart.t()] | String.t(), map()) :: Message.t()
  def user(content, meta \\ %{})
  def user(content, meta) when is_binary(content), do: text(:user, content, meta)

  def user(content, meta) when is_list(content) do
    %Message{role: :user, content: content, metadata: meta}
  end

  @doc "Shortcut for an assistant message; accepts a string or content parts list."
  @spec assistant([ContentPart.t()] | String.t(), map()) :: Message.t()
  def assistant(content, meta \\ %{})
  def assistant(content, meta) when is_binary(content), do: text(:assistant, content, meta)

  def assistant(content, meta) when is_list(content) do
    %Message{role: :assistant, content: content, metadata: meta}
  end

  @doc "Shortcut for a system message; accepts a string or content parts list."
  @spec system([ContentPart.t()] | String.t(), map()) :: Message.t()
  def system(content, meta \\ %{})
  def system(content, meta) when is_binary(content), do: text(:system, content, meta)

  def system(content, meta) when is_list(content) do
    %Message{role: :system, content: content, metadata: meta}
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

  @doc "Validate context: ensures valid messages and at most one system message."
  @spec validate(t()) :: {:ok, t()} | {:error, String.t()}
  def validate(%__MODULE__{messages: msgs} = context) do
    with :ok <- validate_system_messages(msgs),
         :ok <- validate_message_structure(msgs) do
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
      model = ReqLLM.Model.from("anthropic:claude-3-haiku-20240307")
      tagged = ReqLLM.Context.wrap(context, model)
      #=> %ReqLLM.Providers.Anthropic.Context{context: context}

  """
  @spec wrap(t(), ReqLLM.Model.t()) :: term()
  def wrap(%__MODULE__{} = ctx, %ReqLLM.Model{provider: provider_atom}) do
    {:ok, provider_mod} = ReqLLM.Provider.Registry.get_provider(provider_atom)

    if function_exported?(provider_mod, :wrap_context, 1) do
      provider_mod.wrap_context(ctx)
    else
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
        list, :done -> %ReqLLM.Context{messages: Enum.reverse(list, messages)}
        _list, :halt -> :ok
      end

      {[], collector}
    end
  end

  defimpl Inspect do
    def inspect(%{messages: msgs}, opts) do
      msg_count = length(msgs)

      if msg_count <= 2 do
        role_previews =
          msgs
          |> Enum.map_join(", ", fn msg ->
            content_preview =
              case List.first(msg.content) do
                %{text: text} when is_binary(text) ->
                  trimmed = String.slice(text, 0, 40)
                  if String.length(text) > 40, do: trimmed <> "...", else: trimmed

                _ ->
                  ""
              end

            "#{msg.role}:\"#{content_preview}\""
          end)

        Inspect.Algebra.concat([
          "#Context<",
          Inspect.Algebra.to_doc(msg_count, opts),
          " msgs: ",
          role_previews,
          ">"
        ])
      else
        msg_docs =
          msgs
          |> Enum.with_index()
          |> Enum.map(fn {msg, idx} ->
            content_preview =
              case List.first(msg.content) do
                %{text: text} when is_binary(text) ->
                  trimmed = String.slice(text, 0, 60)
                  if String.length(text) > 60, do: trimmed <> "...", else: trimmed

                _ ->
                  ""
              end

            "  [#{idx}] #{msg.role}: \"#{content_preview}\""
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
    end
  end

  # Private functions

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

  defp convert_loose_map(%{role: role, content: content})
       when is_atom(role) and is_binary(content) do
    {:ok, text(role, content)}
  end

  defp convert_loose_map(%{role: role, content: content})
       when is_binary(role) and is_binary(content) do
    case role do
      "user" -> {:ok, text(:user, content)}
      "assistant" -> {:ok, text(:assistant, content)}
      "system" -> {:ok, text(:system, content)}
      _ -> {:error, ReqLLM.Error.Invalid.Role.exception(role: role)}
    end
  end

  defp convert_loose_map(%{"role" => role, "content" => content})
       when is_binary(role) and is_binary(content) do
    case role do
      "user" -> {:ok, text(:user, content)}
      "assistant" -> {:ok, text(:assistant, content)}
      "system" -> {:ok, text(:system, content)}
      _ -> {:error, ReqLLM.Error.Invalid.Role.exception(role: role)}
    end
  end

  defp convert_loose_map(_map), do: {:error, :invalid_loose_map}

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

  defp validate_system_messages(messages) do
    system_count = Enum.count(messages, &(&1.role == :system))

    case system_count do
      0 -> :ok
      1 -> :ok
      n -> {:error, "Context should have at most one system message, found #{n}"}
    end
  end

  defp validate_message_structure(messages) do
    case Enum.all?(messages, &Message.valid?/1) do
      true -> :ok
      false -> {:error, "Context contains invalid messages"}
    end
  end
end
