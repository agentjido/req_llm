defmodule ReqLLM.Providers.AtlasCloudTest do
  use ReqLLM.ProviderCase, provider: ReqLLM.Providers.AtlasCloud, async: true

  alias ReqLLM.Providers.AtlasCloud

  defp atlascloud_model do
    %LLMDB.Model{
      id: "qwen/qwen3.5-flash",
      model: "qwen/qwen3.5-flash",
      provider_model_id: "qwen/qwen3.5-flash",
      provider: :atlascloud,
      capabilities: %{chat: true}
    }
  end

  test "resolves model strings before LLMDB catalog support" do
    warning =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert {:ok, model} = ReqLLM.model("atlascloud:qwen/qwen3.5-flash")
        assert model.provider == :atlascloud
        assert model.id == "qwen/qwen3.5-flash"
        assert model.model == "qwen/qwen3.5-flash"
      end)

    assert warning =~ "Using unverified model: atlascloud:qwen/qwen3.5-flash"
  end

  test "rejects operations that Atlas Cloud does not expose" do
    assert {:error, %ReqLLM.Error.Invalid.Parameter{}} =
             AtlasCloud.prepare_request(:embedding, atlascloud_model(), "Hello", [])

    assert {:error, %ReqLLM.Error.Invalid.Parameter{}} =
             AtlasCloud.prepare_request(:unsupported, atlascloud_model(), context_fixture(), [])
  end
end
