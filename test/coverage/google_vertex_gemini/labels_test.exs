defmodule ReqLLM.Coverage.GoogleVertexGemini.LabelsTest do
  @moduledoc """
  Google Vertex AI Gemini custom metadata labels feature coverage tests.

  Exercises the Vertex AI `labels` provider option, which attaches
  user-defined metadata to `generateContent` requests for billing and
  reporting. Labels are filterable in Google Cloud billing reports and
  BigQuery exports.

  Run with `REQ_LLM_FIXTURES_MODE=record` and
  `REQ_LLM_MODELS=google_vertex:*` to regenerate fixtures against the
  live API. Otherwise uses cached fixtures.

  See: https://cloud.google.com/vertex-ai/generative-ai/docs/multimodal/add-labels-to-api-calls
  """

  use ExUnit.Case, async: false

  alias ReqLLM.Test.ModelMatrix

  @moduletag :coverage
  @moduletag provider: "google_vertex"
  @moduletag timeout: 180_000

  @provider :google_vertex

  # Scope to Gemini models on Vertex AI. Claude-on-Vertex uses a different
  # formatter/endpoint and is out of scope for this feature PR.
  @models @provider
          |> ModelMatrix.models_for_provider(operation: :text)
          |> Enum.filter(&String.contains?(&1, "gemini"))

  setup_all do
    LLMDB.load(allow: :all, custom: %{})
    :ok
  end

  for model_spec <- @models do
    @model_spec model_spec

    describe "#{model_spec}" do
      @describetag model: model_spec |> String.split(":", parts: 2) |> List.last()

      @tag scenario: :labels_basic
      test "sends labels at the top level of the generateContent body" do
        labels = %{
          "team" => "engineering",
          "environment" => "test",
          "use_case" => "coverage_test"
        }

        opts =
          ReqLLM.Test.Helpers.fixture_opts("labels_basic",
            provider_options: [labels: labels]
          )

        {:ok, response} =
          ReqLLM.generate_text(@model_spec, "Say hello in one word.", opts)

        # Success (no HTTP 400) proves Vertex accepted the labels field.
        assert response.message != nil
        assert ReqLLM.Response.text(response) != ""
      end
    end
  end
end
