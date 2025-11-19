#!/usr/bin/env elixir

Mix.install([
  {:req_llm, path: ".."}
])

Logger.configure(level: :warning)

defmodule SimpleAgent.V1 do
  use GenServer

  import ReqLLM.Context

  alias ReqLLM.Context

  defstruct [:model, :context]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  @impl true
  def init(opts) do
    system_prompt = """
    You are a helpful teacher. Keep explanations short and clear.
    """

    model = Keyword.get(opts, :model)
    context = Context.new([system(system_prompt)])
    {:ok, %__MODULE__{model: model, context: context}}
  end

  def ask(pid, user_text) when is_binary(user_text) do
    GenServer.call(pid, {:ask, user_text}, 30_000)
  end

  @impl true
  def handle_call({:ask, user_text}, _from, %{model: model, context: context} = state) do
    context = Context.append(context, user(user_text))

    case ReqLLM.stream_text(model, context.messages) do
      {:ok, stream_response} ->
        debug? = System.get_env("DEBUG") == "true"

        final_text =
          stream_response.stream
          |> Enum.reduce("", fn chunk, acc ->
            if debug? do
              IO.inspect(chunk, label: "Chunk")
            end

            if chunk.type == :content do
              if !debug?, do: IO.write(chunk.text)
              acc <> chunk.text
            else
              acc
            end
          end)

        IO.write("\n\n")

        # Uncomment to see streaming metadata (usage, finish_reason):
        usage = ReqLLM.StreamResponse.usage(stream_response)
        finish_reason = ReqLLM.StreamResponse.finish_reason(stream_response)
        IO.inspect(usage, label: "Usage")
        IO.inspect(finish_reason, label: "Finish Reason")

        context =
          if final_text == "", do: context, else: Context.append(context, assistant(final_text))

        {:reply, {:ok, final_text}, %{state | context: context}}

      {:error, error} ->
        IO.puts("\nError: #{inspect(error)}\n")
        {:reply, {:error, error}, state}
    end
  end
end

model = System.get_env("REQ_LLM_MODEL") || "anthropic:claude-sonnet-4-5"

IO.puts("=== SimpleAgent V1 - Streaming Demo ===\n")
IO.puts("Model: #{model}")

{:ok, pid} = SimpleAgent.V1.start_link(model: model)

IO.puts("\nQuestion: In 2 short sentences, explain what streaming means for LLM responses.\n")

{:ok, _response} =
  SimpleAgent.V1.ask(pid, "In 2 short sentences, explain what streaming means for LLM responses.")

IO.puts("\n\nV1 Demo Complete!")
