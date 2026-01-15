# Planning Phase

You are tasked with creating a detailed implementation plan for an **Elixir Mix project**. Be skeptical, thorough, and produce a high-quality technical specification.

## Prerequisites

Before starting planning, verify the codebase is in a healthy state:

```bash
mix test
mix quality  # or: mix format --check-formatted && mix compile --warnings-as-errors && mix dialyzer && mix credo --strict
```

If these fail, address them or note as blockers before proceeding.

## Item Details
- **ID:** {{id}}
- **Title:** {{title}}
- **Section:** {{section}}
- **Overview:** {{overview}}
- **Branch:** {{branch_name}}
- **Base Branch:** {{base_branch}}
- **Working Directory:** {{item_path}}

## Research Summary
{{research}}

## Planning Process

### Step 1: Validate Understanding

1. **Verify the research findings:**
   - Cross-reference the requirements with actual code
   - Identify any discrepancies or gaps
   - Note assumptions that need verification

2. **Confirm scope:**
   - What's explicitly IN scope
   - What's explicitly OUT of scope
   - Dependencies on other work

### Step 2: Design the Solution

1. **Evaluate approaches:**
   - Consider multiple implementation options
   - Weigh pros/cons of each
   - Select the approach that best fits existing patterns

2. **Break down into phases:**
   - Each phase should be independently testable
   - Order phases to minimize risk
   - Consider rollback strategies

### Step 3: Create User Stories

For each discrete piece of work:
- Clear acceptance criteria
- Priority (1 = highest)
- Estimated complexity

## Output

Create TWO files at `{{item_path}}`:

### 1. plan.md - Detailed Implementation Plan

```markdown
# {{title}} Implementation Plan

## Overview
[Brief description of what we're implementing and why]

## Current State Analysis
[What exists now, what's missing, key constraints discovered]

## Desired End State
[Specification of the desired end state and how to verify it]

### Key Discoveries:
- [Important finding with file:line reference]
- [Pattern to follow]
- [Constraint to work within]

## What We're NOT Doing
[Explicitly list out-of-scope items to prevent scope creep]

## Implementation Approach
[High-level strategy and reasoning]

---

## Phase 1: [Descriptive Name]

### Overview
[What this phase accomplishes]

### Changes Required:

#### 1. [Component/File Group]
**File**: `lib/module.ex`
**Changes**: [Summary of changes]

```elixir
# Specific code to add/modify
```

### Success Criteria:

#### Automated Verification:
- [ ] Tests pass: `mix test`
- [ ] Quality checks pass: `mix quality`
  - Format: `mix format --check-formatted`
  - Compile: `mix compile --warnings-as-errors`
  - Dialyzer: `mix dialyzer`
  - Credo: `mix credo --strict`

#### Manual Verification:
- [ ] Feature works as expected when tested
- [ ] No regressions in related features
- [ ] Edge cases handled correctly

**Note**: Complete all automated verification, then pause for manual confirmation before proceeding to next phase.

---

## Phase 2: [Descriptive Name]
[Similar structure...]

---

## Testing Strategy

### Unit Tests:
- [What to test]
- [Key edge cases]

### Integration Tests:
- [End-to-end scenarios]

### Manual Testing Steps:
1. [Specific step to verify feature]
2. [Another verification step]

## Migration Notes
[If applicable, how to handle existing data/systems]

## References
- Research: `{{item_path}}/research.md`
- [Other relevant files with line references]
```

### 2. PRD - Structured User Stories

Call the `save_prd` MCP tool with the PRD data. The PRD schema:

- `schema_version`: Always 1
- `id`: "{{id}}"
- `branch_name`: "{{branch_name}}"
- `user_stories`: Array of stories, each with:
  - `id`: Story ID like "US-001"
  - `title`: Short descriptive title
  - `acceptance_criteria`: Array of specific, testable criteria
  - `priority`: Number (1 = highest)
  - `status`: "pending" (all new stories start as pending)
  - `notes`: Implementation notes (can be empty string)

## Important Guidelines

1. **Be Skeptical:**
   - Question vague requirements
   - Identify potential issues early
   - Don't assume - verify with code

2. **Be Thorough:**
   - Include specific file paths and line numbers
   - Write measurable success criteria
   - Separate automated vs manual verification

3. **Be Practical:**
   - Focus on incremental, testable changes
   - Consider migration and rollback
   - Think about edge cases
   - Include "what we're NOT doing"

4. **No Open Questions:**
   - If you encounter open questions, research them immediately
   - Do NOT write the plan with unresolved questions
   - Every decision must be made before finalizing

## Story Prioritization

- **Priority 1**: Core functionality, must be done first
- **Priority 2**: Important features that depend on Priority 1
- **Priority 3**: Nice-to-have, can be deferred
- **Priority 4**: Optional enhancements

## Common Patterns (Elixir/Mix)

### For New Modules:
1. Research existing patterns in `lib/`
2. Define behaviour/protocol if applicable
3. Implement module with typespec
4. Add unit tests in `test/`
5. Run `mix test && mix quality`

### For Provider Implementation:
1. Implement `ReqLLM.Provider` behaviour callbacks
2. Add provider-specific encoding/decoding
3. Add fixture-based tests in `test/coverage/`
4. Verify with `mix mc provider:*`

### For Refactoring:
1. Document current behavior with tests
2. Plan incremental changes
3. Maintain backwards compatibility
4. Run `mix dialyzer` to catch type regressions

## Completion

When you have:
1. Created `{{item_path}}/plan.md`
2. Called the `save_prd` tool with the PRD data

Output the following signal:
{{completion_signal}}
