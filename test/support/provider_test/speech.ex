defmodule ReqLLM.ProviderTest.Speech do
  @moduledoc """
  Text-to-speech provider coverage tests.

  Exercises the top-level `ReqLLM.speak/3` API with fixture-backed recording and
  replay for raw binary audio responses.
  """

  defmacro __using__(opts) do
    provider = Keyword.fetch!(opts, :provider)

    quote bind_quoted: [provider: provider] do
      use ExUnit.Case, async: false

      import ExUnit.Case
      import ReqLLM.Test.Helpers

      alias ReqLLM.Test.ModelMatrix

      @moduletag :coverage
      @moduletag category: :speech
      @moduletag provider: provider
      @moduletag timeout: 120_000

      @provider provider
      @models ModelMatrix.models_for_provider(provider, operation: :speech)

      setup_all do
        LLMDB.load(allow: :all, custom: Application.get_env(:llm_db, :custom, %{}))
        :ok
      end

      for model_spec <- @models do
        @model_spec model_spec

        describe "#{model_spec}" do
          @tag category: :speech
          @tag scenario: :speech_basic
          @tag model: model_spec |> String.split(":", parts: 2) |> List.last()
          test "basic speech generation" do
            {:ok, result} =
              ReqLLM.speak(
                @model_spec,
                "Hello, this is a short fixture test.",
                fixture_opts(
                  @provider,
                  "speech_basic",
                  ReqLLM.ProviderTest.Speech.options(@provider)
                )
              )

            assert is_binary(result.audio)
            assert byte_size(result.audio) > 100
            assert is_binary(result.format) and result.format != ""

            assert is_binary(result.media_type) and
                     String.starts_with?(result.media_type, "audio/")
          end
        end
      end
    end
  end

  @doc false
  def options(:openai), do: [voice: "alloy", output_format: :mp3]
  def options(:elevenlabs), do: [voice: "21m00Tcm4TlvDq8ikWAM", output_format: :mp3]
  def options(_provider), do: []
end
