# tutorial/agents/03_streaming_basics.exs
#
# Chapter 3.1: Streaming Basics (Standalone)
# Goal: Show streaming tokens using a simple GenServer. No tools here.
#
# Run with:
#   iex -S mix run tutorial/agents/03_streaming_basics.exs

# Ensure dotenvy loads .env file if present
_ = Dotenvy.source(".env")
Logger.configure(level: :warning)

defmodule SimpleAgent.V1 do
  use GenServer

  import ReqLLM.Context

  alias ReqLLM.Context

  require IEx

  # --- STATE ---
  defstruct [:model, :context]

  # --- CLIENT API ---
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def ask(pid, user_text) do
    GenServer.call(pid, {:ask, user_text}, 60_000)
  end

  # --- SERVER CALLBACKS ---
  @impl true
  def init(opts) do
    system_prompt = "You are a helpful teacher. Keep explanations short."
    model = Keyword.get(opts, :model)
    context = Context.new([system(system_prompt)])
    {:ok, %__MODULE__{model: model, context: context}}
  end

  @impl true
  def handle_call({:ask, user_text}, _from, state) do
    # 1. Append user message
    context = Context.append(state.context, user(user_text))

    IO.puts("\n(Pausing before streaming. Type `continue` or `respawn` to proceed.)")
    IEx.pry()

    # 2. Call stream_text
    #    We merge our context messages with any request options.
    case ReqLLM.stream_text(state.model, context.messages) do
      {:ok, stream_response} ->
        IO.puts("\n[Streaming output]:")

        # 3. Consume the stream
        #    We print chunks as they arrive and accumulate the full text.
        final_text =
          stream_response.stream
          |> Enum.reduce("", fn chunk, acc ->
            if chunk.type == :content do
              IO.write(chunk.text)
              acc <> chunk.text
            else
              acc
            end
          end)

        IO.write("\n\n")

        IO.puts("(Pausing after streaming. Type `continue` or `respawn` to proceed.)")
        IEx.pry()

        # 4. Update context with the assistant's final response
        new_context = Context.append(context, assistant(final_text))
        {:reply, {:ok, final_text}, %{state | context: new_context}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end
end

# --- MAIN SCRIPT ---

model = System.get_env("REQ_LLM_MODEL", "anthropic:claude-haiku-4.5")

IO.puts("=== Chapter 3.1: Streaming Agent ===")
IO.puts("Model: #{model}")

{:ok, pid} = SimpleAgent.V1.start_link(model: model)

question = "Explain the concept of 'Elixir processes' in 2 sentences."
IO.puts("\n>> User: #{question}")

{:ok, _response} = SimpleAgent.V1.ask(pid, question)

IO.puts("Done.")
IEx.pry()
