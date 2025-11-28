defmodule ReqLLM.Coverage.Google.GroundingTest do
  @moduledoc """
  Google grounding (Google Search) feature coverage tests.

  Tests the Google-specific grounding capability that allows Gemini models
  to search the web during generation using the built-in google_search tool.

  Run with REQ_LLM_FIXTURES_MODE=record to test against live API and record fixtures.
  Otherwise uses fixtures for fast, reliable testing.
  """

  use ExUnit.Case, async: false

  import ReqLLM.Context
  import ReqLLM.Test.Helpers

  alias ReqLLM.Test.ModelMatrix

  @moduletag :coverage
  @moduletag provider: "google"
  @moduletag timeout: 180_000

  @provider :google
  @models ModelMatrix.models_for_provider(@provider, operation: :text)

  setup_all do
    LLMDB.load(allow: :all, custom: %{})
    :ok
  end

  for model_spec <- @models do
    @model_spec model_spec

    describe "#{model_spec}" do
      @describetag model: model_spec |> String.split(":", parts: 2) |> List.last()

      @tag scenario: :grounding_basic
      test "grounding with enable: true" do
        opts =
          fixture_opts("grounding_basic",
            provider_options: [
              google_api_version: "v1beta",
              google_grounding: %{enable: true}
            ]
          )

        {:ok, response} =
          ReqLLM.generate_text(
            @model_spec,
            "What are the top 3 news headlines today?",
            opts
          )

        assert response.message != nil
        assert ReqLLM.Response.text(response) != ""

        grounding_data = get_in(response.provider_meta, ["google", "grounding_metadata"])
        sources = get_in(response.provider_meta, ["google", "sources"])

        if grounding_data do
          assert is_map(grounding_data)
          assert is_list(sources)

          if not Enum.empty?(sources) do
            source = List.first(sources)
            assert is_binary(source["uri"])
          end
        end
      end

      @tag scenario: :grounding_with_context
      test "grounding with conversation context" do
        opts =
          fixture_opts("grounding_context",
            provider_options: [
              google_api_version: "v1beta",
              google_grounding: %{enable: true}
            ]
          )

        context =
          new([
            user("I'm planning a trip to Paris"),
            assistant("That sounds wonderful! Paris is a beautiful city."),
            user("What's the weather like there right now?")
          ])

        {:ok, response} = ReqLLM.generate_text(@model_spec, context, opts)

        assert response.message != nil
        assert ReqLLM.Response.text(response) != ""

        grounding_data = get_in(response.provider_meta, ["google", "grounding_metadata"])

        if grounding_data do
          assert is_map(grounding_data)
        end
      end

      @tag scenario: :grounding_streaming
      test "grounding with streaming" do
        opts =
          fixture_opts("grounding_streaming",
            stream: true,
            provider_options: [
              google_api_version: "v1beta",
              google_grounding: %{enable: true}
            ]
          )

        {:ok, stream_response} =
          ReqLLM.stream_text(
            @model_spec,
            "What major tech announcements happened this week?",
            opts
          )

        assert stream_response.stream != nil

        {:ok, response} = ReqLLM.StreamResponse.to_response(stream_response)

        assert response.message != nil
        assert ReqLLM.Response.text(response) != ""

        grounding_data = get_in(response.provider_meta, ["google", "grounding_metadata"])

        if grounding_data do
          assert is_map(grounding_data)
        end
      end

      if String.contains?(@model_spec, "gemini-1.5") do
        @tag scenario: :grounding_legacy
        test "grounding with legacy dynamic_retrieval (Gemini 1.5)" do
          opts =
            fixture_opts("grounding_legacy",
              provider_options: [
                google_api_version: "v1beta",
                google_grounding: %{
                  dynamic_retrieval: %{
                    mode: "MODE_DYNAMIC",
                    dynamic_threshold: 0.7
                  }
                }
              ]
            )

          {:ok, response} =
            ReqLLM.generate_text(
              @model_spec,
              "What is the latest development in AI research?",
              opts
            )

          assert response.message != nil
          assert ReqLLM.Response.text(response) != ""

          grounding_data = get_in(response.provider_meta, ["google", "grounding_metadata"])

          if grounding_data do
            assert is_map(grounding_data)
          end
        end
      end
    end
  end
end
