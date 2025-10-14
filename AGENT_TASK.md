# Model Compatibility AI Agent

## Overview

An **agentic system** (not just a workflow) that uses LLM-powered reasoning and tool calls to automatically analyze and fix failing model tests in the ReqLLM compatibility system. The AI agent makes intelligent decisions about which actions to take based on test output analysis.

**Core Principle**: The agent analyzes failures with LLM reasoning, uses tools to run tests and refresh fixtures, and provides detailed diagnostic reports. It does NOT modify source code—only fixtures.

## Current System Architecture

### Existing Components

1. **Mix Task**: `mix req_llm.model_compat`
   - Orchestrates fixture-based testing per provider/model
   - Updates `priv/supported_models.json` with status (pass/fail/excluded)
   - Supports `--record` flag to re-record fixtures from live APIs
   - Runs tests under `test/coverage/<provider>/*.exs`

2. **State Files**:
   - `priv/supported_models.json` - Single source of truth for model status
   - `priv/models_dev/*.json` - Registry of available models per provider
   - `test/support/fixtures/<provider>/<model_dir>/*.json` - Recorded API fixtures

3. **Testing Architecture**:
   - Fixture-based testing with record/replay modes
   - Comprehensive test suites covering: basic generation, streaming, tools, usage metrics
   - Tests run against cached fixtures by default, live APIs with `REQ_LLM_FIXTURES_MODE=record`

## Hybrid Design: Directed Graph Workflow with LLM Decision Points

### Architecture Philosophy

**Not a pure workflow**: Too rigid, can't handle nuanced failures
**Not a pure agent**: Too unpredictable, might waste tokens or make wrong choices

**Hybrid approach**: Deterministic workflow with LLM-powered decision nodes

```
Workflow controls:           LLM decides:
- Loop iteration             - Why did this test fail?
- Tool execution order       - What action should I take?
- State transitions          - Is this fixed now?
- Parallelization            - Should I stop this provider?
```

**Benefits**:
- Predictable flow and resource usage
- LLM only used where human-like reasoning needed
- Easy to debug and test
- Token-efficient (LLM called only for failures)

### Directed Graph: Main Loop

```
                    ┌─────────────────────┐
                    │   START             │
                    │   Load all failing  │
                    │   models from state │
                    └──────────┬──────────┘
                               │
                               ▼
                    ┌─────────────────────┐
                    │  WORKFLOW:          │
                    │  Pop next model     │
                    │  from queue         │
                    └──────────┬──────────┘
                               │
                               ▼
                        ┌──────────┐
                        │ Queue    │
                        │ empty?   │
                        └─┬──────┬─┘
                      Yes│      │No
                          │      │
                          │      ▼
                          │   ┌──────────────────────┐
                          │   │ WORKFLOW:            │
                          │   │ Run test (no debug)  │
                          │   │ System.cmd(mix mc..) │
                          │   └─────────┬────────────┘
                          │             │
                          │             ▼
                          │      ┌──────────┐
                          │      │ Passed?  │
                          │      └─┬──────┬─┘
                          │    Yes│      │No
                          │       │      │
                          │       │      ▼
                          │       │   ┌──────────────────────┐
                          │       │   │ WORKFLOW:            │
                          │       │   │ Run with --debug     │
                          │       │   └─────────┬────────────┘
                          │       │             │
                          │       │             ▼
                          │       │   ┌──────────────────────┐
                          │       │   │ 🤖 LLM DECISION:     │
                          │       │   │ Analyze debug output │
                          │       │   │ Return: action + why │
                          │       │   └─────────┬────────────┘
                          │       │             │
                          │       │             ▼
                          │       │   ┌─────────────────────────────┐
                          │       │   │  Action =                   │
                          │       │   │  "record" | "retry" |       │
                          │       │   │  "deprecated" | "test_bug"  │
                          │       │   └──┬────┬────┬────┬───────────┘
                          │       │      │    │    │    │
                          │       │   ┌──┘    │    │    └───┐
                          │       │   │       │    │        │
                          │       │   ▼       ▼    ▼        ▼
                          │       │ Record  Retry Report  Stop
                          │       │ Fixture Wait  Issue   Provider
                          │       │   │       │    │        │
                          │       │   └───┬───┴────┴───┬────┘
                          │       │       │            │
                          │       │       ▼            ▼
                          │       │   Verify      Skip remaining
                          │       │   Fixed?      provider models
                          │       │       │            │
                          │       └───────┴────────────┘
                          │                    │
                          │                    ▼
                          │              Log result,
                          │              loop to next model
                          │                    │
                          └────────────────────┘
                                       ▼
                                 ┌──────────┐
                                 │   END    │
                                 │ Generate │
                                 │  Report  │
                                 └──────────┘
```

