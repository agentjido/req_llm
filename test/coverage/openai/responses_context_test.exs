defmodule ReqLLM.Coverage.OpenAI.ResponsesContextTest do
  @moduledoc """
  OpenAI Responses API reasoning-summary, reasoning-context and compaction coverage.

  Run with REQ_LLM_FIXTURES_MODE=record and OPENAI_API_KEY to record fixtures:

      REQ_LLM_FIXTURES_MODE=record mix test test/coverage/openai/responses_context_test.exs --include coverage
  """

  use ReqLLM.ProviderTest.ResponsesContext, provider: :openai
end
