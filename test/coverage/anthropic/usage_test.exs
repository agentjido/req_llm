defmodule ReqLLM.Coverage.Anthropic.UsageTest do
  use ReqLLM.ProviderTest.Usage,
    provider: :anthropic,
    model: "anthropic:claude-3-5-haiku-20241022"
end
