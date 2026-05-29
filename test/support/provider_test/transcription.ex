defmodule ReqLLM.ProviderTest.Transcription do
  @moduledoc """
  Speech-to-text provider coverage tests.

  Uses a deterministic local WAV sample so transcription fixtures can be
  recorded and replayed without generating audio during the test.
  """

  @sample_audio Path.expand("../audio/hello_world.wav", __DIR__)

  defmacro __using__(opts) do
    provider = Keyword.fetch!(opts, :provider)

    quote bind_quoted: [provider: provider] do
      use ExUnit.Case, async: false

      import ExUnit.Case
      import ReqLLM.Test.Helpers

      alias ReqLLM.Test.ModelMatrix

      @moduletag :coverage
      @moduletag category: :transcription
      @moduletag provider: provider
      @moduletag timeout: 120_000

      @provider provider
      @models ModelMatrix.models_for_provider(provider, operation: :transcription)

      setup_all do
        LLMDB.load(allow: :all, custom: Application.get_env(:llm_db, :custom, %{}))
        :ok
      end

      for model_spec <- @models do
        @model_spec model_spec

        describe "#{model_spec}" do
          @tag category: :transcription
          @tag scenario: :transcription_basic
          @tag model: model_spec |> String.split(":", parts: 2) |> List.last()
          test "basic audio transcription" do
            {:ok, result} =
              ReqLLM.transcribe(
                @model_spec,
                {:binary, ReqLLM.ProviderTest.Transcription.sample_audio(), "audio/wav"},
                fixture_opts(@provider, "transcription_basic", language: "en")
              )

            assert is_binary(result.text)
            assert result.text != ""
          end
        end
      end
    end
  end

  @doc false
  def sample_audio do
    File.read!(@sample_audio)
  end
end
