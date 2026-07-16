defmodule ReqLLM.ImagesTest do
  use ExUnit.Case, async: true

  @moduletag contract: :public_api

  alias ReqLLM.{Context, Images, Response}

  setup do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "created" => 1_234,
        "data" => [%{"b64_json" => Base.encode64("image-bytes")}]
      })
    end)

    :ok
  end

  test "supported_models/0 includes known image models by heuristic" do
    models = Images.supported_models()

    assert "openai:gpt-image-1.5" in models
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
    assert {:error, _} = Images.generate_image("openai:gpt-image-1.5", context, fixture: "noop")
  end

  test "ReqLLM image facade preserves response and bang contracts" do
    model = %{provider: :openai, id: "gpt-image-1.5"}

    opts = [
      api_key: "test-key",
      req_http_options: [plug: {Req.Test, __MODULE__}]
    ]

    assert {:ok, %Response{} = response} =
             ReqLLM.generate_image(model, "A blue square", opts)

    assert Response.image_data(response) == "image-bytes"

    assert %Response{} =
             ReqLLM.generate_image!(model, "A blue square", opts)
  end

  test "ReqLLM image bang facade raises the current public error" do
    model = %{provider: :openai, id: "gpt-image-1.5"}
    context = Context.new([Context.system("You are helpful.")])

    assert_raise ReqLLM.Error.Invalid.Parameter, ~r/non-empty user text prompt/, fn ->
      ReqLLM.generate_image!(model, context)
    end
  end

  test "process/4 accepts image options like aspect_ratio" do
    {:ok, model} = ReqLLM.model(google_image_model_spec())

    {:ok, processed} =
      ReqLLM.Provider.Options.process(
        ReqLLM.Providers.Google,
        :image,
        model,
        aspect_ratio: "16:9",
        context: Context.new()
      )

    assert Keyword.get(processed, :aspect_ratio) == "16:9"
  end

  test "process/4 accepts image edit source and mask options" do
    model = %LLMDB.Model{id: "gpt-image-1.5", provider: :openai}

    {:ok, processed} =
      ReqLLM.Provider.Options.process(
        ReqLLM.Providers.OpenAI,
        :image,
        model,
        source_image: <<1, 2, 3>>,
        source_image_media_type: "image/jpeg",
        mask: <<4, 5, 6>>,
        mask_media_type: "image/png",
        context: Context.new()
      )

    assert Keyword.get(processed, :source_image) == <<1, 2, 3>>
    assert Keyword.get(processed, :source_image_media_type) == "image/jpeg"
    assert Keyword.get(processed, :mask) == <<4, 5, 6>>
    assert Keyword.get(processed, :mask_media_type) == "image/png"
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
