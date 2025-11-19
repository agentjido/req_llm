#!/usr/bin/env elixir

Mix.install([
  {:req_llm, path: ".."},
  {:abacus, "~> 2.0"},
  {:jason, "~> 1.4"}
])

Logger.configure(level: :warning)

Code.require_file("simple_agent_parser.ex", __DIR__)
Code.require_file("simple_agent_tools.ex", __DIR__)
Code.require_file("simple_agent_prompts.ex", __DIR__)
Code.require_file("simple_agent_core.ex", __DIR__)

defmodule SimpleAgent.V3 do
  @moduledoc """
  Advanced agent using {:continue, action} pattern for phased processing.

  This version demonstrates:
  - Non-blocking callers (GenServer replies later via GenServer.reply/2)
  - Clean separation into 3 phases: stream → execute tools → finalize
  - Natural tool calling loop with {:continue, action}

  Note: The GenServer still executes all phases sequentially in a single process;
  callers are non-blocked because we defer the reply with GenServer.reply/2.
  """

  use GenServer

  import ReqLLM.Context

  alias ReqLLM.Context
  alias SimpleAgent.{Core, Prompts}

  defstruct [:model, :history, :tools]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  @impl true
  def init(opts) do
    model = Keyword.get(opts, :model)

    tools = [
      SimpleAgent.Tools.calculator_tool()
    ]

    history = Context.new([system(Prompts.tool_prompt())])
    {:ok, %__MODULE__{model: model, history: history, tools: tools}}
  end

  def ask(pid, user_text) when is_binary(user_text) do
    GenServer.call(pid, {:ask, user_text}, 30_000)
  end

  @impl true
  def handle_call({:ask, user_text}, from, state) do
    IO.puts("Received: #{user_text}\n")
    state = update_in(state.history, &Context.append(&1, user(user_text)))
    {:noreply, state, {:continue, {:stream_response, from}}}
  end

  @impl true
  def handle_continue(
        {:stream_response, from},
        %{model: model, history: history, tools: tools} = state
      ) do
    IO.puts("Streaming response...\n")

    case Core.stream_with_tools(model, history, tools, temperature: 0.0) do
      {:ok, %{assistant_text: text, tool_calls: calls}} ->
        IO.write("\n")
        state = update_in(state.history, &Context.append(&1, assistant(text, tool_calls: calls)))

        if calls == [] do
          GenServer.reply(from, {:ok, text})
          {:noreply, state}
        else
          {:noreply, state, {:continue, {:execute_tools, from, calls}}}
        end

      {:error, error} ->
        IO.puts("\nStream error: #{inspect(error)}\n")
        GenServer.reply(from, {:error, error})
        {:noreply, state}
    end
  end

  @impl true
  def handle_continue({:execute_tools, from, tool_calls}, %{tools: tools} = state) do
    IO.puts("Executing #{length(tool_calls)} tool call(s)...\n")

    history = Core.execute_tools_sequential(state.history, tools, tool_calls)
    state = %{state | history: history}

    IO.puts("")
    {:noreply, state, {:continue, {:finalize_response, from}}}
  end

  @impl true
  def handle_continue({:finalize_response, from}, %{model: model, history: history} = state) do
    IO.puts("Generating final answer...\n")

    case Core.finalize(model, history, max_tokens: 256, temperature: 0.0) do
      {:ok, final_text} ->
        IO.puts(final_text)
        IO.puts("")
        state = update_in(state.history, &Context.append(&1, assistant(final_text)))
        GenServer.reply(from, {:ok, final_text})
        {:noreply, state}

      {:error, err} ->
        IO.puts("Final generate_text error: #{inspect(err)}\n")
        GenServer.reply(from, {:error, err})
        {:noreply, state}
    end
  end
end

model = System.get_env("REQ_LLM_MODEL") || "anthropic:claude-sonnet-4-5"

IO.puts("=== SimpleAgent V3 - Phased Processing Demo ===")
IO.puts("Pattern: {:continue, action} for non-blocking reply to caller\n")
IO.puts("Model: #{model}")
IO.puts("Temperature: 0.0 (for deterministic tool behavior)\n")
IO.puts(String.duplicate("=", 80))

{:ok, pid} = SimpleAgent.V3.start_link(model: model)

IO.puts("\nQuestion 1: What is (15 * 7 + 23) / 2? Show your steps briefly.\n")
IO.puts(String.duplicate("-", 80))
{:ok, _response} = SimpleAgent.V3.ask(pid, "What is (15 * 7 + 23) / 2? Show your steps briefly.")
IO.puts(String.duplicate("=", 80))

IO.puts("\nQuestion 2: Compute sqrt(144) + 3^2\n")
IO.puts(String.duplicate("-", 80))
{:ok, _response} = SimpleAgent.V3.ask(pid, "Compute sqrt(144) + 3^2")
IO.puts(String.duplicate("=", 80))

IO.puts("\nQuestion 3: If tickets cost 12.5 dollars each, how much for 7 tickets?\n")
IO.puts(String.duplicate("-", 80))

{:ok, _response} =
  SimpleAgent.V3.ask(pid, "If tickets cost 12.5 dollars each, how much for 7 tickets?")

IO.puts(String.duplicate("=", 80))

IO.puts("\nV3 Demo Complete!")
IO.puts("\nKey Differences from V2:")
IO.puts("  - Non-blocking reply: Caller gets control back immediately, server processes phases")
IO.puts("  - Separation: Stream → Execute Tools → Finalize (3 separate handle_continue clauses)")
IO.puts("  - Cleaner: Each step is isolated and testable")
IO.puts("  - Note: GenServer itself remains busy during handle_continue execution")
IO.puts("  - For true concurrency: Use Task and GenServer.reply/2 from task (see V5)")
