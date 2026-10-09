defmodule ReqLLM.Test.Billing.Capture do
  @moduledoc false

  alias ReqLLM.Test.Billing.{Reference, Run}

  def buffered_response({request, response}) do
    path = request.private[:llm_fixture_path]

    if path && not File.exists?(path) do
      model = request.private[:req_llm_model]
      raw = if is_binary(response.body), do: response.body, else: Jason.encode!(response.body)

      :ok =
        ReqLLM.Test.VCR.record(path,
          provider: model.provider,
          model: "#{model.provider}:#{model.provider_model_id || model.id}",
          request: %{
            method: to_string(request.method),
            url: URI.to_string(request.url),
            headers: request.headers,
            canonical_json: request.private[:llm_canonical_json] || %{}
          },
          response: %{status: response.status, headers: Enum.to_list(response.headers)},
          body: raw
        )
    end

    {request, response}
  end

  def buffered_started(path, request) do
    case System.get_env("REQ_LLM_BILLING_RUN") do
      nil ->
        :ok

      dir ->
        if attempt = Run.fixture_attempt(dir, path) do
          Run.append!(dir, "raw.jsonl", attempt, %{
            "kind" => "request_started",
            "captured_at" => Run.now(),
            "body" => request.private[:llm_canonical_json],
            "headers" => request.headers,
            "url" => URI.to_string(request.url),
            "method" => to_string(request.method)
          })
        end

        :ok
    end
  end

  def notify(path, transcript) do
    case System.get_env("REQ_LLM_BILLING_RUN") do
      nil ->
        :ok

      dir ->
        if attempt = Run.fixture_attempt(dir, path), do: export!(dir, attempt, path, transcript)
        :ok
    end
  end

  def export!(dir, attempt, path, transcript) do
    raw = File.read!(path) |> Jason.decode!()
    request = raw["request"] || %{}
    capture_time = raw["captured_at"]
    raw_request = request["canonical_json"] || %{}

    Run.append!(dir, "raw.jsonl", attempt, %{
      "kind" => "request",
      "body" => raw_request,
      "url" => request["url"],
      "method" => request["method"],
      "headers" => request["headers"],
      "captured_at" => capture_time,
      "representation" => "provider_json"
    })

    Run.append!(dir, "raw.jsonl", attempt, %{
      "kind" => "response",
      "body" => Reference.response_body(raw),
      "status" => raw["response"]["status"],
      "headers" => raw["response"]["headers"],
      "captured_at" => capture_time,
      "representation" =>
        if(raw["streaming"], do: "assembled_provider_events", else: "provider_json")
    })

    if raw["streaming"] do
      transcript
      |> ReqLLM.Test.Transcript.data_chunks()
      |> Enum.with_index()
      |> Enum.each(fn {chunk, index} ->
        Run.append!(dir, "stream_events.jsonl", attempt, %{
          "kind" => "chunk",
          "sequence" => index,
          "payload_b64" => Base.encode64(chunk),
          "events" => Reference.sse_events(chunk)
        })
      end)

      transcript
      |> ReqLLM.Test.Transcript.joined_data()
      |> Reference.sse_events()
      |> Enum.each(fn event ->
        Run.append!(dir, "stream_events.jsonl", attempt, %{
          "kind" => "provider_event",
          "body" => event
        })
      end)
    end

    origin = if is_nil(capture_time), do: "legacy", else: Run.load!(dir)["origin"]
    relative = Path.relative_to(path, dir)

    Run.update_attempt!(dir, attempt["attempt_id"], %{
      "transcript" => relative,
      "transcript_sha256" => Run.hash(path),
      "capture_origin" => origin,
      "captured_at" => capture_time,
      "capture_complete" => true,
      "request" => %{"url" => request["url"], "body" => raw_request}
    })
  end

  def observe_stream(path, context, request, event) do
    case System.get_env("REQ_LLM_BILLING_RUN") do
      nil ->
        :ok

      dir ->
        if attempt = Run.fixture_attempt(dir, path) do
          observer_event(dir, attempt, context, request, event)
        end

        :ok
    end
  end

  defp observer_event(dir, attempt, context, request, :request) do
    Run.append!(dir, "raw.jsonl", attempt, %{
      "kind" => "request_started",
      "url" => context.url,
      "body" => request,
      "headers" => context.req_headers,
      "captured_at" => Run.now()
    })
  end

  defp observer_event(dir, attempt, _context, _request, {:data, bytes}) do
    sequence =
      Run.records(dir, "stream_events.jsonl")
      |> Enum.count(&(&1["attempt_id"] == attempt["attempt_id"]))

    Run.append!(dir, "stream_events.jsonl", attempt, %{
      "kind" => "wire_chunk",
      "sequence" => sequence,
      "payload_b64" => Base.encode64(bytes),
      "captured_at" => Run.now()
    })
  end

  defp observer_event(dir, attempt, _context, _request, event) do
    Run.append!(dir, "raw.jsonl", attempt, %{
      "kind" => "transport_event",
      "event" => safe_event(event),
      "captured_at" => Run.now()
    })
  end

  defp safe_event({:error, %module{}}), do: %{"error_type" => inspect(module)}
  defp safe_event({:headers, headers}), do: %{"headers" => Map.new(headers)}

  defp safe_event({:error, reason}) when is_atom(reason),
    do: %{"error_type" => Atom.to_string(reason)}

  defp safe_event({:error, _}), do: %{"error_type" => "transport_error"}
  defp safe_event(event), do: Run.stringify(event)
end
