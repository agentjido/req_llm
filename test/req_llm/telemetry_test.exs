defmodule ReqLLM.TelemetryTest do
  use ExUnit.Case, async: false

  import ReqLLM.Context
  import ReqLLM.Test.Helpers, only: [openai_format_json_fixture: 1]

  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Message.ReasoningDetails
  alias ReqLLM.Response
  alias ReqLLM.Step.Retry
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
    openai_model = reasoning_model(:openai, "gpt-5")
    anthropic_model = reasoning_model(:anthropic, "claude-sonnet-4-5")
    google_model = reasoning_model(:google, "gemini-2.5-pro")
    opts = [context: ReqLLM.Context.new([user("hello")]), reasoning_effort: :high]

    openai_reasoning =
      openai_model
      |> ReqLLM.Telemetry.new_context(opts, operation: :chat)
      |> ReqLLM.Telemetry.start_request(%{"reasoning" => %{"effort" => "high"}})
      |> ReqLLM.Telemetry.reasoning_metadata()
      |> Map.fetch!(:reasoning)

    anthropic_reasoning =
      anthropic_model
      |> ReqLLM.Telemetry.new_context(opts, operation: :chat)
      |> ReqLLM.Telemetry.start_request(%{
        "thinking" => %{"type" => "enabled", "budget_tokens" => 4096}
      })
      |> ReqLLM.Telemetry.reasoning_metadata()
      |> Map.fetch!(:reasoning)

    google_reasoning =
      google_model
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
    assert openai_reasoning.effective_effort == :high

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

  test "explicit disable signals win over enabled reasoning hints" do
    anthropic_reasoning =
      reasoning_model(:anthropic, "claude-sonnet-4-5")
      |> ReqLLM.Telemetry.new_context(
        [
          context: ReqLLM.Context.new([user("hello")]),
          reasoning_effort: :high,
          thinking: %{type: "disabled", budget_tokens: 0}
        ],
        operation: :chat
      )
      |> ReqLLM.Telemetry.start_request(%{
        "thinking" => %{"type" => "disabled", "budget_tokens" => 0}
      })
      |> ReqLLM.Telemetry.reasoning_metadata()
      |> Map.fetch!(:reasoning)

    google_reasoning =
      reasoning_model(:google, "gemini-2.5-pro")
      |> ReqLLM.Telemetry.new_context(
        [
          context: ReqLLM.Context.new([user("hello")]),
          reasoning_effort: :high,
          provider_options: [google_thinking_budget: 0]
        ],
        operation: :chat
      )
      |> ReqLLM.Telemetry.start_request(%{
        "generationConfig" => %{"thinkingConfig" => %{"thinkingBudget" => 0}}
      })
      |> ReqLLM.Telemetry.reasoning_metadata()
      |> Map.fetch!(:reasoning)

    refute anthropic_reasoning[:requested?]
    assert anthropic_reasoning.requested_mode == :disabled
    refute google_reasoning[:requested?]
    assert google_reasoning.requested_mode == :disabled
  end

  test "tracks google thinking levels as requested reasoning" do
    {:ok, google_model} = ReqLLM.model("google:gemini-3-flash-preview")

    google_reasoning =
      google_model
      |> ReqLLM.Telemetry.new_context(
        [
          context: ReqLLM.Context.new([user("hello")]),
          provider_options: [google_thinking_level: :medium]
        ],
        operation: :chat
      )
      |> ReqLLM.Telemetry.start_request(%{
        "generationConfig" => %{"thinkingConfig" => %{"thinkingLevel" => "medium"}}
      })
      |> ReqLLM.Telemetry.reasoning_metadata()
      |> Map.fetch!(:reasoning)

    assert google_reasoning[:supported?]
    assert google_reasoning[:requested?]
    assert google_reasoning[:effective?]
    assert google_reasoning.requested_mode == :enabled
    assert google_reasoning.requested_effort == :medium
    assert is_nil(google_reasoning.requested_budget_tokens)
    assert google_reasoning.effective_mode == :enabled
    assert google_reasoning.effective_effort == :medium
    assert is_nil(google_reasoning.effective_budget_tokens)
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

  test "raw payload mode sanitizes tools and binary content parts" do
    model = reasoning_model(:openai, "gpt-5")

    tool =
      ReqLLM.Tool.new!(
        name: "lookup_weather",
        description: "Fetches weather data",
        parameter_schema: [
          location: [type: :string, required: true]
        ],
        callback: fn _args -> {:ok, "sunny"} end
      )

    context = %ReqLLM.Context{
      messages: [
        %Message{
          role: :user,
          content: [
            ContentPart.text("hello"),
            ContentPart.image(<<1, 2, 3>>, "image/png"),
            ContentPart.file(<<"abc">>, "contract.txt", "text/plain"),
            ContentPart.thinking("secret request thought")
          ]
        }
      ],
      tools: [tool]
    }

    telemetry_context =
      model
      |> ReqLLM.Telemetry.new_context(
        [context: context, telemetry: [payloads: :raw], reasoning_effort: :high],
        operation: :chat
      )
      |> ReqLLM.Telemetry.start_request(%{"reasoning" => %{"effort" => "high"}})

    ReqLLM.Telemetry.stop_request(telemetry_context, response_with_reasoning(model.id))

    events = collect_events()
    start_meta = single_event_metadata(events, [:req_llm, :request, :start])
    stop_meta = single_event_metadata(events, [:req_llm, :request, :stop])

    [sanitized_tool] = start_meta.request_payload.tools
    [sanitized_message] = start_meta.request_payload.messages
    thinking_part = Enum.find(sanitized_message.content, &(&1.type == :thinking))
    image_part = Enum.find(sanitized_message.content, &(&1.type == :image))
    file_part = Enum.find(sanitized_message.content, &(&1.type == :file))

    response_thinking =
      Enum.find(stop_meta.response_payload.message.content, &(&1.type == :thinking))

    assert sanitized_tool.name == "lookup_weather"
    assert sanitized_tool.description == "Fetches weather data"
    assert sanitized_tool.strict == false
    assert sanitized_tool.parameter_schema[:location][:type] == :string
    assert sanitized_tool.parameter_schema[:location][:required] == true
    refute Map.has_key?(sanitized_tool, :callback)
    refute Map.has_key?(sanitized_tool, :compiled)

    assert image_part.bytes == 3
    assert image_part.media_type == "image/png"
    refute Map.has_key?(image_part, :data)

    assert file_part.bytes == 3
    assert file_part.filename == "contract.txt"
    refute Map.has_key?(file_part, :data)

    assert thinking_part.text == nil
    assert thinking_part.redacted? == true
    assert thinking_part.text_bytes > 0

    assert response_thinking.text == nil
    assert response_thinking.redacted? == true
    assert response_thinking.text_bytes > 0
  end

  test "raw payload mode summarizes binary and vector outputs" do
    embedding_model = %LLMDB.Model{provider: :openai, id: "text-embedding-3-small"}

    embedding_context =
      embedding_model
      |> ReqLLM.Telemetry.new_context(
        [text: ["hello"], telemetry: [payloads: :raw]],
        operation: :embedding
      )
      |> ReqLLM.Telemetry.start_request(%{"input" => ["hello"]})

    ReqLLM.Telemetry.stop_request(
      embedding_context,
      %Req.Response{status: 200, body: %{"data" => [%{"embedding" => [0.1, 0.2, 0.3]}]}}
    )

    speech_model = %LLMDB.Model{provider: :openai, id: "gpt-4o-mini-tts"}

    speech_context =
      speech_model
      |> ReqLLM.Telemetry.new_context(
        [text: "hello", voice: "alloy", telemetry: [payloads: :raw]],
        operation: :speech
      )
      |> ReqLLM.Telemetry.start_request(%{"input" => "hello"})

    ReqLLM.Telemetry.stop_request(
      speech_context,
      %ReqLLM.Speech.Result{
        audio: <<0, 1, 2, 3>>,
        media_type: "audio/mpeg",
        format: "mp3",
        duration_in_seconds: 1.25
      }
    )

    events = collect_events()
    embedding_stop = Enum.at(event_metadata(events, [:req_llm, :request, :stop]), 0)
    speech_stop = Enum.at(event_metadata(events, [:req_llm, :request, :stop]), 1)

    assert embedding_stop.response_payload == %{vector_count: 1, dimensions: 3}
    assert speech_stop.response_payload.audio_bytes == 4
    assert speech_stop.response_payload.media_type == "audio/mpeg"
    assert speech_stop.response_payload.format == "mp3"
    refute Map.has_key?(speech_stop.response_payload, :audio)
  end

  test "raw payload mode sanitizes opaque fallback payloads" do
    model = reasoning_model(:openai, "gpt-5")

    telemetry_context =
      model
      |> ReqLLM.Telemetry.new_context(
        [context: ReqLLM.Context.new([user("hello")]), telemetry: [payloads: :raw]],
        operation: :chat
      )
      |> ReqLLM.Telemetry.start_request(%{"reasoning" => %{"effort" => "high"}})

    ReqLLM.Telemetry.stop_request(
      telemetry_context,
      %Req.Response{
        status: 200,
        body: %{
          "raw" => <<255, 0>>,
          "nested" => [%{"blob" => <<254, 1>>}]
        }
      }
    )

    events = collect_events()
    stop_meta = single_event_metadata(events, [:req_llm, :request, :stop])

    assert stop_meta.response_payload["raw"] == %{bytes: 2}
    assert stop_meta.response_payload["nested"] == [%{"blob" => %{bytes: 2}}]
  end

  test "Req-backed public requests emit request summaries and raw payloads per request" do
    run_req_backed_request(telemetry: [payloads: :raw])

    events = collect_events()
    start_meta = single_event_metadata(events, [:req_llm, :request, :start])
    stop_meta = single_event_metadata(events, [:req_llm, :request, :stop])

    assert start_meta.request_summary.message_count == 1
    assert start_meta.request_summary.text_bytes == 5

    [request_message] = start_meta.request_payload.messages
    [request_part] = request_message.content

    assert request_message.role == :user
    assert request_part.type == :text
    assert request_part.text == "Hello"
    assert stop_meta.response_payload.message.role == :assistant
    assert Enum.any?(stop_meta.response_payload.message.content, &(&1.type == :text))
  end

  test "Req-backed public requests fall back to global raw payload config" do
    original_telemetry_config = Application.get_env(:req_llm, :telemetry)

    on_exit(fn ->
      restore_app_env(:req_llm, :telemetry, original_telemetry_config)
    end)

    Application.put_env(:req_llm, :telemetry, payloads: :raw)
    run_req_backed_request()

    events = collect_events()
    start_meta = single_event_metadata(events, [:req_llm, :request, :start])
    stop_meta = single_event_metadata(events, [:req_llm, :request, :stop])

    assert start_meta.request_summary.message_count == 1
    assert start_meta.request_summary.text_bytes == 5
    assert Map.has_key?(start_meta, :request_payload)
    assert Map.has_key?(stop_meta, :response_payload)
  end

  test "Req-backed retries emit one logical lifecycle" do
    model = reasoning_model(:openai, "gpt-5")

    usage = %{
      tokens: %{input: 10, output: 12, reasoning: 7},
      cost: nil
    }

    {:ok, counter} = Agent.start_link(fn -> 0 end)

    request =
      Req.new(url: "https://example.com", method: :post)
      |> Map.put(:body, Jason.encode!(%{"reasoning" => %{"effort" => "high"}}))
      |> Retry.attach(max_retries: 1)
      |> Telemetry.attach(
        model,
        [context: ReqLLM.Context.new([user("hello")]), reasoning_effort: :high],
        operation: :chat
      )
      |> Map.put(:adapter, fn req ->
        attempt = Agent.get_and_update(counter, fn current -> {current, current + 1} end)

        case attempt do
          0 ->
            {req, %Req.TransportError{reason: :closed}}

          _ ->
            {req,
             %Req.Response{
               status: 200,
               body: response_with_reasoning(model.id),
               private: %{req_llm: %{usage: usage}}
             }}
        end
      end)

    {_request, response} = Req.Request.run_request(request)
    assert %Req.Response{status: 200} = response

    events = collect_events()

    assert event_count(events, [:req_llm, :request, :start]) == 1
    assert event_count(events, [:req_llm, :request, :stop]) == 1
    assert event_count(events, [:req_llm, :reasoning, :start]) == 1
    assert event_count(events, [:req_llm, :reasoning, :stop]) == 1
    assert event_count(events, [:req_llm, :request, :exception]) == 0
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

  defp collect_events(acc \\ []) do
    receive do
      {:telemetry_event, name, measurements, metadata} ->
        collect_events([%{name: name, measurements: measurements, metadata: metadata} | acc])
    after
      10 -> Enum.reverse(acc)
    end
  end

  defp event_metadata(events, event_name) do
    events
    |> Enum.filter(&(&1.name == event_name))
    |> Enum.map(& &1.metadata)
  end

  defp single_event_metadata(events, event_name) do
    [metadata] = event_metadata(events, event_name)
    metadata
  end

  defp event_count(events, event_name) do
    events
    |> Enum.count(&(&1.name == event_name))
  end

  defp run_req_backed_request(opts \\ []) do
    model = ReqLLM.model!("openrouter:anthropic/claude-haiku-4.5")
    {:ok, provider} = ReqLLM.provider(model.provider)
    {:ok, request} = provider.prepare_request(:chat, model, "Hello", opts)

    request =
      Map.put(request, :adapter, fn req ->
        response =
          %Req.Response{
            status: 200,
            body: openai_format_json_fixture(model: model.id, content: "Hello back")
          }

        {req, response}
      end)

    {_request, response} = Req.Request.run_request(request)
    assert %Req.Response{status: 200, body: %Response{}} = response
    :ok
  end

  defp restore_app_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_app_env(app, key, value), do: Application.put_env(app, key, value)
end
