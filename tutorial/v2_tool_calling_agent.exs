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

defmodule SimpleAgent.V2 do
  use GenServer

  alias ReqLLM.Context
  import ReqLLM.Context
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
  def handle_call(
        {:ask, user_text},
        _from,
        %{model: model, history: history, tools: tools} = state
      ) do
    history = Context.append(history, user(user_text))

    case Core.stream_with_tools(model, history, tools, temperature: 0.0) do
      {:ok, %{assistant_text: text, tool_calls: calls}} ->
        if calls == [] do
          history = Context.append(history, assistant(text))
          {:reply, {:ok, text}, %{state | history: history}}
        else
          history = Context.append(history, assistant(text, tool_calls: calls))
          history = Core.execute_tools_sequential(history, tools, calls)

          case Core.finalize(model, history, max_tokens: 256, temperature: 0.0) do
            {:ok, final_text} ->
              IO.puts(final_text)
              history = Context.append(history, assistant(final_text))
              {:reply, {:ok, final_text}, %{state | history: history}}

            {:error, err} ->
              IO.puts("Final generate_text error: #{inspect(err)}")
              {:reply, {:error, err}, state}
          end
        end

      {:error, error} ->
        IO.puts("stream_text error: #{inspect(error)}")
        {:reply, {:error, error}, state}
    end
  end

end

model = System.get_env("REQ_LLM_MODEL") || "anthropic:claude-sonnet-4-5"

IO.puts("=== SimpleAgent V2 - Tool Calling Demo ===\n")
IO.puts("Model: #{model}")
IO.puts("Temperature: 0.0 (for deterministic tool behavior)\n")

{:ok, pid} = SimpleAgent.V2.start_link(model: model)

IO.puts("\nQuestion 1: What is (15 * 7 + 23) / 2? Show your steps briefly.\n")
{:ok, _response} = SimpleAgent.V2.ask(pid, "What is (15 * 7 + 23) / 2? Show your steps briefly.")

IO.puts("\n\nQuestion 2: Compute sqrt(144) + 3^2\n")
{:ok, _response} = SimpleAgent.V2.ask(pid, "Compute sqrt(144) + 3^2")

IO.puts("\n\nQuestion 3: If tickets cost 12.5 dollars each, how much for 7 tickets?\n")
{:ok, _response} = SimpleAgent.V2.ask(pid, "If tickets cost 12.5 dollars each, how much for 7 tickets?")

IO.puts("\n\nV2 Demo Complete!")
