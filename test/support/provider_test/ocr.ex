defmodule ReqLLM.ProviderTest.OCR do
  @moduledoc """
  OCR provider coverage tests.

  The suite accepts an explicit `:models` option because current OCR support can
  target provider-hosted models that may not be listed under the provider's
  catalog entry yet.
  """

  @tiny_pdf <<"%PDF-1.0\n1 0 obj\n<< /Type /Catalog >>\nendobj\n">>

  defmacro __using__(opts) do
    provider = Keyword.fetch!(opts, :provider)
    models = Keyword.get(opts, :models, [])

    quote bind_quoted: [provider: provider, models: models] do
      use ExUnit.Case, async: false

      import ExUnit.Case
      import ReqLLM.Test.Helpers

      @moduletag :coverage
      @moduletag category: :ocr
      @moduletag provider: provider
      @moduletag timeout: 120_000

      @provider provider
      @models models

      setup_all do
        LLMDB.load(allow: :all, custom: Application.get_env(:llm_db, :custom, %{}))
        :ok
      end

      for model_spec <- @models do
        @model_spec model_spec

        describe "#{inspect(model_spec)}" do
          @tag category: :ocr
          @tag scenario: :ocr_basic
          test "basic OCR extraction" do
            {:ok, result} =
              ReqLLM.ocr(
                @model_spec,
                ReqLLM.ProviderTest.OCR.tiny_pdf(),
                fixture_opts(@provider, "ocr_basic", [])
              )

            assert is_binary(result.markdown)
            assert is_list(result.pages)
          end
        end
      end
    end
  end

  @doc false
  def tiny_pdf, do: @tiny_pdf
end
