# tutorial/agents/02_tools_basic_loop.exs
#
# Chapter 2: The Tool Loop (Standalone)
# Goal: Demonstrate the 3-phase "Reason-Act-Answer" loop explicitly.
#
# Run with:
#   iex -S mix run tutorial/agents/02_tools_basic_loop.exs

import ReqLLM.Context

alias ReqLLM.{Context, Tool, ToolCall}

require IEx

# Ensure dotenvy loads .env file if present
_ = Dotenvy.source(".env")

# --- DEFINITIONS (Inlined) ---

defmodule TutorialTools do
  def calculator_tool do
    Tool.new!(
      name: "calculator",
      description: ~s|Safely evaluate a math expression. Example: {"expression":"(2+3)*7"}|,
      parameter_schema: [
        expression: [type: :string, required: true, doc: "Math expression, e.g., \"(2+3)^2 / 5\""]
      ],
      callback: fn args ->
        # Handle both atom keys (internal) and string keys (JSON)
        expr = args[:expression] || args["expression"]

        if is_binary(expr) do
          case Abacus.eval(expr) do
            {:ok, val} -> {:ok, val}
            {:error, r} -> {:error, "Invalid expression: #{Exception.message(r)}"}
          end
        else
          {:error, "Missing 'expression' parameter"}
        end
      end
    )
  end
end

system_prompt = """
You are a helpful assistant with access to tools.
- When a user asks a math question, use the calculator tool.
- Provide only valid JSON for tool arguments.
- After tool results are provided, give a concise final answer.
"""

# --- MAIN SCRIPT ---

# 0. Setup
model = System.get_env("REQ_LLM_MODEL", "anthropic:claude-haiku-4.5")
tools = [TutorialTools.calculator_tool()]

# Build initial context
context =
  Context.new([
    system(system_prompt),
    user("Calculate 128 * 32, then divide by 2.")
  ])

IO.puts(">> Question: Calculate 128 * 32, then divide by 2.\n")

# --- PHASE 1: ASK MODEL ---
IO.puts(">> [Phase 1] Asking model (with tools)...")
IO.puts("   (Pausing before Phase 1. Type `continue` or `respawn` to proceed.)")
IEx.pry()
{:ok, response1} = ReqLLM.generate_text(model, context, tools: tools)

tool_calls = ReqLLM.Response.tool_calls(response1)

IO.puts(">> [Phase 1] Response received.")
IEx.pry()

if tool_calls == [] do
  IO.puts(">> No tools called. Answer: #{ReqLLM.Response.text(response1)}")
else
  IO.puts(">> Model requested #{length(tool_calls)} tool(s).")

  # --- PHASE 2: EXECUTE TOOLS ---
  IO.puts(">> [Phase 2] Executing tools...")

  # Append assistant message (with tool calls)
  context2 = Context.append(context, response1.message)

  # Run tools and append results
  context3 =
    Enum.reduce(tool_calls, context2, fn call, acc_context ->
      args = ToolCall.args_map(call)
      name = ToolCall.name(call)
      IO.puts("   -> Calling #{name} with #{inspect(args)}")

      # Execute the tool
      result =
        case Tool.execute(TutorialTools.calculator_tool(), args) do
          {:ok, val} -> val
          {:error, reason} -> "Tool error: #{inspect(reason)}"
        end

      IO.puts("      Result: #{inspect(result)}")

      # Append result
      # Context.tool_result expects (tool_call_id, content_string)
      Context.append(acc_context, Context.tool_result(call.id, to_string(result)))
    end)

  IO.puts(">> [Phase 2] Tools executed.")
  IEx.pry()

  # --- PHASE 3: FINAL ANSWER ---
  IO.puts(">> [Phase 3] Asking model for final answer...")
  {:ok, response2} = ReqLLM.generate_text(model, context3, tools: [])

  final_text = ReqLLM.Response.text(response2)
  IO.puts("\n>> Final Answer:\n")
  IO.puts(final_text)
  IEx.pry()
end
