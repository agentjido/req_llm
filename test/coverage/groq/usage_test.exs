defmodule ReqLLM.Coverage.Groq.UsageTest do
  use ReqLLM.ProviderTest.Usage, provider: :groq, model: "groq:llama-3.1-8b-instant"
end
