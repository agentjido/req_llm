#!/usr/bin/env elixir

Mix.install([
  {:req_llm, path: ".."},
  {:abacus, "~> 2.1"}
])

Logger.configure(level: :warning)

defmodule CalculatorTool do
  def build do
    {:ok, tool} =
      ReqLLM.Tool.new(
        name: "calculator",
        description:
          "Evaluates a mathematical expression. Supports +, -, *, /, parentheses, and numbers.",
        parameter_schema: %{
          "type" => "object",
          "properties" => %{
            "expression" => %{
              "type" => "string",
              "description" =>
                "Mathematical expression to evaluate (e.g., '842 * 73' or '(10 + 5) / 3')"
            }
          },
          "required" => ["expression"]
        },
        callback: {__MODULE__, :execute}
      )

    tool
  end

  def execute(%{"expression" => expr}) do
    case Abacus.eval(expr) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, "Invalid expression: #{inspect(reason)}"}
    end
  end

  def execute(_), do: {:error, "Missing expression parameter"}
end

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
    You are a helpful assistant with access to a calculator tool.
    Use the calculator for any arithmetic operations.
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
    prn = printer(debug?)

    context = Context.append(context, Context.user(user_text))
    request_opts = build_request_opts(opts)
    max_steps = Keyword.get(opts, :max_steps, 5)

    case run_turn(model, context, request_opts, prn, debug?, max_steps) do
      {:ok, text, new_context, usage_acc, tool_calls_acc} ->
        # Print final output for non-debug mode too, to match original behavior
        if !debug? do
          IO.puts("\n#{text}\n")
          IO.puts("--- Usage ---")
          IO.inspect(usage_acc)
        end

        reply = {:ok, %{text: text, usage: usage_acc, tool_calls: tool_calls_acc}}
        {:reply, reply, %{state | context: new_context}}

      {:error, error} ->
        {:reply, {:error, error}, state}
    end
  end

  # ---- Primary Reason-Act-Loop ----

  defp run_turn(model, context, request_opts, prn, debug?, max_steps) do
    acc = %{usage: %{}, tool_calls: []}
    run_step(model, context, request_opts, prn, debug?, max_steps, acc)
  end

  defp run_step(_model, _context, _opts, _prn, _debug?, 0, _acc) do
    {:error, :max_steps_exceeded}
  end

  defp run_step(model, context, request_opts, prn, debug?, steps_left, acc) do
    prn.say.("\n--- Step 1: Model generates response ---")

    with {:ok, step} <- llm_step(model, context, request_opts, prn, debug?) do
      case step.type do
        :tool_calls ->
          prn.say.("\n--- Step 2: Execute Tools ---")
          tool_results = execute_tools(step.tool_calls, prn)

          ctx2 =
            context
            |> Context.append(step.message)
            |> append_messages(tool_results)

          acc2 = %{
            acc
            | usage: merge_usage(acc.usage, step.usage),
              tool_calls: acc.tool_calls ++ step.tool_calls
          }

          prn.say.("\n--- Loop: back to Step 1 with tool results ---")
          run_step(model, ctx2, request_opts, prn, debug?, steps_left - 1, acc2)

        :text ->
          prn.say.("\n--- Step 3: Done (text) ---")
          ctx2 = Context.append(context, step.message)
          acc2 = %{acc | usage: merge_usage(acc.usage, step.usage)}
          {:ok, step.text, ctx2, acc2.usage, acc2.tool_calls}
      end
    else
      {:error, error} ->
        {:error, error}
    end
  end

  # ---- LLM step (streaming vs. non-streaming) ----

  defp llm_step(model, context, request_opts, prn, debug?) do
    if debug? do
      case ReqLLM.stream_text(model, context.messages, request_opts) do
        {:ok, stream_response} ->
          chunks = Enum.to_list(stream_response.stream)

          Enum.each(chunks, fn chunk ->
            prn.inspect.(chunk, label: "CHUNK")
            if chunk.type == :content, do: prn.write.(chunk.text)
          end)

          prn.write.("\n")

          tool_calls = extract_tool_calls_from_chunks(chunks)
          usage = extract_usage_from_chunks(chunks)

          final_text =
            chunks
            |> Enum.filter(&(&1.type == :content))
            |> Enum.map(& &1.text)
            |> Enum.join()

          prn.say.("Response type: " <> if(tool_calls != [], do: "TOOL_CALLS", else: "TEXT"))
          prn.inspect.(usage, label: "Usage")

          if tool_calls != [] do
            tool_call_structs =
              Enum.map(tool_calls, fn tc ->
                ReqLLM.ToolCall.new(tc.id, tc.name, Jason.encode!(tc.arguments))
              end)

            {:ok,
             %{
               type: :tool_calls,
               tool_calls: tool_calls,
               usage: usage,
               message: Context.assistant(final_text, tool_calls: tool_call_structs)
             }}
          else
            {:ok,
             %{
               type: :text,
               text: final_text,
               usage: usage,
               message: Context.assistant(final_text)
             }}
          end

        {:error, _} = err ->
          err
      end
    else
      case ReqLLM.generate_text(model, context.messages, request_opts) do
        {:ok, response} ->
          tool_calls = ReqLLM.Response.tool_calls(response)
          usage = response.usage

          if tool_calls != [] do
            {:ok,
             %{
               type: :tool_calls,
               tool_calls: tool_calls,
               usage: usage,
               message: response.message
             }}
          else
            text = ReqLLM.Response.text(response)
            {:ok, %{type: :text, text: text, usage: usage, message: response.message}}
          end

        {:error, _} = err ->
          err
      end
    end
  end

  # ---- Tools and helpers ----

  defp execute_tools(tool_calls, prn) do
    Enum.map(tool_calls, fn tool_call ->
      {id, name, args} = parse_tool_call(tool_call)
      prn.say.("\nTool: #{name}")
      prn.say.("Arguments: #{inspect(args)}")

      result =
        case name do
          "calculator" ->
            case CalculatorTool.execute(args) do
              {:ok, value} -> to_string(value)
              {:error, msg} -> "Error: #{msg}"
            end

          _ ->
            "Error: unknown tool #{name}"
        end

      prn.say.("Result: #{result}")
      Context.tool_result(id, result)
    end)
  end

  defp parse_tool_call(%{id: id, name: name, arguments: args}), do: {id, name, args}

  defp parse_tool_call(tool_call) do
    {tool_call.id, ReqLLM.ToolCall.name(tool_call), ReqLLM.ToolCall.args_map(tool_call)}
  end

  defp append_messages(context, messages) do
    Enum.reduce(messages, context, fn msg, ctx -> Context.append(ctx, msg) end)
  end

  defp build_request_opts(opts) do
    [
      temperature: Keyword.get(opts, :temperature, 0.0),
      max_tokens: Keyword.get(opts, :max_tokens, 1000),
      tools: [CalculatorTool.build()]
    ]
  end

  defp merge_usage(a, b) do
    Map.merge(a || %{}, b || %{}, fn _k, v1, v2 ->
      cond do
        is_number(v1) and is_number(v2) -> v1 + v2
        is_map(v1) and is_map(v2) -> merge_usage(v1, v2)
        true -> v2
      end
    end)
  end

  # Simple printer abstraction to isolate side effects
  defp printer(true = _debug) do
    %{
      say: &IO.puts/1,
      write: &IO.write/1,
      inspect: fn data, opts -> IO.inspect(data, opts) end
    }
  end

  defp printer(false = _debug) do
    %{
      say: fn _ -> :ok end,
      write: fn _ -> :ok end,
      inspect: fn _, _ -> :ok end
    }
  end

  defp extract_tool_calls_from_chunks(chunks) do
    tool_calls =
      chunks
      |> Enum.filter(&(&1.type == :tool_call))
      |> Enum.map(fn chunk ->
        %{
          id: Map.get(chunk.metadata, :id) || "call_#{:erlang.unique_integer()}",
          name: chunk.name,
          arguments: chunk.arguments || %{},
          index: Map.get(chunk.metadata, :index, 0)
        }
      end)

    arg_fragments =
      chunks
      |> Enum.filter(fn
        %{type: :meta, metadata: %{tool_call_args: _}} -> true
        _ -> false
      end)
      |> Enum.group_by(fn chunk ->
        chunk.metadata.tool_call_args.index
      end)
      |> Map.new(fn {index, fragments} ->
        accumulated_json =
          fragments
          |> Enum.map_join("", & &1.metadata.tool_call_args.fragment)

        {index, accumulated_json}
      end)

    tool_calls
    |> Enum.map(fn tool_call ->
      case Map.get(arg_fragments, tool_call.index) do
        nil ->
          Map.delete(tool_call, :index)

        json_str ->
          case Jason.decode(json_str) do
            {:ok, args} ->
              tool_call
              |> Map.put(:arguments, args)
              |> Map.delete(:index)

            {:error, _} ->
              Map.delete(tool_call, :index)
          end
      end
    end)
  end

  defp extract_usage_from_chunks(chunks) do
    chunks
    |> Enum.filter(&(&1.type == :meta))
    |> Enum.reduce(%{}, fn chunk, acc ->
      Map.merge(acc, chunk.metadata[:usage] || %{})
    end)
  end
end

model = System.get_env("REQ_LLM_MODEL") || "anthropic:claude-sonnet-4-5"

IO.puts("=== ReqLLM Tutorial: Tool Calling ===\n")
IO.puts("Model: #{model}")
IO.puts("Debug mode: #{if System.get_env("DEBUG") == "true", do: "ON", else: "OFF"}")
IO.puts("\n" <> String.duplicate("=", 50) <> "\n")

{:ok, agent} = TutorialAgent.start_link(model: model)

question = "What is 842 multiplied by 73?"
IO.puts("Question: #{question}\n")

debug_opt = if System.get_env("DEBUG") == "true", do: [debug: true], else: []
{:ok, response} = TutorialAgent.ask(agent, question, debug_opt)

IO.puts(String.duplicate("=", 50))

IO.puts(
  "\nTool calls executed: #{if response[:tool_calls], do: length(response.tool_calls), else: 0}"
)

IO.puts("\nDemo complete!")
