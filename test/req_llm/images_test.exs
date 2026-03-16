defmodule ReqLLM.ImagesTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Provider.Options
  alias ReqLLM.Providers.Google
  alias ReqLLM.{Context, Images}

  test "supported_models/0 includes known image models by heuristic" do
    models = Images.supported_models()

    assert "openai:gpt-image-1" in models
    assert Enum.any?(models, &google_image_model_spec?/1)
  end

  test "validate_model/1 rejects non-image models" do
    assert {:error, _} = Images.validate_model("openai:gpt-4o")
  end

  test "validate_model/1 accepts inline image models outside the catalog" do
    assert {:ok, %LLMDB.Model{id: "gpt-image-2"}} =
             Images.validate_model(%{provider: :openai, id: "gpt-image-2"})
  end

  test "generate_image/3 errors when context has no user text" do
    context = Context.new([Context.system("You are helpful.")])
    assert {:error, _} = Images.generate_image("openai:gpt-image-1", context, fixture: "noop")
  end

  test "process/4 accepts image options like aspect_ratio" do
    {:ok, model} = ReqLLM.model(google_image_model_spec())

    {:ok, processed} =
      Options.process(Google, :image, model, aspect_ratio: "16:9", context: Context.new())

    assert Keyword.get(processed, :aspect_ratio) == "16:9"
  end

  defp google_image_model_spec do
    Images.supported_models()
    |> Enum.find(&google_image_model_spec?/1)
    |> case do
      nil -> flunk("expected at least one Google image model in the catalog")
      model_spec -> model_spec
    end
  end

  defp google_image_model_spec?(model_spec) do
    String.starts_with?(model_spec, "google:") and
      (String.contains?(model_spec, "image") or String.contains?(model_spec, "imagen"))
  end
end
