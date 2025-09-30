defmodule ReqLLM.Coverage.Google.UsageTest do
  use ReqLLM.ProviderTest.Usage, provider: :google, model: "google:gemini-2.5-flash"
end
