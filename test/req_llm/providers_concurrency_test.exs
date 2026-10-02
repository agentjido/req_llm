defmodule ReqLLM.ProvidersConcurrencyTest do
  use ExUnit.Case, async: false

  alias ReqLLM.Providers

  for n <- 1..24 do
    defmodule Module.concat(__MODULE__, "Provider#{n}") do
      @behaviour ReqLLM.Provider
      def provider_id, do: unquote(String.to_atom("registry_test_#{n}"))
      def default_base_url, do: "https://example.invalid"
      def supported_provider_options, do: []
      def prepare_request(_, _, _, _), do: {:error, :unused}
      def attach(request, _, _), do: request
      def encode_body(request), do: request
      def decode_response(response), do: response
    end
  end

  defmodule Replacement do
    use ReqLLM.Provider,
      id: :registry_test_1,
      default_base_url: "https://replacement.invalid",
      default_env_key: "UNUSED_TEST_KEY"
  end

  setup do
    saved = :persistent_term.get(:req_llm_providers)
    on_exit(fn -> :persistent_term.put(:req_llm_providers, saved) end)
    %{providers: for(n <- 1..24, do: Module.concat(__MODULE__, "Provider#{n}"))}
  end

  test "all successful distinct concurrent registrations remain available", %{
    providers: providers
  } do
    results =
      concurrently(Enum.map(providers, fn provider -> fn -> Providers.register(provider) end end))

    assert Enum.all?(results, &match?({:ok, _}, &1))

    for provider <- providers do
      assert Providers.get(provider.provider_id()) == {:ok, provider}
    end
  end

  test "concurrent removal and registration preserve unrelated changes", %{providers: providers} do
    {removed, registered} = Enum.split(providers, 12)
    Enum.each(removed, &Providers.register!/1)

    work =
      Enum.map(removed, fn provider -> fn -> Providers.unregister(provider.provider_id()) end end) ++
        Enum.map(registered, fn provider -> fn -> Providers.register(provider) end end)

    concurrently(work)

    for provider <- removed,
        do: assert(match?({:error, _}, Providers.get(provider.provider_id())))

    for provider <- registered,
        do: assert(Providers.get(provider.provider_id()) == {:ok, provider})
  end

  test "initialization preserves concurrent runtime registrations", %{providers: providers} do
    work =
      [fn -> Providers.initialize() end, fn -> Providers.initialize() end] ++
        Enum.map(providers, fn provider -> fn -> Providers.register(provider) end end)

    concurrently(work)

    for provider <- providers,
        do: assert(Providers.get(provider.provider_id()) == {:ok, provider})
  end

  test "same-ID replacement preserves return values and the final successful replacement", %{
    providers: [first | _]
  } do
    assert {:ok, :registry_test_1} = Providers.register(first)
    assert {:ok, :registry_test_1} = Providers.register(Replacement)
    assert {:ok, Replacement} = Providers.get(:registry_test_1)
    assert :ok = Providers.initialize()
    assert {:ok, Replacement} = Providers.get(:registry_test_1)
    assert :ok = Providers.unregister(:registry_test_1)
    assert {:error, _} = Providers.get(:registry_test_1)
  end

  defp concurrently(work) do
    tasks =
      Enum.map(work, fn run ->
        Task.async(fn ->
          receive do
            :go -> run.()
          end
        end)
      end)

    Enum.each(tasks, &send(&1.pid, :go))
    Enum.map(tasks, &Task.await(&1, 30_000))
  end
end