**Key: Workflow controls flow, LLM makes ONE decision per failure**

### Workflow Steps (Deterministic)

**Step 1: Load Queue** (Workflow)
```elixir
failing_models = 
  read_supported_models()
  |> Enum.filter(fn {_spec, entry} -> entry["status"] == "fail" end)
  |> Enum.group_by(fn {spec, _} -> 
    spec |> String.split(":") |> List.first() |> String.to_atom()
  end)
```

**Step 2: Pop Next Model** (Workflow)
```elixir
{spec, queue} = Queue.pop(queue)
{provider, model_id} = parse_spec(spec)
```

**Step 3: Run Test** (Workflow - System.cmd)
```elixir
{output, exit_status} = 
  System.cmd("mix", ["req_llm.model_compat", spec])
```

**Step 4: Branch on Exit Status** (Workflow)
```elixir
case exit_status do
  0 -> 
    mark_fixed(spec)
    continue_loop()
  
  _ -> 
    # Call LLM for diagnosis
    run_with_debug_and_analyze(spec)
end
```

**Step 5: Run with Debug** (Workflow - System.cmd)
```elixir
{debug_output, _} = 
  System.cmd("mix", ["req_llm.model_compat", spec, "--debug"])
```

**Step 6: LLM Decision Point** (🤖 AI Call)
```elixir
prompt = """
Analyze this test failure and return ONE action:

Test output:
#{debug_output}

Return JSON: {"action": "record|retry|deprecated|test_bug", "reason": "..."}
"""

{:ok, decision} = ReqLLM.generate_text(model, prompt)
action = parse_decision(decision)
```

**Step 7: Execute Action** (Workflow - based on LLM decision)
```elixir
case action do
  "record" -> 
    System.cmd("mix", ["req_llm.model_compat", spec, "--record"])
    verify_fixed(spec)
  
  "retry" ->
    :timer.sleep(delay)
    run_test(spec)
  
  "deprecated" ->
    report_deprecated(spec)
  
  "test_bug" ->
    report_test_bug(spec)
    stop_provider(provider)
end
```

### Phase 3: Parallelization with Constraints

**Concurrency Model**: Provider-scoped parallel workers

```elixir
# Configuration
config = %{
  max_workers: 4,                    # Total concurrent workers
  max_per_provider: 1,               # Models per provider at once
  rate_limit_delay: 2_000,           # ms between requests (same provider)
  retry_backoff_base: 15_000         # ms for exponential backoff
}
```

**How it works**:

1. **Task.async_stream with provider grouping**:
   - Group failing models by provider
   - Each provider gets its own sequential queue
   - Multiple providers can run in parallel

2. **Provider-level semaphore**:
   - ETS table tracks active workers per provider
   - Before starting work on a model, check: `active_count[provider] < max_per_provider`
   - If at limit, worker waits

3. **Rate limiting per provider**:
   - Track last API call timestamp per provider in ETS
   - Enforce minimum delay between calls to same provider
   - Prevents rate limit errors while maximizing throughput

**Example**: Testing 12 models across 4 providers with `max_per_provider: 1`

