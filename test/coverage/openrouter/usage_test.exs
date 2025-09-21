defmodule ReqLLM.Coverage.OpenRouter.UsageTest do
  use ReqLLM.ProviderTest.Usage,
    provider: :openrouter,
    model: "openrouter:meta-llama/llama-3.2-3b-instruct:free"
end
