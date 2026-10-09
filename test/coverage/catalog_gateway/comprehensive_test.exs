for provider <- LLMDB.providers(),
    {:error, _} <- [ReqLLM.Providers.get(provider.id)],
    ReqLLM.Test.ModelMatrix.models_for_provider(provider.id, operation: :text) != [] do
  module = Module.concat([ReqLLM.Coverage.CatalogGateway, Macro.camelize(to_string(provider.id))])

  Module.create(
    module,
    quote do
      use ReqLLM.ProviderTest.Comprehensive, provider: unquote(provider.id)
    end,
    Macro.Env.location(__ENV__)
  )
end
