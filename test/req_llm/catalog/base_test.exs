defmodule ReqLLM.Catalog.BaseTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Catalog.Base

  describe "base/0" do
    test "returns a map" do
      catalog = Base.base()
      assert is_map(catalog)
    end

    test "loads providers from manifest files" do
      catalog = Base.base()
      assert map_size(catalog) > 0
    end
  end

  describe "normalization" do
    setup do
      catalog = Base.base()
      {:ok, catalog: catalog}
    end

    test "flattens provider structure when providers exist", %{catalog: catalog} do
      if map_size(catalog) > 0 do
        {_provider_id, provider} = Enum.at(catalog, 0)

        assert is_binary(provider["id"])
        assert is_binary(provider["name"])
        assert is_map(provider["models"])

        refute Map.has_key?(provider, "provider")
      end
    end

    test "converts models array to map keyed by model ID when providers exist", %{
      catalog: catalog
    } do
      if map_size(catalog) > 0 do
        {_provider_id, provider} = Enum.at(catalog, 0)
        models = provider["models"]

        assert is_map(models)

        if map_size(models) > 0 do
          {model_id, model} = Enum.at(models, 0)

          assert is_binary(model_id)
          assert model["id"] == model_id
        end
      end
    end

    test "all keys are strings when providers exist", %{catalog: catalog} do
      if map_size(catalog) > 0 do
        {provider_id, provider} = Enum.at(catalog, 0)

        assert is_binary(provider_id)

        Enum.each(provider, fn {key, _value} ->
          assert is_binary(key)
        end)

        models = provider["models"]

        if map_size(models) > 0 do
          {model_id, model} = Enum.at(models, 0)

          assert is_binary(model_id)

          Enum.each(model, fn {key, _value} ->
            assert is_binary(key)
          end)
        end
      end
    end
  end
end
