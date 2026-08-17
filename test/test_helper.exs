# Ensure ReqLLM and its regular OTP dependencies are started
Application.ensure_all_started(:req_llm)

# Reload LLMDB with custom test models merged with snapshot
custom_providers = Application.get_env(:llm_db, :custom, %{})
LLMDB.load(custom: custom_providers)

# Install fake API keys for tests when not in LIVE mode
ReqLLM.TestSupport.FakeKeys.install!()

# Logger level is configured via config/config.exs based on REQ_LLM_DEBUG

# Exclude :coverage and :integration by default
# Run integration tests with: mix test --include integration
excluded_tags =
  if System.get_env("REQ_LLM_INCLUDE_COVERAGE") in ~w(1 true yes on) do
    [:integration]
  else
    [:coverage, :integration]
  end

ExUnit.start(capture_log: true, exclude: excluded_tags)
