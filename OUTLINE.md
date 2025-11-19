
## 1. Chapter 1 – LLM as a function

### `tutorial/01_basic_generate.exs`  (new)

Goal: “LLM is just a pure function: prompt → text.”

Contents:

* `Mix.install/1` with `req_llm`
* Read `REQ_LLM_MODEL` or default
* Single `ReqLLM.generate_text/3` call with a string
* Extract final text with `ReqLLM.Response.text/1`
* Print to console

Teaching points:

* No tools
* No streaming
* No `Context`
* Just “call an LLM from Elixir”

---

## 2. Chapter 2 – The tool-calling loop, no streaming, no GenServer

### `tutorial/02_tools_basic_loop.exs`  (new, key teaching file)

Goal: Show the tool loop in the simplest possible way.

Contents:

* `Mix.install/1` with `req_llm`, `abacus`, `jason`
* `Code.require_file("simple_agent_tools.ex", __DIR__)`
* `Code.require_file("simple_agent_prompts.ex", __DIR__)`
* `alias ReqLLM.Context`
* Build:

  * `model`
  * `tools = [SimpleAgent.Tools.calculator_tool()]`
  * `history = Context.new([system(prompt)]) |> Context.append(user(question))`
* Step 1: `ReqLLM.generate_text/3` with `tools: tools`

  * Collect `tool_calls = ReqLLM.Response.tool_calls(response1)`
* `if tool_calls == []` → print direct answer, done.
* Else:

  * Execute each tool call with `ReqLLM.Tool.execute/2` and `ReqLLM.ToolCall.args_map/1`
  * Build `tool_result` messages with `Context.tool_result/2` or `tool_result_message/3`
  * Append `response1.message` and all tool results to a new `history2`
  * Step 2: call `ReqLLM.generate_text/3` again (no tools now) for final answer
* Print final answer

Teaching points:

* `ReqLLM.Context` and message roles (`system`, `user`, `assistant`, `tool_result`)
* What a tool call looks like (`ReqLLM.Response.tool_calls/1`)
* The 3-step Reason–Act–Answer loop:

  1. Ask model, get tool calls
  2. Run tools in Elixir
  3. Ask model again with results

This is the core lesson.

---

## 3. Chapter 3 – Streaming and agents, still one process

### 3.1 Streaming only, no tools

You already have this; you can keep it with minor renaming.

#### `tutorial/03_streaming_basics.exs`  (rename from `v1_streaming_agent.exs` or `step1_streaming.exs`)

Goal: Show streaming tokens and `ReqLLM.StreamResponse`.

Contents:

* `SimpleAgent.V1` GenServer that:

  * Stores `model` and `Context` in state
  * On `ask/2`, appends user, calls `ReqLLM.stream_text/3`
  * Reduces `stream_response.stream` to collect final text
  * Optionally prints usage and finish_reason

Teaching points:

* Difference between `generate_text/3` vs `stream_text/3`
* What a “chunk” looks like (at a high level)
* That streaming doesn’t change semantics, just delivery

You do not talk about tools here, only about output streaming.

### 3.2 Synchronous tool-calling agent (V2 pattern) using Core

#### `tutorial/04_agent_sync_tool_calling.exs`  (new; “V2 done right”)

Goal: Wrap the loop from `02_tools_basic_loop.exs` in a GenServer and use `SimpleAgent.Core`.

Contents:

* `Mix.install/1` with `req_llm`, `abacus`, `jason`
* `Code.require_file/2` for:

  * `simple_agent_core.ex`
  * `simple_agent_tools.ex`
  * `simple_agent_prompts.ex`
* `defmodule SimpleAgent.Sync`:

  * `use GenServer`
  * Struct: `%{model, history, tools}`
  * `init/1`: set model, tools, and history with system prompt
  * `ask/2`: `GenServer.call/3`
  * `handle_call/3`:

    1. Append user message
    2. `Core.stream_with_tools/4`
    3. Append assistant with `tool_calls`
    4. `Core.execute_tools_sequential/3`
    5. `Core.finalize/3`
    6. Append final assistant text and reply

Teaching points:

* Where state (history) lives (inside the server)
* That the *loop itself* didn’t change; only its “host” did
* How `SimpleAgent.Core` encodes the 3 phases

