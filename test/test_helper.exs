# Ensure LLMDB is started first (loads model catalog from snapshot)
Application.ensure_all_started(:llm_db)

# Reload LLMDB with custom test models merged with snapshot
custom_providers = Application.get_env(:llm_db, :custom, %{})
LLMDB.load(custom: custom_providers)

# Ensure providers are loaded for testing
Application.ensure_all_started(:req_llm)

# Install fake API keys for tests when not in LIVE mode
ReqLLM.TestSupport.FakeKeys.install!()

# Logger level is configured via config/config.exs based on REQ_LLM_DEBUG

# Exclude :coverage and :integration by default
# Run integration tests with: mix test --include integration
ExUnit.start(capture_log: true, exclude: [:coverage, :integration])
