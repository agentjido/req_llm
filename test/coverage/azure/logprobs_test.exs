defmodule ReqLLM.Coverage.Azure.LogprobsTest do
  @moduledoc """
  Azure OpenAI Chat Completions logprobs coverage.

  Set `REQ_LLM_INCLUDE_COVERAGE=1` to run the test and
  `REQ_LLM_FIXTURES_MODE=record` to call Azure and record the fixture.
  Set `AZURE_LOGPROBS_DEPLOYMENT` when the deployment name differs from
  the model ID and `AZURE_LOGPROBS_API_VERSION` when Azure requires a
  different API version.
  """

  use ExUnit.Case, async: false

  import ReqLLM.Test.Helpers

  @moduletag :coverage
  @moduletag provider: "azure"
  @moduletag timeout: 60_000

  @fixture_api_version "2025-03-01-preview"
  @fixture_base_url "https://fixture.openai.azure.com/openai"
  @model_spec %{provider: :azure, id: "gpt-4o"}

  setup_all do
    LLMDB.load(allow: :all, custom: %{})
    :ok
  end

  @tag ReqLLM.Test.CompatibilityScenario.tag!(:logprobs_non_streaming)
  @tag model: "gpt-4o"
  test "returns requested logprobs in provider metadata" do
    opts =
      fixture_opts(
        ReqLLM.Test.CompatibilityScenario.fixture!(:logprobs_non_streaming),
        azure_options() ++
          [
            max_tokens: 3,
            provider_options: [openai_logprobs: true, openai_top_logprobs: 3]
          ]
      )

    {:ok, response} = ReqLLM.generate_text(@model_spec, "Reply with one word.", opts)

    logprobs = response.provider_meta[:logprobs]
    assert [_ | _] = logprobs
    Enum.each(logprobs, &assert_logprob_entry/1)
  end

  defp assert_logprob_entry(entry) do
    assert_logprob_candidate(entry)
    assert [_ | _] = entry["top_logprobs"]
    Enum.each(entry["top_logprobs"], &assert_logprob_candidate/1)
  end

  defp assert_logprob_candidate(candidate) do
    assert is_binary(candidate["token"])
    assert is_number(candidate["logprob"])
    assert candidate["logprob"] <= 0.0
  end

  defp azure_options do
    case ReqLLM.Test.Env.fixtures_mode() do
      :record ->
        [deployment: System.get_env("AZURE_LOGPROBS_DEPLOYMENT", "gpt-4o")] ++
          case System.get_env("AZURE_LOGPROBS_API_VERSION") do
            nil -> []
            version -> [api_version: version]
          end

      :replay ->
        [
          api_version: @fixture_api_version,
          base_url: @fixture_base_url,
          deployment: "gpt-4o"
        ]
    end
  end
end
