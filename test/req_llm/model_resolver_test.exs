defmodule ReqLLM.ModelResolverTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias ReqLLM.ModelResolver

  defmodule TestProvider do
    use ReqLLM.Provider,
      id: :model_resolver_test,
      default_base_url: "https://model-resolver.test/v1",
      default_env_key: "MODEL_RESOLVER_TEST_API_KEY"
  end

  setup do
    assert {:ok, :model_resolver_test} = ReqLLM.Providers.register(TestProvider)
    on_exit(fn -> ReqLLM.Providers.unregister(:model_resolver_test) end)
    :ok
  end

  test "returns unverified-model warnings as data without output" do
    output =
      capture_io(:stderr, fn ->
        assert {:ok, model, [warning]} =
                 resolve("model_resolver_test:new-model")

        assert model.provider == :model_resolver_test
        assert model.id == "new-model"
        assert warning =~ "Using unverified model: model_resolver_test:new-model"
        assert warning =~ "ReqLLM.model(%{provider: :model_resolver_test, id: \"new-model\"})"
      end)

    assert output == ""
  end

  test "the public facade emits each returned warning once" do
    output =
      capture_io(:stderr, fn ->
        assert {:ok, model} = ReqLLM.model("model_resolver_test:new-model")
        assert model.provider == :model_resolver_test
        assert model.id == "new-model"
      end)

    assert output =~ "Using unverified model: model_resolver_test:new-model"
    assert length(String.split(output, "Using unverified model:")) == 2
  end

  test "resolves every supported static input form" do
    {:ok, catalog_model, []} = resolve("openai:gpt-4o")

    inputs = [
      {:openai, id: "gpt-4o"},
      {:openai, "gpt-4o", temperature: 0.2},
      %{provider: :openai, id: "gpt-4o"},
      %{"provider" => "openai", "id" => "gpt-4o"},
      catalog_model
    ]

    for input <- inputs do
      assert {:ok, %LLMDB.Model{provider: :openai, id: "gpt-4o"}, []} =
               resolve(input)
    end
  end

  test "keeps public error and bang behavior" do
    assert {:error, resolver_error} = resolve(%{id: "missing-provider"})
    assert {:error, public_error} = ReqLLM.model(%{id: "missing-provider"})

    assert resolver_error.__struct__ == public_error.__struct__
    assert resolver_error.tag == public_error.tag
    assert resolver_error.reason == public_error.reason
    assert resolver_error.context == public_error.context
    assert Exception.message(resolver_error) == Exception.message(public_error)

    assert_raise ReqLLM.Error.Validation.Error, Exception.message(resolver_error), fn ->
      ReqLLM.model!(%{id: "missing-provider"})
    end
  end

  test "keeps Google pricing normalization idempotent" do
    assert {:ok, first, []} =
             resolve("google:gemini-2.5-computer-use-preview-10-2025")

    assert {:ok, second, []} = resolve(first)
    assert second.cost == first.cost
    assert ReqLLM.Pricing.components(second) == ReqLLM.Pricing.components(first)

    component_ids = Enum.map(ReqLLM.Pricing.components(second), &ReqLLM.MapAccess.get(&1, :id))

    assert Enum.count(component_ids, &(&1 == "token.input.standard_context")) == 1
    assert Enum.count(component_ids, &(&1 == "token.input.long_context")) == 1
    assert Enum.count(component_ids, &(&1 == "token.output.standard_context")) == 1
    assert Enum.count(component_ids, &(&1 == "token.output.long_context")) == 1
  end

  defp resolve(input), do: ModelResolver.resolve(input, &ReqLLM.Providers.get/1)
end