```
Time 0s:  [Anthropic:model-1] [OpenAI:model-1] [Google:model-1] [Groq:model-1]
Time 3s:  [Anthropic:model-2] [OpenAI:model-2] [Google:model-2] [Groq:model-2]
Time 6s:  [Anthropic:model-3] [OpenAI:model-3] [Google:model-3] [Groq:model-3]

Result: ~3x faster than sequential, no rate limit violations
```

**Alternative**: If providers can handle more load, set `max_per_provider: 2`

```
Time 0s:  [Anthropic:m1] [Anthropic:m2] [OpenAI:m1] [OpenAI:m2]
Time 2s:  [Anthropic:m3] [Anthropic:m4] [OpenAI:m3] [OpenAI:m4]
```

### Phase 4: Report Generation

Generate structured reports:

1. **Console Summary**:
   - Fixed: count and list
   - Skipped (auth): providers and models
   - Deprecated/needs exclusion: list specs
   - Transient exhausted: models that failed after retries
   - Fixture mismatch unresolved: models with persistent format issues
   - Test bugs suspected: providers with implementation issues

2. **Run Log** (`priv/model_compat_runs/run-YYYYmmdd-HHMMSS.jsonl`):
   ```json
   {"spec": "anthropic:claude-3-5-haiku-20241022", "provider": "anthropic", "model_id": "claude-3-5-haiku-20241022", "attempt": 1, "exit_status": 0, "category": "fixed", "action_taken": "recorded_fixtures", "duration_ms": 4521}
   ```

## LLM Analysis Instead of Error Taxonomy

**Old Approach** (workflow): Regex patterns → fixed category → predetermined action

**New Approach** (agentic): LLM reads full debug output → reasons about root cause → chooses best action

### System Prompt for Analysis

```elixir
"""
You are a ReqLLM test diagnostician. Your job is to analyze failing model compatibility tests and determine the best action.

You have access to these tools:
- run_model_compat(spec, record: bool, debug: bool) - Run a test
- retry_after_delay(seconds) - Wait before retrying
- report_issue(category, details) - Log for human review
- mark_deprecated(spec) - Suggest model exclusion
- read_fixture(provider, model_id, test_name) - View fixture content
- read_code(file_path) - Read test or provider implementation

When analyzing a test failure, consider:

1. **Stale Fixture**: API response format changed
   - Look for: JSON decode errors, unexpected fields, schema mismatches
   - Action: Use run_model_compat with record: true to refresh

2. **Transient Failure**: Temporary API issues
   - Look for: 429, 5xx, timeouts, rate limits, network errors
   - Action: Use retry_after_delay, then run_model_compat again

3. **Deprecated Model**: Provider removed/retired the model
   - Look for: 404, "model not found", "unsupported model"
   - Action: Use mark_deprecated

4. **Test Bug**: Our test code has a bug
   - Look for: Elixir exceptions in ReqLLM code paths, assertion failures
   - Action: Report with code context using report_issue

5. **Authentication**: Missing or invalid API key
   - Look for: 401, "unauthorized", "invalid api key"
   - Action: Report auth issue (library already handles this)

IMPORTANT: 
- Always run with debug: false first to save tokens
- Only request debug: true if you need more information
- You can read fixture files and code to understand context
- After taking an action, verify the result before moving to next model
- If uncertain, report_issue rather than taking risky action
"""
```

### Example AI Reasoning Process

**Failure Case 1**: Anthropic model returns 404

```
AI thinks: "I see a 404 error and 'model_not_found' in the output. 
This looks like the model was deprecated. Let me verify by checking 
if other Anthropic models are passing... Yes, claude-3-5-sonnet works.
Decision: mark_deprecated this model."

Tool call: mark_deprecated("anthropic:claude-3-opus-20240229")
```

**Failure Case 2**: JSON decode error in fixture

