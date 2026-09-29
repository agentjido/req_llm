defmodule ReqLLM.Coverage.Azure.ResponsesContextTest do
  @moduledoc """
  Azure OpenAI Responses API reasoning-summary, reasoning-context and compaction coverage.

  Run with REQ_LLM_FIXTURES_MODE=record to test against the live API and record fixtures.

  ## Azure-Specific Requirements

  Set AZURE_OPENAI_API_KEY and AZURE_OPENAI_BASE_URL when recording. Replay uses
  non-network fixture credentials supplied by the shared coverage helper. The
  Azure resource must have a deployment named exactly like the model id (e.g.
  "gpt-5.4"), or set AZURE_RESPONSES_DEPLOYMENT to override. Set
  REQ_LLM_RESPONSES_MODEL to record against another catalog model.

  Record against the v1 GA base URL (`.../openai/v1`): the legacy base URL
  (`.../openai` with `api_version`) serves `/responses` but returns a server
  error for `/responses/compact`. Replay expects the v1 GA URL shape:

      AZURE_OPENAI_BASE_URL=https://<resource>.openai.azure.com/openai/v1 \\
        REQ_LLM_FIXTURES_MODE=record mix test test/coverage/azure/responses_context_test.exs --include coverage
  """

  use ReqLLM.ProviderTest.ResponsesContext, provider: :azure
end
