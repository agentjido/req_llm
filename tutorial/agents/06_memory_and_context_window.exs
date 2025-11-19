# tutorial/agents/06_memory_and_context_window.exs
#
# Chapter 6: Memory & Context Management (Standalone)
# Goal: Manage the context window by summarizing older messages.
#       This prevents the context from growing indefinitely and exceeding token limits.
#
# Run with:
#   mix run tutorial/agents/06_memory_and_context_window.exs

# Ensure dotenvy loads .env file if present
_ = Dotenvy.source(".env")
Logger.configure(level: :warning)

defmodule SimpleMemory do
  @moduledoc """
  A simple memory manager that keeps the last N messages and summarizes the rest.
  """
  import ReqLLM.Context

  alias ReqLLM.Context

  # Thresholds
  # Very low for demo purposes (keep last 6 messages)
  @max_messages 6

  @doc """
  Compact the context if it exceeds @max_messages.
  Returns {:ok, new_context} or {:error, reason}.
  """
  def compact(model, context) do
    # We always preserve the FIRST system message (the persona).
    # We summarize the "middle", and keep the "tail" (recent).

    messages = context.messages

    if length(messages) <= @max_messages do
      {:ok, context}
    else
      IO.puts("\n[Memory] Context length #{length(messages)} > #{@max_messages}. Summarizing...")

      # Split: [System, ...Old..., ...Recent...]
      [system_msg | rest] = messages

      # Keep last 3 messages (e.g. User, Assistant, User)
      # So we summarize everything between System and the last 3.
      keep_count = 3
      {to_summarize, recent} = Enum.split(rest, length(rest) - keep_count)

      # If nothing to summarize, just return (shouldn't happen with logic above)
      if to_summarize == [] do
        {:ok, context}
      else
        summarize_archived(model, system_msg, to_summarize, recent)
      end
    end
  end

  defp summarize_archived(model, system_msg, old_msgs, recent_msgs) do
    # Create a temporary context to ask the model for a summary
    prompt = """
    Summarize the following conversation history into a single concise paragraph.
    Include key facts, user preferences, and important context.
    """

    # We feed the old messages to the model to get a summary
    summary_ctx =
      Context.new(
        [
          system(prompt)
        ] ++ old_msgs
      )

    IO.puts("   -> Asking model to summarize #{length(old_msgs)} messages...")

    case ReqLLM.generate_text(model, summary_ctx) do
      {:ok, response} ->
        summary_text = ReqLLM.Response.text(response) || "No summary generated."
        IO.puts("   -> Summary generated: #{inspect(summary_text)}")

        # Construct new context: 
        # We must merge the summary into the system message because ReqLLM.Context
        # enforces a single system message.

        # Combine original persona + summary
        combined_prompt = """
        #{system_msg.content}

        [MEMORY / CONTEXT SUMMARY]
        #{summary_text}
        """

        # Create a new system message (assuming .content is just the text string for this tutorial)
        # Note: In a robust app, you'd handle multi-part content.
        new_system_msg = system(combined_prompt)

        new_messages = [new_system_msg | recent_msgs]
        {:ok, Context.new(new_messages)}

      {:error, reason} ->
        IO.puts("   -> Summarization failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end

defmodule MemoryAgent do
  use GenServer

  import ReqLLM.Context

  alias ReqLLM.Context

  defstruct [:model, :context]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def ask(pid, text), do: GenServer.call(pid, {:ask, text}, 120_000)

  @impl true
  def init(opts) do
    model = Keyword.get(opts, :model)

    context =
      Context.new([
        system("You are a chatty assistant who likes to remember details.")
      ])

    {:ok, %__MODULE__{model: model, context: context}}
  end

  @impl true
  def handle_call({:ask, text}, _from, state) do
    # 1. Add user message
    context = Context.append(state.context, user(text))

    # 2. Check memory / Compact if needed
    #    (We do this BEFORE calling the model for the answer, so the model gets a clean context)
    #    Note: We pass 'context' which includes the *new* user message. 
    #    Ideally we might want to summarize *before* adding the new message, but 
    #    summarizing old stuff + keeping the new message is fine.
    {:ok, compacted_ctx} = SimpleMemory.compact(state.model, context)

    # 3. Generate answer
    IO.puts(">> User: #{text}")
    # IO.puts("   (Context size: #{length(compacted_ctx.messages)})")

    {:ok, response} = ReqLLM.generate_text(state.model, compacted_ctx)
    answer = ReqLLM.Response.text(response)

    IO.puts(">> Assistant: #{answer}\n")

    # 4. Update state with new assistant message
    final_ctx = Context.append(compacted_ctx, response.message)

    {:reply, {:ok, answer}, %{state | context: final_ctx}}
  end
end

# --- MAIN ---

model = System.get_env("REQ_LLM_MODEL", "anthropic:claude-haiku-4.5")
IO.puts("=== Chapter 6: Memory Management ===\n")
IO.puts("Model: #{model}")
IO.puts("Max messages before summary: 6 (simulated low limit)\n")

{:ok, pid} = MemoryAgent.start_link(model: model)

# 1. Start a conversation to fill up the buffer
questions = [
  "Hi, my name is Alice.",
  "I am a software engineer using Elixir.",
  "I have a dog named Rover.",
  "My favorite color is blue.",
  # 5th interaction (10 messages total) - should trigger summary soon
  "What is my name?",
  "What is my dog's name?",
  # This should force a summary event
  "What is my profession?",
  "What is my favorite color?"
]

Enum.each(questions, fn q ->
  MemoryAgent.ask(pid, q)
  # Sleep briefly to avoid rate limits if any
  Process.sleep(500)
end)