If you want, you can show that `Core.stream_with_tools/4` is essentially “Phase 1 of `02_tools_basic_loop.exs`, but with streaming and tool-chunk parsing.”

---

## 4. Chapter 4 – OTP patterns for the same loop

Here you switch from “what is the tool loop?” to “how can we schedule it differently?”

### 4.1 Phased processing with `{:continue, action}` (V3)

#### `tutorial/05_agent_phased.exs`  (your current `v3_async_tool_calling_agent.exs`)

Goal: Non-blocking callers, per-phase observability.

Contents:

* `SimpleAgent.V3` exactly as you have it:

  * `handle_call({:ask, ...})` that appends user and returns `{:noreply, ..., {:continue, {:stream_response, from}}}`
  * `handle_continue/2` for:

    * `{:stream_response, from}`
    * `{:execute_tools, from, calls}`
    * `{:finalize_response, from}`
  * Uses `SimpleAgent.Core` in each phase

Teaching points:

* `GenServer.reply/2`
* `{:continue, action}` pattern
* How to split one logical loop into multiple callbacks

You explicitly tell them: “The tool loop didn’t change. We just spread the phases over multiple callbacks.”

### 4.2 Parallel tool execution with `Task.Supervisor` (V5)

#### `tutorial/06_agent_parallel_tools.exs`  (your `v5_parallel_tools_agent.exs`)

Goal: Show that tool execution itself can be parallelized, but the 3-phase structure remains.

Contents:

* `SimpleAgent.V5` as you have it now:

  * Same `{:continue, action}` phases as V3
  * `handle_continue({:execute_tools_parallel, ...})` uses `Task.Supervisor.async_stream_nolink/5`
  * Per-tool timeouts and error isolation
  * Prints timing metrics

Teaching points:

* Parallel vs sequential tool execution
* Timeouts and error handling per tool
* That Phase 2 (execute tools) is the only one that changed; Phases 1 and 3 are identical to V3

### 4.3 Architecture doc

#### `tutorial/ARCHITECTURE.md` (already there)

You already have an excellent comparison of V2, V3, V5. In the narrative:

* Link `04_agent_sync_tool_calling.exs` as “V2 pattern”
* Link `05_agent_phased.exs` as “V3 pattern”
* Link `06_agent_parallel_tools.exs` as “V5 pattern”

---

## 5. Chapter 5 – Web UI (optional, after the loop is solid)

You already have good examples; just reposition them as a separate chapter that assumes the loop is understood.

### 5.1 LiveView chat with integrated tool calling

#### `tutorial/v4_phoenix_liveview_agent.exs`

Goal: Show how the same 3 phases look in a browser UI.

Topics:

* LiveView assigns as the “stateful agent”
* Streaming into the UI
* Visualizing tool calls and results

### 5.2 “Production-style” streaming components

#### `tutorial/streaming_liveview_example/*`

Goal: Show a more realistic Phoenix integration against OpenAI.

Topics:

* Component-based chat UI (`StreamingChatComponents`)
* `StreamingChatLive` patterns: streaming messages, error handling
* `StreamingChat` module using your `PetalPro.AI.OpenAI` wrapper

You can explicitly say: “Internally, this is just Phase 1 (streaming) of the same loop; we’re not running tools in this example.”

---

## 6. Files to de-emphasize or refactor

To keep the teaching path clean:

* Mark `tutorial/tool_calling_agent.exs` and `tutorial/step1_streaming.exs` as “legacy” or remove after you fold their ideas into the numbered `01–06` scripts.
* Deprecate `tutorial/simpleagent_helpers.ex` once everything uses `SimpleAgent.Core` + `SimpleAgent.Parser`.
* In `simple_agent_tutorial.livemd`, mirror the same chapter structure:

  * Section 1 → `01_basic_generate.exs`
  * Section 2 → inline version of `02_tools_basic_loop.exs`
  * Section 3 → call into `SimpleAgent.Sync` from `04_agent_sync_tool_calling.exs`
  * etc.

---

If you create exactly these files and anchor each chapter on one of them, you get a clean teaching arc:

* 01: LLM basics
* 02: Tool loop, clearest possible form
* 03: Streaming + GenServer
* 04–06: OTP patterns (phased, parallel)
* 07+: UI

Everything points back to the same 3-phase loop, which is exactly what you want to teach.