```
AI thinks: "The test is failing with 'unexpected field: reasoning_tokens' 
in the fixture JSON. This wasn't there before. The API probably added 
a new field. Let me re-record the fixture with the current API response."

Tool call: run_model_compat("openai:gpt-4o", record: true, debug: false)
```

**Failure Case 3**: Rate limit error

```
AI thinks: "Got a 429 rate limit error. This is transient. I should 
wait before retrying. The provider suggests 60 seconds in the header."

Tool call: retry_after_delay(60)
Then: run_model_compat("groq:llama-3-8b", record: false, debug: false)
```

## GenServer Architecture

### Module: `ReqLLM.Tools.ModelCompatAgent`

**Key difference from `ReqLLM.Examples.Agent`**: 
- Examples.Agent is conversational (user prompts → AI responds)
- ModelCompatAgent is autonomous (self-driving with LLM reasoning)

### State Structure

```elixir
defstruct [
  :history,            # ReqLLM.Context - conversation history with LLM
  :tools,              # [ReqLLM.Tool.t()] - available tools
  :model,              # "anthropic:claude-3-5-sonnet-20241022" - reasoning model
  :queue,              # [{provider, model_id, spec}] - failing models to process
  :completed,          # MapSet - specs already processed
  :provider_state,     # %{provider => :active | {:stopped, reason}}
  :results,            # [%{spec, category, actions_taken, duration_ms}]
  :config,             # %{max_workers, max_per_provider, rate_limit_delay}
  :run_id,             # "run-20251014-194523"
  :output_path,        # "priv/model_compat_runs/run-20251014-194523.jsonl"
  :worker_pool         # %{provider => [worker_pids]}
]
```

### Configuration

```elixir
config = %{
  model: "anthropic:claude-3-5-sonnet-20241022",
  max_workers: 4,
  max_per_provider: 1,
  rate_limit_delay: 2_000,
  retry_max: 2,
  debug: false
}
```

### Public API

```elixir
# Start the agent
{:ok, pid} = ReqLLM.Tools.ModelCompatAgent.start_link()

# Prompt the agent to start (it self-drives from here)
:ok = ReqLLM.Tools.ModelCompatAgent.prompt(pid, "Process all failing models")

# Monitor progress
%{completed: 15, remaining: 27, current_workers: 3} = 
  ReqLLM.Tools.ModelCompatAgent.status(pid)

# Stop and get final report
%{fixed: [...], deprecated: [...], ...} = 
  ReqLLM.Tools.ModelCompatAgent.stop(pid)
```

### AI Tools (ReqLLM.Tool definitions)

The AI agent uses these tools via function calling:

