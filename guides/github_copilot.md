# GitHub Copilot

GitHub Copilot exposes an OpenAI-compatible Chat Completions API at `https://api.githubcopilot.com`. ReqLLM supports it through the `:github_copilot` provider.

## Configuration

Use a GitHub token that has access to Copilot:

```bash
export COPILOT_GITHUB_TOKEN=gho_...
```

By default, `github_copilot_auth` is `:token`. ReqLLM checks these token sources in order:

1. The `:api_key` request option
2. Application config `config :req_llm, :github_copilot_api_key, token`
3. `COPILOT_GITHUB_TOKEN`
4. `GH_TOKEN`
5. `GITHUB_TOKEN`

If none is configured, ReqLLM returns an error. Running `gh auth token` requires an explicit opt-in:

```elixir
ReqLLM.generate_text("github_copilot:gpt-4o-mini", "Hello!", github_copilot_auth: :auto)
```

Use `:auto` to check configured tokens first and then fall back to the GitHub CLI, or `:gh` to use only the GitHub CLI. Both modes execute the `gh` executable found on `PATH`.

You can also pass a token per request:

```elixir
ReqLLM.generate_text("github_copilot:gpt-4o-mini", "Hello!", api_key: token)
```

## Streaming

```elixir
{:ok, response} =
  ReqLLM.stream_text(
    "github_copilot:gpt-4o-mini",
    "Reply with one sentence.",
    max_tokens: 120
  )

response
|> ReqLLM.StreamResponse.tokens()
|> Enum.each(&IO.write/1)
```

## Provider Options

Provider options can be passed either top-level or nested under `:provider_options`.

```elixir
ReqLLM.stream_text(
  "github_copilot:gpt-4o-mini",
  "Hello!",
  provider_options: [
    github_copilot_integration_id: "vscode-chat",
    github_copilot_auth: :token
  ]
)
```

### `github_copilot_integration_id`

- **Type**: String
- **Default**: `"vscode-chat"`
- **Purpose**: Sets the required `Copilot-Integration-Id` request header.

### `github_copilot_auth`

- **Type**: `:auto` | `:token` | `:gh`
- **Default**: `:token`
- **Purpose**: Controls credential lookup.

`:token` only uses configured token sources and returns an error if none is available. Explicitly set `github_copilot_auth: :auto` to check configured tokens first and then fall back to `gh auth token`, or `github_copilot_auth: :gh` to use only the GitHub CLI.

## Model Specs

Copilot model availability is account-dependent. ReqLLM accepts unverified Copilot model IDs:

```elixir
ReqLLM.model!("github_copilot:gpt-4o-mini")
ReqLLM.model!("github_copilot:claude-sonnet-4.5")
```

If you need to use a different Copilot-compatible host, set `base_url`:

```elixir
model =
  ReqLLM.model!(%{
    provider: :github_copilot,
    id: "gpt-4o-mini",
    base_url: "https://api.individual.githubcopilot.com"
  })

ReqLLM.stream_text(model, "Hello!")
```

## Token Exchange 404s

Some community examples call `https://api.github.com/copilot_internal/v2/token` before calling Copilot. That endpoint is internal and can return `404 Not Found` for valid GitHub CLI OAuth tokens or account types.

ReqLLM does not depend on that exchange. It sends the resolved token directly to `https://api.githubcopilot.com` as a bearer token, matching the path used by the successful streaming request.
