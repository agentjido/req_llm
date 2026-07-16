defmodule ReqLLM.Coverage.OpenAI.LogprobsTest do
  @moduledoc """
  OpenAI logprobs feature coverage tests.

  Validates that logprobs requested via openai_logprobs: true are returned
  in response.provider_meta.logprobs as a list of per-token maps.

  Run with REQ_LLM_FIXTURES_MODE=record to test against live API and record fixtures.
  Otherwise uses fixtures for fast, reliable testing.
  """

  use ExUnit.Case, async: false

  import ReqLLM.Test.Helpers

  @moduletag :coverage
  @moduletag provider: "openai"
  @moduletag timeout: 60_000

  @model_spec "openai:gpt-3.5-turbo"

  setup_all do
    LLMDB.load(allow: :all, custom: %{})
    :ok
  end

  @tag ReqLLM.Test.CompatibilityScenario.tag!(:logprobs_non_streaming)
  @tag model: "gpt-3.5-turbo"
  test "logprobs are returned in provider_meta when requested" do
    opts =
      fixture_opts(ReqLLM.Test.CompatibilityScenario.fixture!(:logprobs_non_streaming),
        provider_options: [openai_logprobs: true]
      )

    {:ok, response} = ReqLLM.generate_text(@model_spec, "test prompt", opts)

    logprobs = response.provider_meta[:logprobs]

    assert is_list(logprobs), "expected logprobs to be a list, got: #{inspect(logprobs)}"
    assert logprobs != []

    Enum.each(logprobs, fn entry ->
      assert is_map(entry)
      assert is_binary(entry["token"])
      assert is_number(entry["logprob"])
      assert entry["logprob"] <= 0.0
    end)
  end

  @tag ReqLLM.Test.CompatibilityScenario.tag!(:basic)
  @tag model: "gpt-3.5-turbo"
  test "logprobs are absent from provider_meta when not requested" do
    opts = fixture_opts(ReqLLM.Test.CompatibilityScenario.fixture!(:basic))

    {:ok, response} = ReqLLM.generate_text(@model_spec, "Hello world!", opts)

    refute Map.has_key?(response.provider_meta, :logprobs)
  end
end
