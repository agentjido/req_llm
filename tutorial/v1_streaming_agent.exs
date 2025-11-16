#!/usr/bin/env elixir

Mix.install([
  {:req_llm, path: ".."}
])

Logger.configure(level: :warning)

defmodule SimpleAgent.V1 do
  use GenServer
  alias ReqLLM.Context
  import ReqLLM.Context

  defstruct [:model, :history]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  @impl true
  def init(opts) do
    system_prompt = """
    You are a helpful teacher. Keep explanations short and clear.
    """

    model = Keyword.get(opts, :model)
    history = Context.new([system(system_prompt)])
    {:ok, %__MODULE__{model: model, history: history}}
  end

  def ask(pid, user_text) when is_binary(user_text) do
    GenServer.call(pid, {:ask, user_text}, 30_000)
  end

  @impl true
  def handle_call({:ask, user_text}, _from, %{model: model, history: history} = state) do
    history = Context.append(history, user(user_text))

    case ReqLLM.stream_text(model, history.messages) do
      {:ok, stream_response} ->
        final_text =
          stream_response
          |> ReqLLM.StreamResponse.tokens()
          |> Enum.reduce("", fn token, acc ->
            IO.write(token)
            acc <> token
          end)

        IO.write("\n\n")

        history = if final_text != "", do: Context.append(history, assistant(final_text)), else: history
        {:reply, {:ok, final_text}, %{state | history: history}}

      {:error, error} ->
        IO.puts("\nError: #{inspect(error)}\n")
        {:reply, {:error, error}, state}
    end
  end
end

model = System.get_env("REQ_LLM_MODEL") || "anthropic:claude-3-7-sonnet-20250219"

IO.puts("=== SimpleAgent V1 - Streaming Demo ===\n")
IO.puts("Model: #{model}")
IO.puts("Temperature: default (not specified for streaming)\n")

{:ok, pid} = SimpleAgent.V1.start_link(model: model)

IO.puts("\nQuestion 1: In 2 short sentences, explain what streaming means for LLM responses.\n")
{:ok, _response} = SimpleAgent.V1.ask(pid, "In 2 short sentences, explain what streaming means for LLM responses.")

IO.puts("\n\nQuestion 2: What is Elixir GenServer in one sentence?\n")
{:ok, _response} = SimpleAgent.V1.ask(pid, "What is Elixir GenServer in one sentence?")

IO.puts("\n\nV1 Demo Complete!")
