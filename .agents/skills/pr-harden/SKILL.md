---
name: pr-harden
description: Take a pull request labeled needs_work, address blocking review findings, strengthen test coverage, rerun validation, and flip it to ready_to_merge when it is clean.
---

# PR Harden

Use this skill when a PR is labeled `needs_work` and the goal is to make the PR merge-ready.

Review target: <url>

## Goal

Turn a `needs_work` PR into a `ready_to_merge` PR by fixing the blocking issues directly on the PR branch.

## Workflow

1. Start from a clean, current `main`
   - `git status --short --branch`
   - `git fetch --prune origin`
   - `git checkout main`
   - `git pull --ff-only origin main`

2. Inspect the PR before changing code
   - Read the PR description, files, current checks, merge state, comments, and reviews
   - Identify the blocking issues first: correctness, regressions, missing tests, red CI, merge conflicts
   - Use the existing review labels as truth: this skill is for PRs labeled `needs_work`

3. Check out the PR branch for editing
   - Use `gh pr checkout <number>` because this skill needs to commit back to the PR branch
   - If the PR comes from a fork, make sure the checkout leaves you on a writable branch before editing

4. Fix the PR, not `main`
   - Address all blocking findings directly on the PR branch
   - Keep the fix scoped to the PR’s goal unless a small follow-up is required to make the branch safe
   - Add or strengthen focused regression tests for each blocking bug or risky edge case you fix
   - Improve test quality, not just test count

5. Validate aggressively
   - Run the smallest focused test slice that proves each fix
   - Run any provider- or capability-specific suites touched by the change
   - Run `mix quality` unless the PR is strictly docs-only
   - If GitHub CI was failing, make sure local validation covers the failing area before pushing

6. Push the updated PR branch
   - Commit only the PR-branch fixes
   - Push back to the PR branch, not `main`

7. Update the review-state label
   - If blockers remain, keep or apply `needs_work` and remove `ready_to_merge`
   - If the PR is now merge-clean, blocking findings are resolved, and CI is green, apply `ready_to_merge` and remove `needs_work`

Use:

```bash
gh pr edit <number> --add-label needs_work --remove-label ready_to_merge
gh pr edit <number> --add-label ready_to_merge --remove-label needs_work
```

## Review Standard

A PR is only `ready_to_merge` when all of these are true:

- No known correctness bugs or regressions remain
- Test coverage is adequate for the risk of the change
- GitHub CI is green
- The PR merges cleanly with `main`
- No unresolved blocking review comments remain

## Output

Report:

- what blocking issues were fixed
- what tests were added or strengthened
- what validation ran
- whether the PR was relabeled to `ready_to_merge` or remains `needs_work`

Do not merge the PR as part of this skill.