```elixir
Tool.new!(
  name: "run_model_compat",
  description: """
  Run the model compatibility test suite for a specific model.
  Returns test output including pass/fail status, error messages, and fixture details.
  """,
  parameter_schema: [
    spec: [type: :string, required: true, 
           doc: "Model spec like 'anthropic:claude-3-5-sonnet-20241022'"],
    record: [type: :boolean, default: false, 
             doc: "If true, record new fixtures from live API"],
    debug: [type: :boolean, default: false, 
            doc: "If true, include verbose debug output"]
  ],
  callback: &ModelCompatTools.run_model_compat/1
)

Tool.new!(
  name: "get_next_failing_model",
  description: "Get the next failing model to process. Returns nil if queue is empty.",
  parameter_schema: [],
  callback: &ModelCompatTools.get_next_failing/1
)

Tool.new!(
  name: "retry_after_delay",
  description: "Sleep for specified seconds (for rate limit backoff)",
  parameter_schema: [
    seconds: [type: :integer, required: true, doc: "Seconds to wait"]
  ],
  callback: &ModelCompatTools.retry_after_delay/1
)

Tool.new!(
  name: "report_issue",
  description: "Log an issue that requires human intervention",
  parameter_schema: [
    category: [type: :string, required: true, 
               doc: "Category: deprecated, test_bug, auth_error, unknown"],
    spec: [type: :string, required: true, doc: "Model spec"],
    details: [type: :string, required: true, doc: "Diagnostic details"]
  ],
  callback: &ModelCompatTools.report_issue/1
)

Tool.new!(
  name: "mark_deprecated",
  description: "Mark a model as deprecated/excluded",
  parameter_schema: [
    spec: [type: :string, required: true, doc: "Model spec to mark"]
  ],
  callback: &ModelCompatTools.mark_deprecated/1
)

Tool.new!(
  name: "read_fixture",
  description: "Read a fixture file to understand test expectations",
  parameter_schema: [
    provider: [type: :string, required: true, doc: "Provider name"],
    model_id: [type: :string, required: true, doc: "Model ID"],
    test_name: [type: :string, required: true, 
                doc: "Test name like 'basic', 'streaming', 'tool_multi'"]
  ],
  callback: &ModelCompatTools.read_fixture/1
)

Tool.new!(
  name: "read_code",
  description: "Read test or provider implementation code",
  parameter_schema: [
    file_path: [type: :string, required: true, 
                doc: "Relative path like 'lib/req_llm/providers/anthropic.ex'"]
  ],
  callback: &ModelCompatTools.read_code/1
)

Tool.new!(
  name: "stop_provider",
  description: "Stop processing remaining models for a provider (test bug detected)",
  parameter_schema: [
    provider: [type: :string, required: true, doc: "Provider to stop"],
    reason: [type: :string, required: true, doc: "Why stopping"]
  ],
  callback: &ModelCompatTools.stop_provider/1
)

Tool.new!(
  name: "check_status",
  description: "Check if a model now passes after taking action",
  parameter_schema: [
    spec: [type: :string, required: true, doc: "Model spec to check"]
  ],
  callback: &ModelCompatTools.check_status/1
)
```

### Processing Loop (AI-Driven)

```elixir
def handle_call({:prompt, "Process all failing models"}, _from, state) do
  # AI agent starts autonomous operation
  prompt = """
  You are now in control. Your task is to process all failing model tests.
  
  Start by calling get_next_failing_model to get the first model to work on.
  Then follow the Observe-Reason-Act cycle for each model until the queue is empty.
  
  Remember: Always try without --debug first to save tokens.
  """
  
  state = append_to_history(state, Context.user(prompt))
  
  # Let AI decide what to do
  case stream_and_handle_tools(state) do
    {:ok, new_state, _response} ->
      {:reply, :ok, new_state}
    
    {:error, error} ->
      {:reply, {:error, error}, state}
  end
end

defp stream_and_handle_tools(state) do
  # This is similar to Examples.Agent but the AI drives the loop
  case ReqLLM.stream_text(state.model, state.history.messages, tools: state.tools) do
    {:ok, stream_response} ->
      chunks = Enum.to_list(stream_response.stream)
      
      case extract_tool_calls_from_chunks(chunks) do
        [] ->
          # AI provided reasoning but no tool call yet
          text = chunks |> Enum.map_join("", & &1.text)
          new_state = append_to_history(state, Context.assistant(text))
          {:ok, new_state, text}
        
        tool_calls ->
          # Execute tools and continue
          new_state = execute_tool_calls(state, chunks, tool_calls)
          
          # AI continues reasoning after tool results
          stream_and_handle_tools(new_state)
      end
    
    {:error, error} ->
      {:error, error}
  end
end

defp execute_tool_calls(state, chunks, tool_calls) do
  initial_text = chunks |> Enum.map_join("", & &1.text)
  assistant_msg = Context.assistant(initial_text, tool_calls: tool_calls)
  state = append_to_history(state, assistant_msg)
  
  # Execute each tool and append results to history
  Enum.reduce(tool_calls, state, fn tool_call, state ->
    tool = Enum.find(state.tools, fn t -> t.name == tool_call.name end)
    
    if tool do
      case Tool.execute(tool, tool_call.arguments) do
        {:ok, result} ->
          log_tool_execution(tool_call.name, tool_call.arguments, result)
          
          tool_result = Context.tool_result_message(
            tool_call.name, 
            tool_call.id, 
            result
          )
          
          append_to_history(state, tool_result)
        
        {:error, error} ->
          log_tool_error(tool_call.name, error)
          
          tool_result = Context.tool_result_message(
            tool_call.name,
            tool_call.id,
            %{error: to_string(error)}
          )
          
          append_to_history(state, tool_result)
      end
    else
      state
    end
  end)
end
```

