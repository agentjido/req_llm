defmodule ReqLLM.Coverage.Google.UsageTest do
  use ReqLLM.ProviderTest.Usage, provider: :google, model: "google:gemini-1.5-flash"
end
