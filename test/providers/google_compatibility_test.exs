defmodule ReqLLM.Providers.GoogleCompatibilityTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Context
  alias ReqLLM.Providers.Google
  alias ReqLLM.Providers.GoogleVertex

  test "rejects unsupported options through both Google providers" do
    for provider <- [Google, GoogleVertex],
        id <- ["gemini-3.5-flash-lite", "gemini-3.6-flash", "gemini-3.8-flash"],
        operation <- [:chat, :object],
        {key, value} <- [
          temperature: 0.7,
          top_p: 0.9,
          top_k: 40,
          reasoning_token_budget: 1000,
          google_thinking_budget: 1000,
          google_candidate_count: 1
        ] do
      model = LLMDB.Model.new!(%{provider: provider.provider_id(), id: id})

      for opts <- [[{key, value}], [provider_options: [{key, value}]]] do
        assert_raise ReqLLM.Error.Invalid.Parameter, fn ->
          provider.pre_validate_options(operation, model, opts)
        end
      end
    end
  end

  test "uses the routed model ID for compatibility rules" do
    model =
      LLMDB.Model.new!(%{
        provider: :google_vertex,
        id: "custom-deployment",
        extra: %{family: "gemini-flash"},
        provider_model_id: "publishers/google/models/gemini-3.8-flash"
      })

    assert_raise ReqLLM.Error.Invalid.Parameter, fn ->
      GoogleVertex.pre_validate_options(:chat, model, temperature: 0.7)
    end

    assert {opts, []} = Google.translate_options(:chat, model, reasoning_effort: :minimal)
    assert opts[:google_thinking_level] == :low
  end

  test "accepts default options through the complete options pipeline" do
    for provider <- [Google, GoogleVertex], operation <- [:chat, :object] do
      model = LLMDB.Model.new!(%{provider: provider.provider_id(), id: "gemini-3.8-flash"})
      opts = ReqLLM.Provider.Options.process!(provider, operation, model, [])
      refute Keyword.has_key?(opts, :google_candidate_count)
    end
  end

  test "rejects unsupported explicit thinking levels on Gemini 3.8" do
    model = LLMDB.Model.new!(%{provider: :google, id: "gemini-3.8-flash"})

    for level <- [:minimal, "minimal"] do
      assert_raise ReqLLM.Error.Invalid.Parameter, fn ->
        Google.pre_validate_options(:chat, model,
          provider_options: [google_thinking_level: level]
        )
      end
    end
  end

  test "omits candidateCount for Gemini 3 text and structured output requests" do
    {:ok, schema} = ReqLLM.Schema.compile(name: [type: :string, required: true])
    context = Context.new([Context.user("Return a name")])

    for id <- ["gemini-3-flash", "gemini-3.6-flash", "gemini-3.8-flash"],
        operation <- [:chat, :object] do
      opts = [operation: operation, compiled_schema: schema]

      request = %Req.Request{options: Keyword.merge(opts, model: id, context: context)}
      body = request |> Google.encode_body() |> ReqLLM.Test.Helpers.json_body()
      refute Map.has_key?(body["generationConfig"], "candidateCount")

      vertex_body = ReqLLM.Providers.GoogleVertex.Gemini.format_request(id, context, opts)
      refute Map.has_key?(vertex_body["generationConfig"], "candidateCount")
    end
  end

  test "rejects unsupported options in direct encoding and translation" do
    model = LLMDB.Model.new!(%{provider: :google, id: "gemini-3.8-flash"})

    assert_raise ReqLLM.Error.Invalid.Parameter, fn ->
      Google.translate_options(:chat, model, reasoning_token_budget: 1000)
    end

    assert_raise ReqLLM.Error.Invalid.Parameter, fn ->
      Google.encode_body(%Req.Request{options: [model: model.id, temperature: 0.7]})
    end
  end

  test "preserves Gemini 2.5 options and Gemini 3.0 token budgets" do
    model = LLMDB.Model.new!(%{provider: :google, id: "gemini-2.5-flash"})
    opts = [temperature: 0.7, top_p: 0.9, top_k: 40, google_candidate_count: 2]
    assert {validated, []} = Google.pre_validate_options(:chat, model, opts)
    assert validated[:temperature] == 0.7

    model = LLMDB.Model.new!(%{provider: :google, id: "gemini-3-flash"})
    assert {translated, []} = Google.translate_options(:chat, model, reasoning_token_budget: 1000)
    assert translated[:google_thinking_budget] == 1000
  end
end
