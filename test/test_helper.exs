# Ensure providers are loaded for testing
Application.ensure_all_started(:req_llm)

# Install fake API keys for tests when not in LIVE mode
ReqLLM.TestSupport.FakeKeys.install!()

# Logger level is configured via config/config.exs based on REQ_LLM_DEBUG

ExUnit.start(capture_log: true, exclude: [:coverage])
