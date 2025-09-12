# GitHub Actions CI

This repository includes a GitHub Actions CI workflow that automatically runs tests and quality checks on every push to the main branch and on all pull requests.

## What the CI does

The CI workflow (`ci.yml`) performs the following checks:

1. **Multi-version testing**: Tests against Elixir 1.18.0/OTP 27.0 and Elixir 1.17.3/OTP 26.2
2. **Quality checks** (on latest version only):
   - Code formatting check (`mix format --check-formatted`)
   - Static analysis with Credo (`mix credo --strict`) 
   - Type checking with Dialyzer (`mix dialyzer`)
3. **Compilation**: Ensures code compiles without warnings (`mix compile --warnings-as-errors`)
4. **Tests**: Runs the full test suite (`mix test`)

## Test fixtures

The CI is configured to use cached test fixtures (`LIVE=false`) rather than making live API calls. This ensures:
- Fast, reliable test execution
- No dependency on external API availability
- No need for API keys in CI

## Caching

The workflow includes intelligent caching for:
- Dependencies (`_build`, `deps`)
- Dialyzer PLT files for faster type checking

## Local development

To run the same checks locally:

```bash
# Install dependencies
mix deps.get

# Run quality checks (matches CI)
mix quality

# Run tests with fixtures (matches CI)
mix test

# Run tests against live APIs (requires API keys)
LIVE=true mix test
```