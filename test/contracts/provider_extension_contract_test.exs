defmodule ReqLLM.ProviderExtensionContractTest do
  use ExUnit.Case, async: false

  import ReqLLM.ProviderCase, only: [provider_contract: 1]

  defmodule ExternalProvider do
    use ReqLLM.Provider,
      id: :contract_external,
      default_base_url: "https://contract.example/v1",
      default_env_key: "CONTRACT_EXTERNAL_API_KEY"

    @provider_schema [contract_option: [type: :string]]
  end

  provider_contract(
    provider: ExternalProvider,
    provider_id: :contract_external,
    default_base_url: "https://contract.example/v1",
    provider_options: [:contract_option],
    defaults: true
  )

  defmodule MinimalProvider do
    @behaviour ReqLLM.Provider

    def prepare_request(_operation, _model, _input, _opts), do: {:error, :not_implemented}
    def attach(request, _model, _opts), do: request
    def encode_body(request), do: request
    def decode_response(request_response), do: request_response
  end

  @tag contract: :provider_extension
  test "provider contract keeps every optional callback optional" do
    on_exit(fn -> ReqLLM.Providers.unregister(MinimalProvider) end)

    optional_callbacks = ReqLLM.Provider.behaviour_info(:optional_callbacks)

    refute Enum.any?(optional_callbacks, fn {name, arity} ->
             function_exported?(MinimalProvider, name, arity)
           end)

    assert {:ok, MinimalProvider} = ReqLLM.Providers.register(MinimalProvider)
    assert {:ok, MinimalProvider} = ReqLLM.provider(MinimalProvider)
  end
end
