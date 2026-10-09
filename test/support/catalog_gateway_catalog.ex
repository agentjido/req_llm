defmodule ReqLLM.Test.CatalogGatewayCatalog do
  @moduledoc false

  alias LLMDB.{Catalog, Model, Provider, Store}

  def install! do
    snapshot = Store.snapshot()
    opts = Store.last_opts()

    ExUnit.Callbacks.on_exit(fn ->
      if snapshot, do: Store.put!(snapshot, opts), else: Store.clear!()
    end)

    providers = [
      Provider.new!(%{
        id: :llmapi,
        name: "LLM API",
        runtime: %{
          base_url: "https://api.llmapi.ai/v1",
          auth: %{type: "bearer", env: ["LLM_API_KEY", "LLMAPI_API_KEY"]}
        }
      }),
      Provider.new!(%{id: :missing_gateway_runtime}),
      Provider.new!(%{id: :openai})
    ]

    model =
      Model.new!(%{
        provider: :llmapi,
        id: "vendor/chat-model",
        capabilities: %{chat: true, streaming: %{text: true}, tools: %{enabled: true}},
        execution: %{
          text: %{
            supported: true,
            family: "openai_chat_compatible",
            wire_protocol: "openai_chat",
            path: "/chat/completions",
            provider_model_id: "vendor/chat-model"
          }
        },
        pricing: %{
          currency: "USD",
          components: [
            %{id: "token.input", kind: "token", per: 1_000_000, rate: 10.0},
            %{id: "token.output", kind: "token", per: 1_000_000, rate: 20.0}
          ]
        }
      })

    models = [
      model,
      %{model | id: "catalog-only", catalog_only: true},
      %{model | id: "missing-contract", execution: %{}},
      %{model | provider: :missing_gateway_runtime},
      Model.new!(%{provider: :openai, id: "registered-model"})
    ]

    catalog =
      Catalog.build(providers, models, models,
        filters: %{allow: :all, deny: %{}},
        loaded_at: nil,
        digest: "reqllm-catalog-gateway-test"
      )

    Store.put!(catalog, [])
    %{model: model, registry: registry(models)}
  end

  defp registry(models) do
    models
    |> Enum.group_by(& &1.provider)
    |> Map.new(fn {provider, models} ->
      {provider,
       Enum.map(models, fn model ->
         %{"id" => model.id, "capabilities" => model.capabilities, "type" => "text"}
       end)}
    end)
  end
end
