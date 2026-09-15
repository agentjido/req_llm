defmodule ReqLLM.ModelPrefixResolutionTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias LLMDB.{Catalog, Model, Provider, Spec, Store}
  alias ReqLLM.Providers.AmazonBedrock

  @moduletag contract: :public_api

  @sonnet "anthropic.claude-sonnet-4-5-20250929-v1:0"
  @opus "anthropic.claude-opus-4-7"

  setup do
    snapshot = Store.snapshot()
    opts = Store.last_opts()
    warn_unverified_models = Application.fetch_env(:req_llm, :warn_unverified_models)
    Application.put_env(:req_llm, :warn_unverified_models, true)

    on_exit(fn ->
      if snapshot, do: Store.put!(snapshot, opts), else: Store.clear!()

      case warn_unverified_models do
        {:ok, value} -> Application.put_env(:req_llm, :warn_unverified_models, value)
        :error -> Application.delete_env(:req_llm, :warn_unverified_models)
      end
    end)

    providers = [
      Provider.new!(%{id: :amazon_bedrock}),
      Provider.new!(%{id: :anthropic, extra: %{model_id_prefixes: ["zone."]}}),
      Provider.new!(%{id: :openai})
    ]

    models = [
      catalog_model(@sonnet, 3.0, aliases: ["sonnet"], provider_model_id: "global." <> @sonnet),
      catalog_model("cohere.embed-v4", 0.1, provider_model_id: "cohere.embed-v4:0"),
      catalog_model(@opus, 5.0),
      catalog_model("eu." <> @opus, 5.5),
      Model.new!(%{
        provider: :anthropic,
        id: "claude-versioned",
        aliases: ["claude-short"],
        provider_model_id: "claude-api-version"
      }),
      Model.new!(%{
        provider: :anthropic,
        id: "zone.claude-versioned",
        provider_model_id: "zone.claude-api-version"
      }),
      Model.new!(%{provider: :openai, id: "gpt-test", aliases: ["gpt-short"]})
    ]

    catalog =
      Catalog.build(providers, models, models,
        filters: %{allow: :all, deny: %{}},
        loaded_at: nil,
        digest: "reqllm-prefix-test"
      )

    Store.put!(catalog, [])
    :ok
  end

  test "all spec forms replace a default profile with the resolved profile" do
    for spec <- specs(:amazon_bedrock, "eu." <> @sonnet) do
      assert {:ok, model} = ReqLLM.model(spec)
      assert model.id == @sonnet
      assert model.provider_model_id == "eu." <> @sonnet
    end
  end

  test "prefixed aliases use the canonical API ID" do
    for spec <- specs(:amazon_bedrock, "us.sonnet") do
      assert {:ok, model} = ReqLLM.model(spec)
      assert model.id == @sonnet
      assert model.provider_model_id == "us." <> @sonnet
    end
  end

  test "an existing API prefix is not duplicated" do
    for spec <- specs(:amazon_bedrock, "global." <> @sonnet) do
      assert {:ok, model} = ReqLLM.model(spec)
      assert model.provider_model_id == "global." <> @sonnet
    end
  end

  test "the API ID suffix is retained when the canonical ID has no suffix" do
    for spec <- specs(:amazon_bedrock, "global.cohere.embed-v4") do
      assert {:ok, model} = ReqLLM.model(spec)
      assert model.id == "cohere.embed-v4"
      assert model.provider_model_id == "global.cohere.embed-v4:0"
    end
  end

  test "all spec forms retain the prices selected by LLMDB" do
    model_id = "eu." <> @opus

    assert {:ok, {:amazon_bedrock, ^model_id, selected}} =
             Spec.resolve({:amazon_bedrock, model_id})

    usage = %{input_tokens: 1_000_000, output_tokens: 1_000_000}
    assert {:ok, selected_cost} = ReqLLM.Billing.calculate(usage, selected)
    assert selected_cost != nil

    for spec <- specs(:amazon_bedrock, model_id) do
      assert {:ok, model} = ReqLLM.model(spec)
      assert model.id == selected.id
      assert model.cost == selected.cost
      assert model.pricing == selected.pricing
      assert model.provider_model_id == model_id
      assert {:ok, ^selected_cost} = ReqLLM.Billing.calculate(usage, model)
    end
  end

  test "requests use the same resolved profile for all spec forms and transports" do
    context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

    opts = [
      access_key_id: "AKIATEST",
      secret_access_key: "secretTEST",
      region: "us-east-1",
      use_converse: false,
      max_tokens: 32
    ]

    for spec <- specs(:amazon_bedrock, "eu.sonnet") do
      model = ReqLLM.model!(spec)
      assert {:ok, request} = AmazonBedrock.prepare_request(:chat, model, context, opts)
      assert request.url.path == "/model/eu.#{@sonnet}/invoke"

      assert {:ok, stream_request} =
               AmazonBedrock.attach_stream(model, context, opts, ReqLLM.Finch)

      assert stream_request.path == "/model/eu.#{@sonnet}/invoke-with-response-stream"
    end
  end

  test "unprefixed aliases retain their catalog API ID" do
    for spec <- specs(:amazon_bedrock, "sonnet") do
      assert {:ok, model} = ReqLLM.model(spec)
      assert model.provider_model_id == "global." <> @sonnet
    end

    for spec <- specs(:anthropic, "claude-short") do
      assert {:ok, model} = ReqLLM.model(spec)
      assert model.id == "claude-versioned"
      assert model.provider_model_id == "claude-api-version"
    end
  end

  test "provider-defined prefixes retain an exact API route" do
    for spec <- specs(:anthropic, "zone.claude-versioned") do
      assert {:ok, model} = ReqLLM.model(spec)
      assert model.id == "zone.claude-versioned"
      assert model.provider_model_id == "zone.claude-api-version"
    end
  end

  test "inline maps and structs keep their explicit route" do
    attrs = %{provider: :amazon_bedrock, id: @sonnet, provider_model_id: "custom-deployment"}

    for spec <- [attrs, Model.new!(attrs)] do
      assert {:ok, model} = ReqLLM.model(spec)
      assert model.provider_model_id == "custom-deployment"
    end
  end

  test "at-format specs support providers registered only in ReqLLM" do
    for spec <- specs(:openai_codex, "gpt-short") do
      assert {:ok, model} = ReqLLM.model(spec)
      assert model.provider == :openai_codex
      assert model.id == "gpt-test"
      assert model.provider_model_id == "gpt-test"
    end
  end

  test "unknown at-format models retain the registered provider's fallback" do
    output =
      capture_io(:stderr, fn ->
        assert {:ok, model} = ReqLLM.model("new-model:0@openai_codex")
        assert model.provider == :openai_codex
        assert model.id == "new-model:0"
        assert model.provider_model_id == "new-model:0"
      end)

    assert output == ""
  end

  test "a registered at-format provider takes precedence over a colon in the model ID" do
    for model_id <- ["openai:new-model", "openai:new-model:0"] do
      assert {:ok, model} = ReqLLM.model("#{model_id}@openai_codex")
      assert model.provider == :openai_codex
      assert model.id == model_id
      assert model.provider_model_id == model_id
    end
  end

  test "unknown catalog models use the same fallback for every spec form" do
    for spec <- specs(:amazon_bedrock, "eu.new-model:0") do
      output =
        capture_io(:stderr, fn ->
          assert {:ok, model} = ReqLLM.model(spec)
          assert model.provider == :amazon_bedrock
          assert model.id == "eu.new-model:0"
          assert model.provider_model_id == "eu.new-model:0"
        end)

      assert output =~ "Using unverified model: amazon_bedrock:eu.new-model:0"
    end
  end

  test "malformed strings do not enter the unverified-model fallback" do
    output =
      capture_io(:stderr, fn ->
        for spec <- ["openai:", "@openai_codex", "openai_codex:", "bare-model"] do
          assert {:error, _reason} = ReqLLM.model(spec)
        end
      end)

    assert output == ""
  end

  defp specs(provider, model_id) do
    provider_name = Atom.to_string(provider)

    [
      "#{provider_name}:#{model_id}",
      "#{model_id}@#{provider_name}",
      "#{String.replace(provider_name, "_", "-")}:#{model_id}",
      {provider, model_id, []},
      {provider, id: model_id},
      {provider, model: model_id}
    ]
  end

  defp catalog_model(id, rate, attrs \\ []) do
    %{provider: :amazon_bedrock, id: id, capabilities: %{chat: true}}
    |> Map.merge(Map.new(attrs))
    |> Map.put(:cost, %{input: rate, output: rate * 5})
    |> Map.put(:pricing, %{
      currency: "USD",
      components: [
        %{id: "token.input", kind: "token", per: 1_000_000, rate: rate},
        %{id: "token.output", kind: "token", per: 1_000_000, rate: rate * 5}
      ]
    })
    |> Model.new!()
  end
end
