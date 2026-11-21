defmodule ReqLLM.Coverage.Google.InteractionsTest do
  @moduledoc """
  Google Interactions API and Gemini 4 `:xhigh` thinking coverage tests.

  Run with REQ_LLM_FIXTURES_MODE=record to test against the live API and record fixtures.
  Otherwise uses recorded fixtures for fast, offline replay testing.
  """

  use ExUnit.Case, async: false

  import ReqLLM.Test.Helpers

  alias ReqLLM.Providers.Google.InteractionsAPI
  alias ReqLLM.Response
  alias ReqLLM.StreamResponse
  alias ReqLLM.Test.CompatibilityScenario

  @moduletag :coverage
  @moduletag provider: "google"
  @moduletag model: "gemini-4-hydrogen"
  @moduletag timeout: 180_000

  @model_spec "google:gemini-4-hydrogen"

  @tag CompatibilityScenario.tag!(:interactions_basic)
  test "basic buffered Interactions API generation" do
    {:ok, response} =
      ReqLLM.generate_text(
        @model_spec,
        "Reply with the single word: pong.",
        fixture_opts(
          CompatibilityScenario.fixture!(:interactions_basic),
          google_api: :interactions,
          max_tokens: 256
        )
      )

    assert String.trim(Response.text(response) || "") != ""
    assert is_binary(response.id)
    assert response.provider_meta["interaction_id"] == response.id
    assert response.usage.input_tokens > 0
    assert InteractionsAPI.verified_interactions_steps(response.message) != nil
  end

  @tag CompatibilityScenario.tag!(:interactions_streaming)
  test "streaming Interactions API generation" do
    {:ok, stream_response} =
      ReqLLM.stream_text(
        @model_spec,
        "Count from 1 to 3 separated by spaces.",
        fixture_opts(
          CompatibilityScenario.fixture!(:interactions_streaming),
          google_api: :interactions,
          max_tokens: 256
        )
      )

    assert {:ok, response} = StreamResponse.to_response(stream_response)
    assert String.trim(Response.text(response) || "") != ""
    assert is_binary(response.id)
    assert response.provider_meta["interaction_id"] == response.id
    assert InteractionsAPI.verified_interactions_steps(response.message) != nil
  end

  @tag CompatibilityScenario.tag!(:interactions_xhigh)
  test "Interactions API with :xhigh reasoning effort" do
    {:ok, response} =
      ReqLLM.generate_text(
        @model_spec,
        "What is 17 * 19? Reply with the number only.",
        fixture_opts(
          CompatibilityScenario.fixture!(:interactions_xhigh),
          google_api: :interactions,
          reasoning_effort: :xhigh,
          max_tokens: 4096
        )
      )

    assert Response.text(response) =~ "323"
    assert is_binary(response.id)
    assert response.provider_meta["interaction_id"] == response.id
    assert response.usage.total_tokens > 0
  end
end