**Key Insight**: The AI is in full control. It:
1. Calls `get_next_failing_model` when ready
2. Calls `run_model_compat` to test
3. Reads output and reasons about cause
4. Calls appropriate tools (`run_model_compat` with `record: true`, `mark_deprecated`, etc.)
5. Verifies results with `check_status`
6. Loops back to step 1

## Mix Task Wrapper

### `mix req_llm.agent_model_compat`

```elixir
defmodule Mix.Tasks.ReqLlm.AgentModelCompat do
  @shortdoc "Run AI agent to auto-refresh failing model fixtures"
  
  @moduledoc """
  Automated model compatibility fixture refresh agent.
  
  ## Usage
  
      mix req_llm.agent_model_compat
      mix req_llm.agent_model_compat --debug
      mix req_llm.agent_model_compat --provider anthropic
  
  ## Options
  
      --debug       Enable verbose output
      --provider    Limit to specific provider
      --dry-run     Show what would be done without recording
  """
  
  use Mix.Task
  
  def run(args) do
    Application.ensure_all_started(:req_llm)
    
    opts = parse_args(args)
    
    {:ok, agent} = ReqLLM.Tools.ModelCompatAgent.start_link(opts)
    
    :ok = ReqLLM.Tools.ModelCompatAgent.run(agent)
    
    # Wait for completion (agent calls stop when done)
    receive do
      {:agent_complete, report} ->
        print_report(report)
    end
  end
end
```

## Implementation Effort

### Core Agent (3-5 hours)

- **ModelCompatAgent GenServer**: Based on Examples.Agent structure
  - State with history, tools, queue, results
  - Tool execution loop with streaming
  - Autonomous AI-driven processing
- **Tool implementations**: 9 tools (run_model_compat, get_next_failing, etc.)
  - Each tool: 20-50 lines of implementation
  - File I/O, System.cmd wrappers, ETS operations
- **System prompt engineering**: Create effective diagnostic prompt
  - Include examples of good reasoning
  - Define tool usage patterns

### Parallelization (2-3 hours)

- **Provider-scoped workers**: ETS-based coordination
  - Track active workers per provider
  - Rate limit enforcement
  - Queue management
- **Task.async_stream integration**: Spawn workers safely
- **Backpressure handling**: Limit concurrent LLM calls

### Reporting & Polish (1-2 hours)

- **JSONL logging**: Structured run logs
- **Console summary**: Formatted output with colors
- **Mix task wrapper**: CLI interface

### Total: ~6-10 hours for full agentic system

## Future Enhancements (Optional)

### Advanced Error Classification (if needed)

If regex coverage proves insufficient, add LLM-powered classification:

```elixir
defp classify_error_with_llm(output) do
  prompt = """
  Analyze this test failure output and categorize it:
  
  Categories:
  - transient: Network, rate limit, timeout, 5xx errors
  - auth: Authentication/authorization failures
  - deprecated_not_found: Model removed or deprecated
  - fixture_mismatch: Response format changed
  - test_bug: Implementation error in test code
  
  Output: #{output}
  
  Respond with only the category name.
  """
  
  {:ok, response} = ReqLLM.generate_text("anthropic:claude-3-5-haiku-20241022", prompt)
  String.trim(response)
end
```

### Parallel Processing

- Add per-provider token bucket rate limiter
- Concurrent GenServer workers per provider
- Shared ETS table for results aggregation

