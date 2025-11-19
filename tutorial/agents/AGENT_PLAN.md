# AGENT_PLAN.md – req_llm Agents Tutorial

## 1) TL;DR

Create a coherent “agents tutorial” track under `tutorial/agents/` that mirrors the chapters in `OUTLINE.md`.

**Key Requirement**: Each of the first 4–5 scripts must be **standalone**. No shared helper files (`simple_agent_*.ex`) for these introductory examples. Inline tools, prompts, and logic to minimize context switching.

- **Location**: `tutorial/agents/`
- **Format**: Standalone `.exs` scripts.
- **Content**: Numbered scripts (`01`–`06`).

---

## 2) Implementation Plan

### 2.1. Setup

*   (Optional) The `mix.exs` change to compile `tutorial/` is less critical if files are standalone, but can remain for later chapters if needed.

### 2.2. Chapter 1 – LLM as a function

#### File: `tutorial/agents/01_basic_generate.exs`

-   **Status**: Done.
-   **Content**: Pure `ReqLLM.generate_text/3` call. Standalone.

---

### 2.3. Chapter 2 – Tool-calling loop

#### File: `tutorial/agents/02_tools_basic_loop.exs`

-   **Changes**: Refactor to be standalone.
-   **Content**:
    *   Define `calculator_tool` inside the script (or inline the `Tool.new` call).
    *   Define system prompt string inside the script.
    *   Implement the 3-phase loop explicitly in the script body.

---

### 2.4. Chapter 3 – Streaming & Sync Agent

#### File: `tutorial/agents/03_streaming_basics.exs`

-   **Purpose**: Streaming basics.
-   **Content**:
    *   Define `SimpleAgent.V1` GenServer inside the script.
    *   Implement `ask/2` with `ReqLLM.stream_text/3`.
    *   No tools.

#### File: `tutorial/agents/04_agent_sync_tool_calling.exs`

-   **Purpose**: GenServer with tools (V2 pattern).
-   **Content**:
    *   Define `SimpleAgent.Sync` GenServer inside.
    *   Inline `calculator_tool` function/definition.
    *   Implement the tool execution loop (Phase 1, 2, 3) as private functions within the module (replacing `SimpleAgent.Core`).

---

### 2.5. Chapter 4 – OTP Patterns (Phased)

#### File: `tutorial/agents/05_agent_phased.exs`

-   **Purpose**: `{:continue, ...}` pattern (V3).
-   **Content**:
    *   Define `SimpleAgent.Phased` GenServer inside.
    *   Inline necessary logic.
    *   (Decision): If the code becomes too long, we might introduce a local helper module *inside* the file, or just accept the length for the sake of being "standalone".

---

### 2.6. Cleanup

*   Remove `tutorial/agents/simple_agent_*.ex` files to avoid confusion and enforce the "standalone" rule for the basics.
