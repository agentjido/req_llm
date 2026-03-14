defmodule ReqLLM.ImagesTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Provider.Options
  alias ReqLLM.Providers.Google
  alias ReqLLM.{Context, Images}

  test "supported_models/0 includes known image models by heuristic" do
    models = Images.supported_models()
    assert "openai:gpt-image-1" in models
    assert "google:gemini-2.0-flash-exp-image-generation" in models
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
    {:ok, model} = ReqLLM.model("google:gemini-2.0-flash-exp-image-generation")

    {:ok, processed} =
      Options.process(Google, :image, model, aspect_ratio: "16:9", context: Context.new())

    assert Keyword.get(processed, :aspect_ratio) == "16:9"
  end
end
