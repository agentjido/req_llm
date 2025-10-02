# Ensure providers are loaded for testing
Application.ensure_all_started(:req_llm)

# Install fake API keys for tests when not in LIVE mode
ReqLLM.TestSupport.FakeKeys.install!()

# Configure Logger level based on REQ_LLM_DEBUG env var
if System.get_env("REQ_LLM_DEBUG") in ["1", "true"] do
  Logger.configure(level: :debug)
else
  Logger.configure(level: :warning)
end

ExUnit.start(capture_log: true, exclude: [:coverage])
