# Ensure ReqLLM and its regular OTP dependencies are started
Application.ensure_all_started(:req_llm)

# Reload LLMDB with custom test models merged with snapshot
custom_providers = Application.get_env(:llm_db, :custom, %{})
LLMDB.load(custom: custom_providers)

# Install fake API keys for tests when not in LIVE mode
ReqLLM.TestSupport.FakeKeys.install!()

# Logger level is configured via config/config.exs based on REQ_LLM_DEBUG

# Run all offline tests by default. Integration tests require live services.
ExUnit.start(capture_log: true, exclude: [:integration])
