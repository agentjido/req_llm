# Research Phase

You are tasked with conducting comprehensive research for the following item in an **Elixir Mix project**. Be thorough, skeptical, and document your findings with specific file references.

## Prerequisites

Before starting research, verify the codebase is in a healthy state:

```bash
mix test
mix quality  # or: mix format --check-formatted && mix compile --warnings-as-errors && mix dialyzer && mix credo --strict
```

If these fail, note the failures in your research findings - they may be relevant to the task.

## Item Details
- **ID:** {{id}}
- **Title:** {{title}}
- **Section:** {{section}}
- **Overview:** {{overview}}
- **Working Directory:** {{item_path}}

## Research Process

### Step 1: Initial Analysis

1. **Understand the scope:**
   - Break down the task into composable research areas
   - Identify specific components, patterns, or concepts to investigate
   - Consider which directories, files, or architectural patterns are relevant

2. **Read relevant files:**
   - Read files COMPLETELY - do not skim or read partially
   - Start with files directly related to the feature/task
   - Trace dependencies and connections

### Step 2: Deep Investigation

1. **Explore the codebase:**
   - Find all files related to this task
   - Understand how the current implementation works
   - Identify patterns and conventions to follow
   - Look for similar features we can model after

2. **Document what you find:**
   - Include specific file paths and line numbers
   - Note existing patterns and conventions
   - Identify integration points and dependencies
   - Find relevant tests and examples

### Step 3: Synthesize Findings

Compile your research with:
- Concrete file references (file:line format)
- Patterns, connections, and architectural decisions
- Areas that need special attention
- Potential challenges or risks

## Output

Create a file at: `{{item_path}}/research.md`

Use this structure:

```markdown
# Research: {{title}}

**Date**: [Current date]
**Item**: {{id}}

## Research Question
{{overview}}

## Summary
[High-level findings - 2-3 paragraphs answering what needs to be done and how]

## Current State Analysis

### Existing Implementation
- [What exists now with file:line references]
- [Current patterns and conventions]
- [Integration points]

### Key Files
- `lib/module.ex:123` - Description of what's there
- `lib/another/module.ex:45-67` - Description of the code block

## Technical Considerations

### Dependencies
- [External dependencies needed]
- [Internal modules to integrate with]

### Patterns to Follow
- [Existing patterns to maintain consistency]
- [Conventions observed in the codebase]

## Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| [Risk 1] | [High/Medium/Low] | [How to address] |

## Recommended Approach
[High-level strategy based on research findings]

## Open Questions
[Any areas that need clarification before implementation]
```

## Important Guidelines

1. **Be Thorough:**
   - Read all relevant files COMPLETELY
   - Don't assume - verify with actual code
   - Include specific file paths and line numbers

2. **Be Skeptical:**
   - Question assumptions
   - Verify patterns actually exist
   - Look for edge cases

3. **Be Practical:**
   - Focus on actionable findings
   - Note what's in scope vs out of scope
   - Consider migration and backwards compatibility

## Completion

When you have completed the research and created the `{{item_path}}/research.md` file, output the following signal:
{{completion_signal}}
