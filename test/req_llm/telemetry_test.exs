defmodule ReqLLM.TelemetryTest do
  use ExUnit.Case, async: false

  import ReqLLM.Context

  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Message.ReasoningDetails
  alias ReqLLM.Response
  alias ReqLLM.Step.Telemetry

  @events [
    [:req_llm, :request, :start],
    [:req_llm, :request, :stop],
    [:req_llm, :request, :exception],
    [:req_llm, :reasoning, :start],
    [:req_llm, :reasoning, :update],
    [:req_llm, :reasoning, :stop]
  ]

  setup do
    test_pid = self()
    suffix = System.unique_integer([:positive])

    Enum.each(@events, fn event ->
      :telemetry.attach(
        "#{inspect(event)}-#{suffix}",
        event,
        fn name, measurements, metadata, _ ->
          send(test_pid, {:telemetry_event, name, measurements, metadata})
        end,
        nil
      )
    end)

    on_exit(fn ->
      Enum.each(@events, fn event ->
        :telemetry.detach("#{inspect(event)}-#{suffix}")
      end)
    end)

    :ok
  end

  test "normalizes effective reasoning across OpenAI, Anthropic, and Google request bodies" do
    model = reasoning_model(:openai, "gpt-5")
    opts = [context: ReqLLM.Context.new([user("hello")]), reasoning_effort: :high]

    openai_reasoning =
      model
      |> ReqLLM.Telemetry.new_context(opts, operation: :chat)
      |> ReqLLM.Telemetry.start_request(%{"reasoning" => %{"effort" => "high"}})
      |> ReqLLM.Telemetry.reasoning_metadata()
      |> Map.fetch!(:reasoning)

    anthropic_reasoning =
      model
      |> ReqLLM.Telemetry.new_context(opts, operation: :chat)
      |> ReqLLM.Telemetry.start_request(%{
        "thinking" => %{"type" => "enabled", "budget_tokens" => 4096}
      })
      |> ReqLLM.Telemetry.reasoning_metadata()
      |> Map.fetch!(:reasoning)

    google_reasoning =
      model
      |> ReqLLM.Telemetry.new_context(
        [
          context: ReqLLM.Context.new([user("hello")]),
          provider_options: [google_thinking_budget: 8192]
        ],
        operation: :chat
      )
      |> ReqLLM.Telemetry.start_request(%{
        "generationConfig" => %{"thinkingConfig" => %{"thinkingBudget" => 8192}}
      })
      |> ReqLLM.Telemetry.reasoning_metadata()
      |> Map.fetch!(:reasoning)

    assert openai_reasoning[:supported?]
    assert openai_reasoning[:requested?]
    assert openai_reasoning[:effective?]
    assert openai_reasoning.requested_mode == :enabled
    assert openai_reasoning.effective_mode == :enabled
    assert openai_reasoning.effective_effort == "high"

    assert anthropic_reasoning[:supported?]
    assert anthropic_reasoning[:requested?]
    assert anthropic_reasoning[:effective?]
    assert anthropic_reasoning.effective_mode == :enabled
    assert anthropic_reasoning.effective_budget_tokens == 4096

    assert google_reasoning[:supported?]
    assert google_reasoning[:effective?]
    assert google_reasoning.effective_mode == :enabled
    assert google_reasoning.effective_budget_tokens == 8192
  end

  test "emits correlated sync request and reasoning lifecycle events" do
    model = reasoning_model(:openai, "gpt-5")

    request =
      Req.new()
      |> Map.put(:body, Jason.encode!(%{"reasoning" => %{"effort" => "high"}}))
      |> Telemetry.attach(
        model,
        [context: ReqLLM.Context.new([user("hello")]), reasoning_effort: :high],
        operation: :chat
      )
      |> Telemetry.handle_request()

    response = response_with_reasoning(model.id)

    usage = %{
      tokens: %{input: 10, output: 12, reasoning: 7},
      cost: nil
    }

    {_req, _resp} =
      Telemetry.handle_response({
        request,
        %Req.Response{status: 200, body: response, private: %{req_llm: %{usage: usage}}}
      })

    assert_receive {:telemetry_event, [:req_llm, :request, :start], _measurements, start_meta}
    assert_receive {:telemetry_event, [:req_llm, :reasoning, :start], _, reasoning_start_meta}

    updates =
      Enum.map(1..3, fn _ ->
        receive do
          {:telemetry_event, [:req_llm, :reasoning, :update], _measurements, metadata} -> metadata
        after
          500 -> flunk("expected reasoning update event")
        end
      end)

    assert Enum.sort(Enum.map(updates, & &1.milestone)) ==
             Enum.sort([:content_started, :details_available, :usage_updated])

    assert_receive {:telemetry_event, [:req_llm, :request, :stop], stop_measurements, stop_meta}
    assert_receive {:telemetry_event, [:req_llm, :reasoning, :stop], _, reasoning_stop_meta}

    request_id = start_meta.request_id

    assert reasoning_start_meta.request_id == request_id
    assert Enum.all?(updates, &(&1.request_id == request_id))
    assert stop_meta.request_id == request_id
    assert reasoning_stop_meta.request_id == request_id

    assert start_meta.reasoning.requested_mode == :enabled
    assert stop_meta.reasoning[:returned_content?]
    assert stop_meta.reasoning.reasoning_tokens == 7
    assert stop_meta.reasoning.channel == :content_and_usage
    assert stop_meta.finish_reason == :stop
    assert stop_meta.response_summary.thinking_bytes > 0
    assert stop_measurements.duration > 0
  end

  test "does not emit reasoning lifecycle events for non-reasoning operations" do
    model = %LLMDB.Model{provider: :openai, id: "text-embedding-3-small"}

    request =
      Req.new()
      |> Map.put(:body, Jason.encode!(%{"input" => "hello"}))
      |> Telemetry.attach(model, [operation: :embedding, text: "hello"], operation: :embedding)
      |> Telemetry.handle_request()

    {_req, _resp} =
      Telemetry.handle_response({
        request,
        %Req.Response{
          status: 200,
          body: %{"data" => [%{"embedding" => [0.1, 0.2]}]},
          private: %{
            req_llm: %{usage: %{tokens: %{input: 3, output: 0, reasoning: 0}, cost: nil}}
          }
        }
      })

    assert_receive {:telemetry_event, [:req_llm, :request, :start], _, start_meta}
    assert_receive {:telemetry_event, [:req_llm, :request, :stop], _, stop_meta}
    refute_receive {:telemetry_event, [:req_llm, :reasoning, _], _, _}
    refute start_meta.reasoning[:supported?]
    refute stop_meta.reasoning[:effective?]
    assert stop_meta.reasoning.channel == :none
  end

  defp reasoning_model(provider, id) do
    %LLMDB.Model{
      provider: provider,
      id: id,
      capabilities: %{reasoning: %{enabled: true}}
    }
  end

  defp response_with_reasoning(model_id) do
    assistant_message = %Message{
      role: :assistant,
      content: [
        ContentPart.thinking("reasoning summary"),
        ContentPart.text("final answer")
      ],
      reasoning_details: [
        %ReasoningDetails{provider: :openai, text: "summary", index: 0}
      ]
    }

    %Response{
      id: "resp_123",
      model: model_id,
      context: ReqLLM.Context.new([user("hello"), assistant_message]),
      message: assistant_message,
      object: nil,
      stream?: false,
      stream: nil,
      usage: %{reasoning_tokens: 7},
      finish_reason: :stop,
      provider_meta: %{},
      error: nil
    }
  end
end
