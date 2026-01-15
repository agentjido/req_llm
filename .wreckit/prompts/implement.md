# Implementation Phase

## Task
Implement the user stories for this item in an **Elixir Mix project**.

## Prerequisites

Before starting implementation, verify the codebase is in a healthy state:

```bash
mix test
mix quality  # or: mix format --check-formatted && mix compile --warnings-as-errors && mix dialyzer && mix credo --strict
```

If these fail, fix them before proceeding with new changes.

## Item Details
- **ID:** {{id}}
- **Title:** {{title}}
- **Section:** {{section}}
- **Overview:** {{overview}}
- **Branch:** {{branch_name}}
- **Base Branch:** {{base_branch}}

## Research
{{research}}

## Implementation Plan
{{plan}}

## User Stories (PRD)
{{prd}}

## Progress Log
{{progress}}

## Instructions
1. Pick the highest priority pending story from the PRD
2. Implement the story following the plan
3. Ensure all acceptance criteria are met
4. Run tests and quality checks:
   ```bash
   mix test
   mix quality  # format, compile --warnings-as-errors, dialyzer, credo
   ```
5. Fix any failures before proceeding
6. Commit changes with a descriptive message
7. Call the `update_story_status` tool with the story ID and status "done"
8. Append learnings/notes to {{item_path}}/progress.log
9. Repeat for remaining stories

## Working Directory
{{item_path}}

## Completion
When ALL stories have status "done", output the following signal:
{{completion_signal}}
