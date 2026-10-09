defmodule ReqLLM.Test.Billing.Live do
  @moduledoc false
  import ExUnit.Assertions

  alias ReqLLM.Test.Billing.{Audit, Reference, Run, Samples}

  @output_limit 512
  @padding String.duplicate("Ledger reference row alpha beta gamma delta epsilon. ", 1500)

  def run!(selection, dir) do
    Process.flag(:trap_exit, true)
    assert System.get_env("REQ_LLM_BILLING_MODE") == "record"
    assert ReqLLM.Test.Fixtures.mode() == :record
    assert System.get_env("REQ_LLM_FIXTURE_ALLOW_CREDENTIAL_FALLBACK") == "0"
    initial = initial_context(selection, dir)

    _final_context =
      Enum.reduce(selection["phases"], initial, fn phase, context ->
        request(selection, phase, context, dir)
      end)

    :ok
  end

  def estimate(selection, context) do
    model = ReqLLM.model!(selection["model"])
    rates = Reference.rates!(selection["model"])
    bytes = byte_size(Jason.encode!(Run.stringify(context))) + 8192
    max_context = model.limits[:context] || 1_050_000

    tokens =
      if selection["case_id"] == "hosted_web_search",
        do: max_context,
        else: min(bytes, max_context)

    input_rate =
      if model.provider == :anthropic,
        do: rates["cache_1h"],
        else: rates["cache_write"] || rates["input"]

    multiplier = if model.provider == :anthropic, do: rates["long_multiplier"] || "1", else: "4.4"
    tokens_charge = ReqLLM.Test.Billing.Money.micros(input_rate, tokens, 1_000_000, multiplier)

    output_charge =
      ReqLLM.Test.Billing.Money.micros(rates["output"], @output_limit, 1_000_000, multiplier)

    tools = if selection["case_id"] == "hosted_web_search", do: 10_000, else: 0
    tokens_charge + output_charge + tools + 1000
  end

  defp request(selection, phase, context, dir) do
    context = phase_context(selection, phase, context)

    attrs =
      Map.merge(selection, %{
        "phase" => phase,
        "expected_pricing" =>
          if(selection["case_id"] == "compact_unknown", do: "unknown", else: "priced")
      })

    attempt = Run.reserve!(dir, attrs, estimate(selection, context))
    opts = options(selection, phase, attempt)

    Run.append!(dir, "raw.jsonl", attempt, %{
      "kind" => "attempt_started",
      "origin" => "live",
      "captured_at" => Run.now()
    })

    try do
      {response, telemetry} =
        with_telemetry(fn -> invoke(selection, context, opts, dir, attempt) end)

      Run.append!(dir, "observed.jsonl", attempt, %{
        "kind" => "usage",
        "usage" => response.usage,
        "provider_reported_cost" => response.usage["cost"],
        "telemetry" => telemetry,
        "observation_origin" =>
          if(selection["case_id"] == "websocket_usage",
            do: "native_session_replay",
            else: "public_api"
          ),
        "provider_meta" => response.provider_meta,
        "response_id" => response.id
      })

      Run.update_attempt!(dir, attempt["attempt_id"], %{
        "state" => "complete",
        "finished_at" => Run.now()
      })

      captured = Run.attempt!(dir, attempt["attempt_id"])

      assert captured["capture_complete"] == true,
             "successful live request did not write a source capture"

      assert captured["capture_origin"] == "live", "live evidence cannot use an imported fixture"
      raw = Audit.safe_path!(dir, captured["transcript"]) |> File.read!() |> Jason.decode!()
      body = Reference.response_body(raw)
      reference = Reference.calculate(selection["model"], body, %{"url" => raw["request"]["url"]})

      assert reference["status"] == attrs["expected_pricing"],
             "selected billing facts were not confirmed: #{inspect(reference)}"

      if reference["status"] == "priced",
        do: Run.reconcile!(dir, attempt["attempt_id"], reference["total_micros"])

      assert Audit.check_attempt!(dir, captured)["status"] == "passed"
      assert length(telemetry) == 1, "expected exactly one terminal token-usage event"
      [event] = telemetry
      assert get_in(event, ["measurements", "cost"]) == response.usage[:total_cost]
      verify_case!(selection, phase, body, response)
      next_context(selection, phase, context, response)
    rescue
      error ->
        Run.update_attempt!(dir, attempt["attempt_id"], %{
          "state" => "failed",
          "finished_at" => Run.now(),
          "error_type" => inspect(error.__struct__)
        })

        Run.append!(dir, "raw.jsonl", attempt, %{
          "kind" => "attempt_failed",
          "error_type" => inspect(error.__struct__),
          "captured_at" => Run.now()
        })

        reraise error, __STACKTRACE__
    catch
      kind, reason ->
        Run.update_attempt!(dir, attempt["attempt_id"], %{
          "state" => "failed",
          "finished_at" => Run.now(),
          "error_type" => to_string(kind)
        })

        Run.append!(dir, "raw.jsonl", attempt, %{
          "kind" => "attempt_failed",
          "error_type" => to_string(kind),
          "captured_at" => Run.now()
        })

        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp with_telemetry(callback) do
    owner = self()
    ref = make_ref()

    :ok =
      :telemetry.attach(
        {__MODULE__, ref},
        [:req_llm, :token_usage],
        fn _name, measurements, metadata, _config ->
          send(owner, {:billing_usage, ref, measurements, metadata})
        end,
        nil
      )

    try do
      response = callback.()
      {response, telemetry_events(ref, [])}
    after
      :telemetry.detach({__MODULE__, ref})
    end
  end

  defp telemetry_events(ref, events) do
    receive do
      {:billing_usage, ^ref, measurements, metadata} ->
        telemetry_events(
          ref,
          events ++ [Run.stringify(%{measurements: measurements, metadata: metadata})]
        )
    after
      30 -> events
    end
  end

  defp options(selection, phase, attempt) do
    opts = [
      fixture: attempt["fixture"],
      max_tokens: @output_limit,
      max_retries: 0,
      receive_timeout: 180_000,
      total_timeout: 180_000,
      req_http_options: [retry: false],
      pricing_context: %{api: "chat", inference_geo: "global"}
    ]

    opts =
      if String.starts_with?(selection["model"], "openai:"),
        do:
          Keyword.merge(opts,
            reasoning_effort: :none,
            pricing_context: %{api: "batch", service_tier: "auto", regional_processing: true},
            provider_options: [
              service_tier:
                if(selection["case_id"] == "returned_service_tier", do: phase, else: "default")
            ]
          ),
        else: opts

    opts =
      if selection["case_id"] == "compact_unknown",
        do: Keyword.delete(opts, :pricing_context),
        else: opts

    case selection["case_id"] do
      "client_function" ->
        Keyword.merge(opts,
          tools: [echo_tool()],
          tool_choice:
            if(phase == "call",
              do: %{type: "function", function: %{name: "billing_echo"}},
              else: :none
            )
        )

      "hosted_web_search" ->
        opts
        |> Keyword.put(:tools, [%{"type" => "web_search"}])
        |> Keyword.put(:tool_choice, :required)
        |> Keyword.update!(:provider_options, &Keyword.put(&1, :openai_max_tool_calls, 1))

      _ ->
        opts
    end
  end

  defp invoke(%{"case_id" => "websocket_usage"} = selection, context, _opts, dir, attempt),
    do: websocket(selection, context, dir, attempt)

  defp invoke(%{"case_id" => "compact_unknown"} = selection, context, opts, _dir, _attempt) do
    {:ok, response} = ReqLLM.compact_context(selection["model"], context, opts)
    response
  end

  defp invoke(%{"mode" => "buffered"} = selection, context, opts, _dir, _attempt) do
    {:ok, response} = ReqLLM.generate_text(selection["model"], context, opts)
    response
  end

  defp invoke(selection, context, opts, _dir, _attempt) do
    {:ok, stream} = ReqLLM.stream_text(selection["model"], context, opts)
    {:ok, response} = ReqLLM.StreamResponse.to_response(stream)
    response
  end

  defp initial_context(selection, dir) do
    nonce = Run.load!(dir)["run_id"] <> ":" <> selection["case_id"] <> ":" <> selection["mode"]

    case selection["case_id"] do
      id when id in ~w(cache_5m cache_1h mixed_cache_ttl) ->
        ttl = if id == "cache_1h", do: "1h", else: "5m"
        first_ttl = if id == "mixed_cache_ttl", do: "1h", else: ttl
        parts = [cache_part(nonce <> " first\n" <> @padding, first_ttl)]

        parts =
          if id == "mixed_cache_ttl",
            do: parts ++ [cache_part(nonce <> " second\n" <> @padding, "5m")],
            else: parts

        ReqLLM.Context.new([
          ReqLLM.Context.system(parts),
          ReqLLM.Context.user("Reply with OK only.")
        ])

      "client_function" ->
        ReqLLM.Context.new([
          ReqLLM.Context.user(
            "Call billing_echo with value OK. After receiving the result, reply OK only."
          )
        ])

      "hosted_web_search" ->
        ReqLLM.Context.new([
          ReqLLM.Context.user(
            "Use web search exactly once to find the official Elixir language website. Reply with its URL only."
          )
        ])

      _ ->
        ReqLLM.Context.new([ReqLLM.Context.user("Reply OK only. Billing run " <> nonce)])
    end
  end

  defp cache_part(text, ttl),
    do: ReqLLM.Message.ContentPart.text(text, %{cache_control: %{type: "ephemeral", ttl: ttl}})

  defp phase_context(%{"case_id" => "long_context"}, phase, _context) do
    repetitions = if phase == "long", do: 40_000, else: 20_000

    ReqLLM.Context.new([
      ReqLLM.Context.user(
        String.duplicate("Ledger row alpha beta gamma delta epsilon.\n", repetitions) <>
          "\nReply OK only."
      )
    ])
  end

  defp phase_context(_, _, context), do: context

  def verify_case!(selection, phase, body, response) do
    verify_case_facts!(selection, phase, body, response)
    :ok
  end

  defp verify_case_facts!(%{"case_id" => id}, phase, body, response)
       when id in ~w(cache_5m cache_1h mixed_cache_ttl) do
    usage = body["usage"]

    if phase == "warm" do
      assert is_integer(usage["cache_read_input_tokens"]) and usage["cache_read_input_tokens"] > 0,
             "warm request did not establish a cache hit"
    else
      assert is_integer(usage["cache_creation_input_tokens"]) and
               usage["cache_creation_input_tokens"] > 0,
             "cold request did not establish a cache write"

      if id == "mixed_cache_ttl" do
        assert get_in(usage, ["cache_creation", "ephemeral_5m_input_tokens"]) > 0
        assert get_in(usage, ["cache_creation", "ephemeral_1h_input_tokens"]) > 0
        assert map_size(ReqLLM.Usage.normalize(response.usage).cache_write_tokens_by_ttl) == 2
      end
    end
  end

  defp verify_case_facts!(
         %{"case_id" => "long_context", "model" => model},
         phase,
         body,
         _response
       ) do
    usage = body["usage"]
    count = usage["input_tokens"] || usage["prompt_tokens"]
    threshold = Reference.rates!(model)["threshold"]

    assert count > threshold == (phase == "long"),
           "supplier token count did not reach the selected context band"
  end

  defp verify_case_facts!(%{"case_id" => "hosted_web_search"}, _phase, _body, response),
    do: assert(response.usage.tool_usage.web_search.count == 1)

  defp verify_case_facts!(%{"case_id" => "returned_service_tier"}, "flex", body, _response),
    do: assert(body["service_tier"] == "flex", "request did not establish a returned flex tier")

  defp verify_case_facts!(%{"case_id" => "client_function"}, "call", _body, response) do
    assert [%ReqLLM.ToolCall{}] = response.message.tool_calls
    assert response.usage.tool_usage == %{}
  end

  defp verify_case_facts!(_, _, _body, _response), do: :ok

  defp next_context(%{"case_id" => "client_function"}, "call", context, response) do
    calls = ReqLLM.Response.tool_calls(response)

    ReqLLM.Context.execute_and_append_tools(
      ReqLLM.Context.append(context, response.message),
      calls,
      [echo_tool()]
    )
  end

  defp next_context(_, _, context, _response), do: context

  defp echo_tool,
    do:
      ReqLLM.Tool.new!(
        name: "billing_echo",
        description: "Return the supplied test value locally.",
        parameter_schema: [value: [type: :string, required: true]],
        callback: fn args -> {:ok, args.value} end
      )

  defp websocket(selection, _context, dir, attempt) do
    model = ReqLLM.model!(selection["model"])

    payload = %{
      "input" => "Reply OK only.",
      "max_output_tokens" => @output_limit,
      "service_tier" => "default",
      "reasoning" => %{"effort" => "none"}
    }

    request =
      Map.merge(payload, %{
        "model" => model.provider_model_id || model.id,
        "type" => "response.create"
      })

    frames = [%{"direction" => "client", "event" => request}]

    Run.append!(dir, "raw.jsonl", attempt, %{
      "kind" => "request",
      "url" => "wss://api.openai.com/v1/responses",
      "body" => request
    })

    {:ok, session} = ReqLLM.OpenAI.Responses.connect(model, connect_timeout: 15_000)

    try do
      assert :ok = ReqLLM.OpenAI.Responses.response_create(session, payload)
      frames = websocket_events(session, frames, dir, attempt)

      raw = %{
        "format" => "responses_websocket_v1",
        "request" => %{"url" => "wss://api.openai.com/v1/responses"},
        "captured_at" => Run.now(),
        "frames" => frames
      }

      path = Path.join(dir, "transcripts/#{attempt["fixture"]}.json")
      File.write!(path, Jason.encode!(raw, pretty: true) <> "\n")

      Run.update_attempt!(dir, attempt["attempt_id"], %{
        "transcript" => Path.relative_to(path, dir),
        "transcript_sha256" => Run.hash(path),
        "capture_origin" => "live",
        "captured_at" => raw["captured_at"],
        "capture_complete" => true
      })

      sample = %{
        Samples.sample("websocket_usage", selection["model"])
        | body: Reference.response_body(raw)
      }

      Samples.buffered(sample)
    after
      ReqLLM.OpenAI.Responses.close(session)
    end
  end

  defp websocket_events(session, frames, dir, attempt) do
    {:ok, event} = ReqLLM.OpenAI.Responses.next_event(session, 180_000)

    Run.append!(dir, "stream_events.jsonl", attempt, %{
      "kind" => "websocket_event",
      "body" => event
    })

    assert event["type"] not in ["error", "response.failed", "response.incomplete"]
    frames = frames ++ [%{"direction" => "server", "event" => event}]

    if event["type"] == "response.completed",
      do: frames,
      else: websocket_events(session, frames, dir, attempt)
  end
end
