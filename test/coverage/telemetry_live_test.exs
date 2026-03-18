defmodule ReqLLM.Coverage.TelemetryLiveTest do
  use ExUnit.Case, async: false

  import ReqLLM.Context
  import ReqLLM.Test.Helpers

  alias ReqLLM.ProviderTest.Comprehensive
  alias ReqLLM.Test.ModelMatrix

  @events [
    [:req_llm, :request, :start],
    [:req_llm, :request, :stop],
    [:req_llm, :request, :exception],
    [:req_llm, :reasoning, :start],
    [:req_llm, :reasoning, :update],
    [:req_llm, :reasoning, :stop],
    [:req_llm, :token_usage]
  ]

  @moduletag :coverage
  @moduletag timeout: 300_000

  if ReqLLM.Test.Env.fixtures_mode() != :record do
    @moduletag skip: "telemetry live smoke tests only run in record mode"
  end

  setup_all do
    LLMDB.load(allow: :all, custom: %{})
    :ok
  end

  setup do
    test_pid = self()
    suffix = System.unique_integer([:positive])

    :telemetry.attach_many(
      "req-llm-live-telemetry-#{suffix}",
      @events,
      fn name, measurements, metadata, _ ->
        send(test_pid, {:telemetry_event, name, measurements, metadata})
      end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach("req-llm-live-telemetry-#{suffix}")
    end)

    :ok
  end

  for provider <- [:openai, :anthropic, :google] do
    @provider provider
    @tag provider: @provider
    test "#{@provider} emits correlated sync and streaming telemetry for reasoning requests" do
      model_spec = reasoning_model_spec!(@provider)
      provider_config = param_bundles(@provider)

      sync_opts =
        model_spec
        |> reasoning_overlay(provider_config.deterministic, 2000)
        |> fixture_opts("#{@provider}-telemetry-sync")

      {:ok, sync_response} =
        ReqLLM.generate_text(model_spec, provider_config.reasoning_prompts.basic, sync_opts)

      assert %ReqLLM.Response{} = sync_response
      sync_events = collect_events()
      assert_reasoning_lifecycle(sync_events, :sync, @provider)

      stream_context =
        ReqLLM.Context.new([
          system(provider_config.reasoning_prompts.streaming_system),
          user(provider_config.reasoning_prompts.streaming_user)
        ])

      stream_opts =
        @provider
        |> param_bundles()
        |> Map.fetch!(:creative)
        |> then(&reasoning_overlay(model_spec, @provider, &1, 3000))
        |> fixture_opts("#{@provider}-telemetry-stream")

      {:ok, stream_response} = ReqLLM.stream_text(model_spec, stream_context, stream_opts)
      stream_chunks = Enum.to_list(stream_response.stream)

      {:ok, streamed_response} =
        ReqLLM.StreamResponse.to_response(%{stream_response | stream: stream_chunks})

      assert %ReqLLM.Response{} = streamed_response
      stream_events = collect_events()
      assert_reasoning_lifecycle(stream_events, :stream, @provider)
    end
  end

  defp reasoning_model_spec!(provider) do
    provider
    |> ModelMatrix.models_for_provider(operation: :text)
    |> Enum.find(&Comprehensive.supports_reasoning?/1)
    |> case do
      nil -> raise "No reasoning-capable model available for #{provider}"
      model_spec -> model_spec
    end
  end

  defp collect_events(acc \\ []) do
    receive do
      {:telemetry_event, name, measurements, metadata} ->
        collect_events([%{name: name, measurements: measurements, metadata: metadata} | acc])
    after
      25 -> Enum.reverse(acc)
    end
  end

  defp assert_reasoning_lifecycle(events, mode, provider) do
    request_start = single_event(events, [:req_llm, :request, :start])
    request_stop = single_event(events, [:req_llm, :request, :stop])
    reasoning_start = single_event(events, [:req_llm, :reasoning, :start])
    reasoning_stop = single_event(events, [:req_llm, :reasoning, :stop])
    token_usage = single_event(events, [:req_llm, :token_usage])
    updates = Enum.filter(events, &(&1.name == [:req_llm, :reasoning, :update]))
    request_id = request_start.metadata.request_id

    refute Enum.any?(events, &(&1.name == [:req_llm, :request, :exception]))

    assert request_start.metadata.mode == mode
    assert request_stop.metadata.mode == mode
    assert request_start.metadata.request_id == request_id
    assert request_stop.metadata.request_id == request_id
    assert reasoning_start.metadata.request_id == request_id
    assert reasoning_stop.metadata.request_id == request_id
    assert token_usage.metadata.request_id == request_id
    assert Enum.all?(updates, &(&1.metadata.request_id == request_id))

    assert request_stop.metadata.reasoning[:supported?]
    assert request_stop.metadata.reasoning[:requested?]
    assert request_stop.metadata.reasoning[:effective?]
    assert is_map(request_stop.metadata.usage)
    assert request_stop.metadata.finish_reason != nil

    case provider do
      :openai ->
        assert request_stop.metadata.reasoning.effective_effort in [
                 :minimal,
                 :low,
                 :medium,
                 :high,
                 :xhigh,
                 :default
               ]

      :anthropic ->
        assert is_integer(request_stop.metadata.reasoning.effective_budget_tokens)
        assert request_stop.metadata.reasoning.effective_budget_tokens > 0

      :google ->
        assert is_integer(request_stop.metadata.reasoning.effective_budget_tokens)
        assert request_stop.metadata.reasoning.effective_budget_tokens > 0
    end

    %{request_id: request_id, request_stop: request_stop.metadata}
  end

  defp single_event(events, name) do
    events
    |> Enum.filter(&(&1.name == name))
    |> case do
      [event] -> event
      other -> flunk("Expected one #{inspect(name)} event, got #{inspect(other)}")
    end
  end
end
