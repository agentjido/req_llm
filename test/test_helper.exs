# Ensure providers are loaded for testing
Application.ensure_all_started(:req_llm)

# Load HTTP mock helper
Code.require_file("support/http_mock.ex", __DIR__)

# Setup global HTTP mock
ReqLLM.Test.HTTPMock.setup_global_mock()

ExUnit.start(capture_log: true, exclude: [:coverage])
