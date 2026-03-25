---
name: pr-review
description: Review a Pull Request for code quality, tests, and merge readiness. Use when reviewing PRs, checking for merge conflicts, or providing feedback before merging.
---

# PR Review

Review this Pull Request: <url>

This skill is for review-only work. Prefer `gh pr checkout <number> --detach` so disposable local branches do not accumulate.

Analyze the quality of the code, the tests and the overall change. Check for merge conflicts with `main`, advise on fixes if a conflict exists.

Prioritize findings:

1. Correctness bugs and behavior regressions
2. Missing or weak regression coverage for the changed behavior
3. Merge conflicts or dirty merge state against `main`
4. Failing or missing GitHub CI context

When the review is complete, update the PR review-state label on GitHub:

- Apply `ready_to_merge` and remove `needs_work` when there are no blocking findings, the PR is merge-clean, and GitHub CI is green
- Apply `needs_work` and remove `ready_to_merge` when blocking findings remain, coverage is insufficient for the risk, merge conflicts exist, or GitHub CI is failing

Use:

```bash
gh pr edit <number> --add-label ready_to_merge --remove-label needs_work
gh pr edit <number> --add-label needs_work --remove-label ready_to_merge
```

Give me feedback on the PR and whether it is ready to merge.

If asked to give feedback on the PR, do so with a terse response in a encouraging, warm and friendly tone. Be appreciative of the work and the effort put into the PR.
