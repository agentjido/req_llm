# Contributing to ReqLLM

Thank you for your interest in ReqLLM. Provider APIs change continuously, and
real applications find combinations and edge cases that provider documentation
does not show. ReqLLM improves when builders bring those cases back to the
project as reports, tests, and patches.

Do not wait for a perfect patch. Small fixes, partial fixes, and agent-assisted
pull requests are welcome. Keep the change focused, explain the observed API
behavior, and be available to answer review questions. Maintainers can help
with structure, style, and cleanup.

For provider behavior changes, the most valuable evidence is a focused test and
a fixture recorded from the real API. The test turns one user's edge case into
coverage that all users can replay without provider credentials.

## Table of Contents

- [Contributing to ReqLLM](#contributing-to-reqllm)
  - [Table of Contents](#table-of-contents)
  - [Core Principles](#core-principles)
  - [Types of Contributions](#types-of-contributions)
    - [Provider Edge Cases](#provider-edge-cases)
    - [Core Library Contributions](#core-library-contributions)
    - [New Provider Contributions](#new-provider-contributions)
    - [Provider Feature Extensions](#provider-feature-extensions)
  - [Development Setup](#development-setup)
  - [Testing Requirements](#testing-requirements)
    - [Running Tests](#running-tests)
    - [Fixture Generation](#fixture-generation)
  - [Pull Request Process](#pull-request-process)
  - [Code Quality Standards](#code-quality-standards)
    - [Formatting](#formatting)
    - [Compilation](#compilation)
    - [Static Analysis](#static-analysis)
    - [Linting](#linting)
    - [Combined Check](#combined-check)
    - [Code Style Conventions](#code-style-conventions)
  - [Questions?](#questions)
  - [License](#license)

## Core Principles

ReqLLM uses these principles:

1. **Fast, Tested Fixes**: A focused patch is better than a workaround that
   stays in one application. Add a regression test that shows the failure and
   the fix.
2. **Real API Evidence**: When a change depends on provider behavior, record the
   smallest live API fixture that proves it. If you cannot access the model or
   feature, state that clearly and include a sanitized reproduction.
3. **Replayable Reliability**: Committed fixtures let the test suite reproduce
   real provider responses without credentials or repeated API cost.
4. **Focused Quality**: Run the tests for the changed behavior and run
   `mix quality`. Run broad model checks when the change has broad effects.

Never include API keys, private prompts, or other sensitive data in a fixture.

## Types of Contributions

### Provider Edge Cases

Provider APIs can change after a fixture is recorded. If you find an edge case,
open an issue or a pull request and include:

- The provider, model, and operation
- A minimal request or reproduction
- The expected and observed behavior
- A sanitized response or error when it helps explain the problem

A pull request that changes provider behavior must include a focused regression
test. Record a live fixture when provider access permits. See the
[Fixture Testing Guide](guides/fixture-testing.md) for focused record and replay
commands.

### Core Library Contributions

Core library contributions modify the foundational components of ReqLLM including:

- Core modules (`ReqLLM`, `LLMDB.Model`, `ReqLLM.Provider`, etc.)
- Data structures (`Context`, `Message`, `StreamChunk`, `Response`, etc.)
- Shared utilities and helpers
- Provider behavior and DSL
- Testing infrastructure

**Requirements:**

✅ **All existing tests must pass**
```bash
mix test
```

✅ **All model compatibility tests must pass**
```bash
mix mc "*:*"
```

✅ **All quality checks must pass**
```bash
mix quality
# Runs: format check, compile with warnings as errors, dialyzer, credo --strict
```

✅ **New functionality requires comprehensive tests**
- Unit tests for new modules/functions
- Integration tests with fixtures where appropriate
- Coverage tests if new API behavior is introduced

✅ **Documentation must be updated**
- Add `@moduledoc` and `@doc` annotations
- Update relevant guides in `guides/`
- Add examples to README if introducing user-facing features

**Pull Request Checklist:**
- [ ] All existing tests pass (`mix test`)
- [ ] All model compatibility tests pass (`mix mc "*:*"`)
- [ ] Quality checks pass (`mix quality`)
- [ ] New tests added for new functionality
- [ ] Documentation updated

### New Provider Contributions

Adding a new LLM provider requires implementing the `ReqLLM.Provider` behavior and ensuring comprehensive model coverage.

**Requirements:**

✅ **Provider implementation complete**
- Implement all required callbacks in `lib/req_llm/providers/your_provider.ex`
- Use `ReqLLM.Provider.DSL` for provider registration
- Follow existing provider patterns (see [Adding a Provider Guide](guides/adding_a_provider.md))

✅ **Model metadata configured**
- Model metadata provided by the `llm_db` dependency (no manual sync needed)
- All models have proper metadata (capabilities, cost, context length, etc.)

✅ **Fixtures generated for all supported models**
```bash
# Generate fixtures for all provider models
mix mc "your_provider:*" --record
```

✅ **Model compatibility tests pass**
```bash
# Verify all models pass
mix mc "your_provider:*"
```

The output should show all models with ✓ status. This is **mandatory** before PR submission.

✅ **Provider-specific tests added**
- Add tests in `test/provider/your_provider_test.exs`
- Use mocked responses (no live API calls in provider tests)
- Cover edge cases, error handling, and provider-specific features

✅ **Quality checks pass**
```bash
mix quality
```

**Pull Request Checklist:**
- [ ] Provider module implemented with all callbacks
- [ ] Model metadata synced and present
- [ ] Fixtures generated for all models (`mix mc "your_provider:*" --record`)
- [ ] All model compatibility tests pass (`mix mc "your_provider:*"`)
- [ ] Provider-specific tests added with mocks
- [ ] Quality checks pass (`mix quality`)
- [ ] Documentation added (provider-specific guide if needed)
- [ ] README updated with provider in supported list

**Note:** The responsibility is on the PR author to generate fixtures locally. Reviewers will verify by running `mix mc "your_provider:*"` and expect all models to pass.

### Provider Feature Extensions

Adding new features to existing providers (e.g., file uploads, PDF support, image inputs, text-to-speech, vision capabilities).

**Requirements:**

✅ **Feature implementation complete**
- Modify provider module to support new feature
- Update encoding/decoding logic as needed
- Add parameter validation and options

✅ **Fixtures generated for new feature**
```bash
# Generate fixtures for affected models
LIVE=true mix test --only "provider:your_provider" --only "category:relevant_category"

# Or regenerate specific model fixtures
mix mc "your_provider:specific-model" --record
```

✅ **Tests cover new feature**
- Add coverage tests in `test/coverage/` for high-level API
- Add provider tests in `test/provider/` with mocked responses
- Ensure fixtures demonstrate the new capability

✅ **Model compatibility maintained**
```bash
# Verify affected models still pass
mix mc "your_provider:*"
```

✅ **Quality checks pass**
```bash
mix quality
```

**Pull Request Checklist:**
- [ ] Feature implemented in provider module
- [ ] Fixtures generated for new feature
- [ ] Tests added covering new functionality
- [ ] All model compatibility tests pass for affected provider
- [ ] Quality checks pass (`mix quality`)
- [ ] Documentation updated (API reference, provider guide)
- [ ] Example usage added to README or guides

## Development Setup

```bash
# Clone the repository
git clone https://github.com/agentjido/req_llm.git
cd req_llm

# Install dependencies
mix deps.get

# Set up API keys (copy and configure)
cp .env.example .env
# Edit .env with your API keys

# Install git hooks (recommended)
mix git_hooks.install

# Verify setup
mix test
mix quality
```

### Git Hooks

We use the [`git_hooks`](https://hex.pm/packages/git_hooks) package to manage git hooks in an Elixir-idiomatic way:

```bash
mix git_hooks.install
```

This installs a pre-push hook that runs `mix format --check-formatted` before each push.

This is important because Elixir 1.18 and 1.19 format some code differently (particularly guard clauses), and CI tests against multiple Elixir versions. The hook ensures your code is formatted correctly before pushing, preventing CI failures.

## Testing Requirements

ReqLLM uses a three-tier testing architecture:

1. **Core Package Tests** (`test/req_llm/`): Unit tests with no API calls
2. **Provider Tests** (`test/provider/`): Mocked provider-specific tests
3. **Coverage Tests** (`test/coverage/`): Live API tests with fixture caching

### Running Tests

```bash
# Run all tests with cached fixtures
mix test

# Run tests against live APIs (regenerate fixtures)
LIVE=true mix test

# Run specific provider tests
mix test --only "provider:anthropic"

# Run specific category tests
mix test --only "category:core"

# Run model compatibility checks
mix mc                          # Show fixture status for all models
mix mc "*:*"                    # Run tests for all models
mix mc "anthropic:*"           # Run tests for all Anthropic models
mix mc "openai:gpt-4o"         # Run tests for specific model
mix mc --sample                # Run tests for sample subset
```

### Fixture Generation

Fixtures are the backbone of ReqLLM's reliability:

- **Cached by default**: Tests run against cached JSON fixtures
- **Generated with LIVE=true**: Set `LIVE=true` to hit real APIs and regenerate fixtures
- **Stored alongside tests**: Fixtures live in `test/.../fixtures/provider/test_name.json`
- **Required for all new features**: Every new capability must have fixture coverage
- **Focused for bug fixes**: Start with the affected model and scenario to limit cost and unrelated fixture changes

```bash
# Generate fixtures for a new test
LIVE=true mix test test/coverage/your_new_test.exs

# Regenerate all fixtures for a provider
mix mc "provider:*" --record

# Regenerate fixtures for a specific model
mix mc "provider:specific-model" --record
```

## Pull Request Process

1. **Fork and Branch**
   ```bash
   git checkout -b feature/your-feature-name
   ```

2. **Develop with Tests**
   - Add a test that reproduces the reported edge case
   - Include the exact provider, model, and scenario when relevant
   - Ensure the test passes with the recorded fixture
   - Run quality checks frequently

3. **Generate/Update Fixtures**
   ```bash
   # For new features
   LIVE=true mix test test/path/to/your_test.exs

   # For new providers
   mix mc "your_provider:*" --record
   ```

4. **Verify Everything Passes**
   ```bash
   mix test                    # All tests
   mix mc "*:*"                # Model compatibility (or specific provider pattern)
   mix quality                 # Code quality
   ```

5. **Update Documentation**
   - Add/update module docs
   - Update guides if needed
   - Do **NOT** edit `CHANGELOG.md` (see below)

6. **Submit Pull Request**
   - Use descriptive title
   - Reference related issues
   - Describe the observed and expected API behavior
   - Include checklist from relevant contribution type above
   - Include output from the focused test or model compatibility command

7. **Review Process**
   - Maintainer will run `mix mc "*:*"` (or provider-specific) to verify fixtures
   - Maintainer will review code quality and tests
   - Address feedback and update PR

## Changelog

**Do NOT edit `CHANGELOG.md`** — it is auto-generated by `git_ops` during releases.

Your changes will appear in the changelog automatically based on your commit messages:
- `feat:` commits create "Added" entries
- `fix:` commits create "Fixed" entries  
- `docs:`, `chore:`, `ci:` commits are excluded

To ensure your change is documented correctly, use [Conventional Commits](https://www.conventionalcommits.org/) format with clear, descriptive messages.

## Code Quality Standards

All contributions must meet these standards:

### Formatting
```bash
mix format
mix format --check-formatted  # In CI
```

### Compilation
```bash
mix compile --warnings-as-errors
```

### Static Analysis
```bash
mix dialyzer
```

### Linting
```bash
mix credo --strict
```

### Combined Check
```bash
mix quality  # Runs all of the above
```

GitHub CI uses the same `mix quality` alias for linting, so the local command and the PR quality gate stay aligned.

### Code Style Conventions

- **No inline comments in function bodies**: Code should be self-documenting through clear naming and structure
- **Use `@moduledoc` and `@doc`**: All public modules and functions must have documentation
- **Zoi for data structures**: Use Zoi schemas with `@schema` definitions for validation
- **Splode for errors**: Return `{:ok, result}` or `{:error, %ReqLLM.Error{}}` tuples
- **NimbleOptions for validation**: Validate public API options with schemas
- **Pattern matching over conditionals**: Prefer pattern matching when possible
- **Explicit module calls**: Minimize imports, prefer `Module.function()` style

See the project root AGENTS.md file for complete style guide and architecture details.

## Questions?

- **Documentation**: Check the guides/ directory for detailed implementation guides
- **Issues**: Open an issue for questions or bug reports
- **Discussions**: Use GitHub Discussions for general questions
- **Examples**: Look at existing providers for implementation patterns

## License

By contributing to ReqLLM, you agree that your contributions will be licensed under the Apache License 2.0.

---

Thank you for helping make ReqLLM better! Your contributions make this library more reliable, feature-rich, and valuable for the Elixir community.
