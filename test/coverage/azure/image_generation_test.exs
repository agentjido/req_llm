defmodule ReqLLM.Coverage.Azure.ImageGenerationTest do
  @moduledoc """
  Azure OpenAI image generation coverage tests.

  Run with REQ_LLM_FIXTURES_MODE=record to test against live API and record fixtures.

  ## Azure-Specific Requirements

  Set AZURE_OPENAI_API_KEY and AZURE_OPENAI_BASE_URL when recording (and for
  replay, since request preparation still resolves and validates the base URL).
  The Azure resource must have a deployment named exactly like the model id
  (e.g. "gpt-image-2"), or set AZURE_IMAGE_DEPLOYMENT to override.

  Either endpoint format works for every gpt-image model; the committed fixture
  was recorded against the v1 GA base URL:

      AZURE_OPENAI_BASE_URL=https://<resource>.openai.azure.com/openai/v1 \\
        REQ_LLM_FIXTURES_MODE=record mix test test/coverage/azure/image_generation_test.exs --include coverage
  """

  use ReqLLM.ProviderTest.ImageGeneration, provider: :azure
end
