#!/usr/bin/env elixir

Mix.install([
  {:req_llm, path: ".."}
])

Logger.configure(level: :warning)

defmodule TutorialAgent do
  use GenServer
  alias ReqLLM.Context

  defstruct [:model, :context]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  @impl true
  def init(opts) do
    system_prompt = """
    You are a helpful assistant. Keep responses clear and concise.
    """

    model = Keyword.get(opts, :model)
    context = Context.new([Context.system(system_prompt)])
    {:ok, %__MODULE__{model: model, context: context}}
  end

  def ask(pid, user_text, opts \\ []) when is_binary(user_text) do
    GenServer.call(pid, {:ask, user_text, opts}, 60_000)
  end

  @impl true
  def handle_call({:ask, user_text, opts}, _from, %{model: model, context: context} = state) do
    debug? = Keyword.get(opts, :debug, false)

    context = Context.append(context, Context.user(user_text))

    stream_opts = [
      temperature: Keyword.get(opts, :temperature, 0.7),
      max_tokens: Keyword.get(opts, :max_tokens, 1000)
    ]

    case ReqLLM.stream_text(model, context.messages, stream_opts) do
      {:ok, stream_response} ->
        final_text =
          stream_response.stream
          |> Enum.reduce("", fn chunk, acc ->
            if debug?, do: IO.inspect(chunk, label: "CHUNK")

            if chunk.type == :content do
              IO.write(chunk.text)
              acc <> chunk.text
            else
              acc
            end
          end)

        IO.write("\n")

        usage = ReqLLM.StreamResponse.usage(stream_response)
        finish_reason = ReqLLM.StreamResponse.finish_reason(stream_response)

        IO.puts("\n--- Usage ---")
        IO.inspect(usage)
        IO.puts("--- Finish Reason ---")
        IO.inspect(finish_reason)

        context =
          if final_text != "",
            do: Context.append(context, Context.assistant(final_text)),
            else: context

        result = %{text: final_text, usage: usage, finish_reason: finish_reason}
        {:reply, {:ok, result}, %{state | context: context}}

      {:error, error} ->
        IO.puts("\n--- Error ---")
        IO.inspect(error)
        {:reply, {:error, error}, state}
    end
  end
end

model = System.get_env("REQ_LLM_MODEL") || "anthropic:claude-sonnet-4-5"

IO.puts("=== ReqLLM Tutorial Agent ===\n")
IO.puts("Model: #{model}")
IO.puts("Debug mode: #{if System.get_env("DEBUG") == "true", do: "ON", else: "OFF"}")
IO.puts("\n" <> String.duplicate("=", 50) <> "\n")

{:ok, agent} = TutorialAgent.start_link(model: model)

question = "In 2 sentences, explain what streaming means for LLM responses."
IO.puts("Question: #{question}\n")

debug_opt = if System.get_env("DEBUG") == "true", do: [debug: true], else: []
{:ok, response} = TutorialAgent.ask(agent, question, debug_opt)

IO.puts("\n" <> String.duplicate("=", 50))
IO.puts("\nFinal response text length: #{String.length(response.text)} characters")
IO.puts("\nDemo complete!")
