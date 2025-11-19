#!/usr/bin/env elixir

Mix.install([
  {:req_llm, path: ".."},
  {:abacus, "~> 2.0"},
  {:jason, "~> 1.4"}
])

Logger.configure(level: :warning)

Code.require_file("simpleagent_helpers.ex", __DIR__)

defmodule SimpleAgent.V2 do
  use GenServer

  import ReqLLM.Context

  alias ReqLLM.Context
  alias SimpleAgent.Helpers

  defstruct [:model, :context, :tools]

  @system_prompt """
  You are a helpful assistant with access to tools.

  - When a user asks a math question or expression, use the calculator tool with the "expression" parameter.
  - Provide only valid JSON for tool arguments; do not add extra text in the arguments.
  - After tool results are provided, give a concise final answer.
  """

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  @impl true
  def init(opts) do
    model = Keyword.get(opts, :model)
    tools = [Helpers.calculator_tool()]
    context = Context.new([system(@system_prompt)])
    {:ok, %__MODULE__{model: model, context: context, tools: tools}}
  end

  def ask(pid, user_text) when is_binary(user_text) do
    GenServer.call(pid, {:ask, user_text}, 30_000)
  end

  @impl true
  def handle_call(
        {:ask, user_text},
        _from,
        %{model: model, context: context, tools: tools} = state
      ) do
    context = Context.append(context, user(user_text))

    case ReqLLM.stream_text(model, context.messages, tools: tools, temperature: 0.0) do
      {:ok, stream_response} ->
        debug? = System.get_env("DEBUG") == "true"

        acc =
          Enum.reduce(stream_response.stream, %{text: "", calls: [], arg_frags: %{}}, fn chunk,
                                                                                         acc ->
            if debug?, do: IO.inspect(chunk, label: "Chunk")

            cond do
              chunk.type == :content and is_binary(chunk.text) ->
                if !debug?, do: IO.write(chunk.text)
                %{acc | text: acc.text <> chunk.text}

              chunk.type == :tool_call ->
                if !debug? do
                  args_display =
                    if chunk.arguments in [nil, %{}], do: "...", else: inspect(chunk.arguments)

                  IO.puts("\n[tool_call: #{chunk.name}(#{args_display})]")
                end

                call = %{
                  id: Map.get(chunk.metadata || %{}, :id) || "call_#{:erlang.unique_integer()}",
                  name: chunk.name,
                  arguments: chunk.arguments || %{},
                  index: Map.get(chunk.metadata || %{}, :index, 0)
                }

                %{acc | calls: acc.calls ++ [call]}

              match?(%{type: :meta, metadata: %{tool_call_args: _}}, chunk) ->
                %{index: idx, fragment: frag} = chunk.metadata.tool_call_args
                existing = Map.get(acc.arg_frags, idx, "")
                %{acc | arg_frags: Map.put(acc.arg_frags, idx, existing <> (frag || ""))}

              true ->
                acc
            end
          end)

        if !debug?, do: IO.write("\n")

        calls =
          Enum.map(acc.calls, fn call ->
            call =
              if call.arguments == %{} do
                case Map.get(acc.arg_frags, call.index) do
                  nil ->
                    call

                  json ->
                    case Jason.decode(json) do
                      {:ok, m} when is_map(m) -> %{call | arguments: m}
                      _ -> call
                    end
                end
              else
                call
              end

            Map.delete(call, :index)
          end)

        if calls == [] do
          context = Context.append(context, assistant(acc.text))
          {:reply, {:ok, acc.text}, %{state | context: context}}
        else
          context = Context.append(context, assistant(acc.text, tool_calls: calls))

          context =
            Enum.reduce(calls, context, fn call, ctx ->
              tool = Enum.find(tools, &(&1.name == call.name))

              if tool do
                case ReqLLM.Tool.execute(tool, call.arguments) do
                  {:ok, result} ->
                    if !debug? do
                      IO.puts(
                        "[tool] #{call.name}(#{inspect(call.arguments)}) -> #{inspect(result)}"
                      )
                    end

                    Context.append(ctx, tool_result_message(call.name, call.id, result))

                  {:error, reason} ->
                    err = if is_binary(reason), do: reason, else: inspect(reason)

                    if !debug? do
                      IO.puts("[error] #{call.name} error: #{err}")
                    end

                    Context.append(ctx, tool_result_message(call.name, call.id, %{error: err}))
                end
              else
                if !debug?, do: IO.puts("[error] Tool not found: #{call.name}")
                ctx
              end
            end)

          case ReqLLM.generate_text(model, context.messages, max_tokens: 256, temperature: 0.0) do
            {:ok, %{message: %{content: [%{text: t} | _]}}} when is_binary(t) ->
              if !debug?, do: IO.puts(t)
              context = Context.append(context, assistant(t))
              {:reply, {:ok, t}, %{state | context: context}}

            {:ok, t} when is_binary(t) ->
              if !debug?, do: IO.puts(t)
              context = Context.append(context, assistant(t))
              {:reply, {:ok, t}, %{state | context: context}}

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

IO.puts("\nQuestion: What is (15 * 7 + 23) / 2?\n")
{:ok, _response} = SimpleAgent.V2.ask(pid, "What is (15 * 7 + 23) / 2?")

IO.puts("\n\nV2 Demo Complete!")
