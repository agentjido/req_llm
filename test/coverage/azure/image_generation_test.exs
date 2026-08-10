defmodule ReqLLM.Coverage.Azure.ImageGenerationTest do
  @moduledoc """
  Azure OpenAI image generation coverage tests.

  Run with REQ_LLM_FIXTURES_MODE=record to test against live API and record fixtures.

  ## Azure-Specific Requirements

  Set AZURE_OPENAI_API_KEY and AZURE_OPENAI_BASE_URL when recording (and for
  replay, since request preparation still resolves and validates the base URL).
  The shared harness passes no :deployment option, so the Azure resource must
  have a deployment named exactly like the model id (e.g. "gpt-image-1").
  """

  use ReqLLM.ProviderTest.ImageGeneration, provider: :azure
end