### Enhanced Reporting

Generate markdown reports:

1. **`exclusions_needed.md`**: Deprecated models for manual `models_local` patches
2. **`suspected_test_bugs.md`**: Stack traces and frequency analysis
3. **`transient_failures.md`**: Retry suggestions with timing

### Persistent Job Queue

- ETS or disk-backed queue for resume-on-restart
- Track partial runs and resume from checkpoint
- Handle long-running operations gracefully

## Example Output

### Console Summary

```
Model Compatibility Agent - Run 2025-10-14T19:45:23Z
====================================================

Processed: 42 models across 6 providers

Results:
  ✅ Fixed: 15 models
  ⏭️  Skipped (auth): 3 providers (8 models)
  ⚠️  Deprecated/needs exclusion: 5 models
  🔄 Transient exhausted: 3 models
  🔧 Fixture mismatch unresolved: 2 models
  🐛 Test bugs suspected: 1 provider (9 models)

Fixed Models:
  - anthropic:claude-3-5-haiku-20241022 (2 attempts, 8.2s)
  - openai:gpt-4o-mini (1 attempt, 3.1s)
  ...

Action Required:
  1. Add exclusions for deprecated models:
     - xai:grok-beta-20241201
     - google:gemini-1.0-pro
  
  2. Missing API keys:
     - openrouter: Set OPENROUTER_API_KEY
     - cerebras: Set CEREBRAS_API_KEY
  
  3. Investigate test bugs:
     - groq: FunctionClauseError in ProviderTest.Comprehensive
       Sample: groq:llama-3.1-8b-instant

Log: priv/model_compat_runs/run-20251014-194523.jsonl
```

### JSONL Log Sample

```jsonl
{"run_id":"run-20251014-194523","spec":"anthropic:claude-3-5-haiku-20241022","provider":"anthropic","model_id":"claude-3-5-haiku-20241022","attempt":1,"exit_status":1,"category":"transient","action_taken":"retry_scheduled","duration_ms":3421,"timestamp":"2025-10-14T19:45:26Z"}
{"run_id":"run-20251014-194523","spec":"anthropic:claude-3-5-haiku-20241022","provider":"anthropic","model_id":"claude-3-5-haiku-20241022","attempt":2,"exit_status":0,"category":"fixed","action_taken":"recorded_fixtures","duration_ms":4521,"timestamp":"2025-10-14T19:45:45Z"}
{"run_id":"run-20251014-194523","spec":"openrouter:anthropic/claude-3-5-sonnet","provider":"openrouter","model_id":"anthropic/claude-3-5-sonnet","attempt":1,"exit_status":1,"category":"auth","action_taken":"skipped_provider","duration_ms":234,"timestamp":"2025-10-14T19:45:47Z"}
```

## Risks and Guardrails

### Rate Limits and Quotas
- Default sequential processing (concurrency: 1)
- Exponential backoff for transient failures
- Configurable per-provider sleep intervals

### Credentials
- Pre-check all provider API keys before processing
- Skip and report missing credentials
- Never expose keys in logs

### Fixture Recording
- Only record for failing models (never record-all)
- Validate fixtures exist after recording
- Avoid hammering APIs unnecessarily

### Code Safety
- **NEVER modify source code**
- **NEVER auto-edit exclusion patches**
- **NEVER modify test implementations**
- Only write: fixtures, state JSON, run logs

### Network Reliability
- Cap retries to 2 per model
- Clear logging of all attempts
- Graceful handling of network failures

## Success Criteria

1. **Fixture Refresh**: Successfully re-record fixtures for transient failures
2. **Error Classification**: Accurately categorize 90%+ of failures
3. **No False Positives**: Never mark passing tests as failures
4. **Rate Limit Compliance**: Zero provider throttling incidents
5. **Clear Reporting**: Actionable summaries for manual intervention
6. **Safe Operation**: Zero code modifications, zero credential leaks
