defmodule ReqLLM.Coverage.GitHubCopilot.ComprehensiveTest do
  @moduledoc """
  Comprehensive GitHub Copilot API feature coverage tests.

  Run with `REQ_LLM_FIXTURES_MODE=record` to test against the live API and
  record fixtures. Otherwise uses cached fixtures for deterministic validation.

  Scope recording to one inexpensive chat model:

      mix mc "github_copilot:gpt-4.1" --scenario basic --record
  """

  use ReqLLM.ProviderTest.Comprehensive, provider: :github_copilot
end
