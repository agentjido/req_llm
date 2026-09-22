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

  test "process/4 accepts the gpt-image parameter set" do
    model = %LLMDB.Model{id: "gpt-image-1.5", provider: :openai}

    {:ok, processed} =
      ReqLLM.Provider.Options.process(
        ReqLLM.Providers.OpenAI,
        :image,
        model,
        background: :transparent,
        moderation: "low",
        output_compression: 50,
        output_format: :webp,
        quality: :low,
        context: Context.new()
      )

    assert Keyword.get(processed, :background) == :transparent
    assert Keyword.get(processed, :moderation) == "low"
    assert Keyword.get(processed, :output_compression) == 50
    assert Keyword.get(processed, :quality) == :low
  end

  test "process/4 accepts every gpt-image quality tier as an atom" do
    model = %LLMDB.Model{id: "gpt-image-2.5-sunburst", provider: :openai}

    for quality <- [:auto, :low, :medium, :high, :xhigh, :max] do
      {:ok, processed} =
        ReqLLM.Provider.Options.process(
          ReqLLM.Providers.OpenAI,
          :image,
          model,
          quality: quality,
          context: Context.new()
        )

      assert Keyword.get(processed, :quality) == quality
    end
  end

  test "process/4 rejects gpt-image parameters outside their allowed values" do
    model = %LLMDB.Model{id: "gpt-image-1.5", provider: :openai}

    for opts <- [
          [background: :blurred],
          [moderation: :off],
          [output_compression: 101],
          [input_fidelity: :medium]
        ] do
      assert {:error, _} =
               ReqLLM.Provider.Options.process(
                 ReqLLM.Providers.OpenAI,
                 :image,
                 model,
                 opts ++ [context: Context.new()]
               )
    end
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

  describe "OpenAI-only image options on other providers" do
    @openai_only [background: :transparent, moderation: :low, output_compression: 50]

    for {provider_mod, provider_id, model_id} <- [
          {ReqLLM.Providers.Google, :google, "gemini-2.5-flash-image"},
          {ReqLLM.Providers.XAI, :xai, "grok-2-image-1212"},
          {ReqLLM.Providers.Minimax, :minimax, "image-01"}
        ] do
      test "#{provider_id} prepares a request instead of raising on them" do
        model = %LLMDB.Model{id: unquote(model_id), provider: unquote(provider_id)}

        for {key, value} <- @openai_only ++ [input_fidelity: :high] do
          assert {:ok, request} =
                   unquote(provider_mod).prepare_request(:image, model, "a fox", [
                     {:api_key, "test-key"},
                     {key, value}
                   ])

          refute Map.has_key?(request.options, key)
        end
      end

      test "#{provider_id} escalates them under on_unsupported: :error" do
        model = %LLMDB.Model{id: unquote(model_id), provider: unquote(provider_id)}

        assert {:error, %ReqLLM.Error.Validation.Error{reason: reason}} =
                 unquote(provider_mod).prepare_request(:image, model, "a fox",
                   api_key: "test-key",
                   background: :transparent,
                   on_unsupported: :error
                 )

        assert reason =~ ":background"
      end
    end
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

  describe "stream_image/3" do
    test "rejects providers without image streaming" do
      assert {:error, %ReqLLM.Error.Invalid.Parameter{parameter: message}} =
               Images.stream_image(%{provider: :xai, id: "grok-2-image"}, "A red square")

      assert message =~ "image streaming is only supported for OpenAI and Azure"

      assert {:error, %ReqLLM.Error.Invalid.Parameter{}} =
               Images.stream_image("google:gemini-2.5-flash-image", "A red square")
    end

    test "rejects OpenAI models outside the image families" do
      assert {:error, %ReqLLM.Error.Invalid.Parameter{parameter: message}} =
               Images.stream_image("openai:gpt-4o", "A red square")

      assert message =~ "gpt-4o"
    end

    test "rejects edits and multi-image requests" do
      assert {:error, %ReqLLM.Error.Invalid.Parameter{parameter: edit_message}} =
               Images.stream_image("openai:gpt-image-1.5", "A red square", source_image: "png")

      assert edit_message =~ "streaming image edits are not supported"

      assert {:error, %ReqLLM.Error.Invalid.Parameter{parameter: n_message}} =
               Images.stream_image("openai:gpt-image-1.5", "A red square", n: 2)

      assert n_message =~ "single image"
    end

    test "rejects a context without user text" do
      context = Context.new([Context.system("You are helpful.")])

      assert {:error, %ReqLLM.Error.Invalid.Parameter{}} =
               Images.stream_image("openai:gpt-image-1.5", context, api_key: "test-key")
    end

    test "is exposed on the ReqLLM facade" do
      assert {:error, %ReqLLM.Error.Invalid.Parameter{}} =
               ReqLLM.stream_image("openai:gpt-4o", "A red square")
    end
  end

  test "generate_image/3 rejects stream: true" do
    assert {:error, %ReqLLM.Error.Invalid.Parameter{parameter: message}} =
             Images.generate_image("openai:gpt-image-1.5", "A red square", stream: true)

    assert message =~ "stream_image/3"
  end
end
