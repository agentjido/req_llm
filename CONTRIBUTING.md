# Contributing to ReqLLM

Thank you for your interest in contributing to ReqLLM! This guide outlines the expectations and requirements for different types of contributions.

## Table of Contents

- [Contributing to ReqLLM](#contributing-to-reqllm)
  - [Table of Contents](#table-of-contents)
  - [Core Principles](#core-principles)
  - [Types of Contributions](#types-of-contributions)
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

ReqLLM is built on two foundational commitments:

1. **Fixture-Based Reliability**: All functionality must be validated against cached fixtures. This ensures reproducible tests without hitting live APIs and maintains reliability across provider changes.
2. **Quality Over Speed**: Code must pass all quality checks (formatting, compilation, dialyzer, credo) before review.

These principles keep the project maintainable and the maintainers sane.

## Types of Contributions

### Core Library Contributions

Core library contributions modify the foundational components of ReqLLM including:

- Core modules (`ReqLLM`, `ReqLLM.Model`, `ReqLLM.Provider`, etc.)
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
- [ ] CHANGELOG.md updated with changes

### New Provider Contributions

Adding a new LLM provider requires implementing the `ReqLLM.Provider` behavior and ensuring comprehensive model coverage.

**Requirements:**

✅ **Provider implementation complete**
- Implement all required callbacks in `lib/req_llm/providers/your_provider.ex`
- Use `ReqLLM.Provider.DSL` for provider registration
- Follow existing provider patterns (see [Adding a Provider Guide](guides/adding_a_provider.md))

✅ **Model metadata configured**
- Provider registry in `priv/models_dev/your_provider.json` (synced via `mix req_llm.model_sync`)
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
- [ ] CHANGELOG.md updated

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
- [ ] CHANGELOG.md updated

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
   - Write tests first (TDD encouraged)
   - Ensure tests pass with fixtures
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
   - Add CHANGELOG entry

6. **Submit Pull Request**
   - Use descriptive title
   - Reference related issues
   - Include checklist from relevant contribution type above
   - **Include output of `mix mc "*:*"` (or provider-specific pattern) showing passing models**

7. **Review Process**
   - Maintainer will run `mix mc "*:*"` (or provider-specific) to verify fixtures
   - Maintainer will review code quality and tests
   - Address feedback and update PR

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

### Code Style Conventions

- **No inline comments in function bodies**: Code should be self-documenting through clear naming and structure
- **Use `@moduledoc` and `@doc`**: All public modules and functions must have documentation
- **TypedStruct for data structures**: Use TypedStruct with `@type` definitions
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
