defmodule ReqLLM.Coverage.FireworksAI.ComprehensiveTest do
  @moduledoc """
  Comprehensive Fireworks AI feature coverage tests.

  Run with `REQ_LLM_FIXTURES_MODE=record` to test against the live API and
  record fixtures. Otherwise uses cached fixtures for fast, deterministic
  testing.

  Scope is limited via `REQ_LLM_MODELS` when recording — by default the
  comprehensive matrix expands to all 19 Fireworks models, so prefer:

      REQ_LLM_FIXTURES_MODE=record \\
        REQ_LLM_MODELS="fireworks_ai:accounts/fireworks/models/kimi-k2-instruct,fireworks_ai:accounts/fireworks/models/gpt-oss-20b" \\
        mix test --only provider:fireworks_ai
  """

  use ReqLLM.ProviderTest.Comprehensive, provider: :fireworks_ai
end
