defmodule LLMFixture do
  @moduledoc """
  HTTP fixture recording & replay system for ReqLLM tests.

  Automatically handles LIVE vs REPLAY modes based on LIVE environment variable.
  Use via the fixture: option in ReqLLM.generate_text/3 and related functions.
  """

  require Logger

  # ---------------------------------------------------------------------------
  # Main entry point – returns a Req request step (arity-1 function)
  # ---------------------------------------------------------------------------
  def step(provider, fixture_name) do
    # Validate fixture name to prevent path traversal
    safe_fixture_name = Path.basename(fixture_name)

    if safe_fixture_name != fixture_name do
      raise ArgumentError, "fixture name cannot contain path separators: #{inspect(fixture_name)}"
    end

    fn request ->
      path = fixture_path(provider, safe_fixture_name)
      Logger.debug("LLMFixture intercepted request for #{provider}/#{safe_fixture_name}")

      if live?() do
        Logger.debug("LLMFixture: LIVE mode - tagging request for recording")
        # Tag the request and add response steps to capture the response
        request =
          request
          |> Req.Request.put_private(:llm_fixture_path, path)
          |> Req.Request.put_private(:llm_fixture_provider, provider)
          |> Req.Request.put_private(:llm_fixture_name, safe_fixture_name)

        # Insert a non-invasive tap step to capture RAW SSE bytes after decompression
        # but before our SSE parsing step. If we can't find the stream step, fall back
        # to placing before provider decode.
        request = insert_tap_step(request)

        # Save fixture at the end after all provider decoding is done
        request
        |> Req.Request.append_response_steps(llm_fixture_save: &save_fixture_response/1)
      else
        Logger.debug("LLMFixture: REPLAY mode")
        # Short-circuit the pipeline with stubbed response
        {:ok, response} = handle_replay(path)
        {request, response}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Mode helpers
  # ---------------------------------------------------------------------------
  defp live?, do: System.get_env("LIVE") in ~w(1 true TRUE)

  # ---------------------------------------------------------------------------
  # Streaming helpers
  # ---------------------------------------------------------------------------
  defp streaming_response?(%Req.Response{headers: headers, body: body}) do
    content_type_streaming =
      Enum.any?(headers, fn {k, v} ->
        k_lower = String.downcase(k)
        v_string = if is_list(v), do: Enum.join(v, "; "), else: v
        k_lower == "content-type" and String.contains?(v_string, "text/event-stream")
      end)

    body_streaming = match?(%Stream{}, body) or is_function(body)

    content_type_streaming or body_streaming
  end

  # Tap the raw SSE stream (post-decompression) and tee chunks into Process dict
  defp tap_stream_response({%Req.Request{} = req, %Req.Response{} = resp}) do
    path = req.private[:llm_fixture_path]

    if streaming_response?(resp) and is_binary_header_content_type?(resp, "text/event-stream") do
      body = resp.body

      cond do
        is_binary(body) ->
          put_raw_chunk(path, body)
          {req, resp}

        match?(%Stream{}, body) ->
          tapped =
            body
            |> Stream.transform(nil, fn chunk, acc ->
              if is_binary(chunk), do: put_raw_chunk(path, chunk)
              {[chunk], acc}
            end)

          {req, %{resp | body: tapped}}

        true ->
          {req, resp}
      end
    else
      {req, resp}
    end
  end

  defp is_binary_header_content_type?(%Req.Response{} = resp, value) do
    case Req.Response.get_header(resp, "content-type") do
      [ct | _] when is_binary(ct) -> String.contains?(ct, value)
      _ -> false
    end
  end

  defp put_raw_chunk(path, chunk) when is_binary(chunk) do
    key = {:llmfixture_raw_stream_chunks, path}
    current = Process.get(key) || []
    Process.put(key, [chunk | current])
  end

  # Insert our tap step just before the stream parsing step if present, otherwise
  # before provider decode. As a last resort, prepend.
  defp insert_tap_step(%Req.Request{} = req) do
    steps = req.response_steps
    tap = {:llm_fixture_tap, &tap_stream_response/1}

    cond do
      Enum.any?(steps, fn {name, _} -> name == :stream_sse end) ->
        {before_steps, after_steps} = Enum.split_while(steps, fn {name, _} -> name != :stream_sse end)
        %{req | response_steps: before_steps ++ [tap] ++ after_steps}

      Enum.any?(steps, fn {name, _} -> name == :llm_decode_response end) ->
        {before_steps, after_steps} = Enum.split_while(steps, fn {name, _} -> name != :llm_decode_response end)
        %{req | response_steps: before_steps ++ [tap] ++ after_steps}

      true ->
        Req.Request.prepend_response_steps(req, [tap])
    end
  end

  # ---------------------------------------------------------------------------
  # Replay branch
  # ---------------------------------------------------------------------------
  defp handle_replay(path) do
    if !File.exists?(path) do
      raise """
      Fixture not found: #{path}
      Run the test once with LIVE=true to capture it.
      """
    end

    fixture_data = path |> File.read!() |> Jason.decode!()
    resp = fixture_data["response"]

    body =
      case fixture_data["chunks"] do
        nil ->
          # Regular non-streaming response
          decode_body(resp["body"])

        chunks when is_list(chunks) ->
          # For streaming responses, we need to reconstruct the raw SSE stream
          # that would have been returned by the HTTP response.
          # The Step.Stream module will then parse this into structured chunks.
          raw_sse_data =
            chunks
            |> Enum.map(fn chunk ->
                 case chunk do
                   %{"b64" => b64_data} -> decode_body(%{"b64" => b64_data})
                   other -> inspect(other)
                 end
               end)
            |> Enum.join("")

          # Return the raw SSE data as binary for Step.Stream to process
          raw_sse_data
      end

    {:ok, %Req.Response{
      status: resp["status"], 
      headers: resp["headers"],
      body: body
    }}
  end

  # ---------------------------------------------------------------------------
  # Response step for saving fixtures in LIVE mode
  # ---------------------------------------------------------------------------
  defp save_fixture_response({request, response}) do
    case request.private[:llm_fixture_path] do
      nil ->
        {request, response}

      path ->
        encode_info = capture_request_body(request)

        # Do not consume the stream here; our tap step has already captured raw chunks
        save_fixture(path, encode_info, request, response)
        {request, response}
    end
  end

  # ---------------------------------------------------------------------------
  # Request capture helpers
  # ---------------------------------------------------------------------------
  defp capture_request_body(%Req.Request{body: body}) do
    case body do
      {:json, json_map} ->
        %{canonical_json: json_map}

      other ->
        %{canonical_json: other}
    end
  end

  # ---------------------------------------------------------------------------
  # Record branch - Updated to handle 4-arity
  # ---------------------------------------------------------------------------
  defp save_fixture(path, encode_info, %Req.Request{} = req, %Req.Response{} = resp) do
    File.mkdir_p!(Path.dirname(path))

    # Check if we captured stream chunks (prefer raw tap capture)
    stream_chunks =
      case Process.delete({:llmfixture_raw_stream_chunks, path}) do
        nil -> Process.delete({:llmfixture_stream_chunks, path})
        raw when is_list(raw) -> Enum.reverse(raw)
      end

    response_data = %{
      status: resp.status,
      headers: mapify_headers(resp.headers),
      body: if(!stream_chunks, do: encode_body(resp.body))
    }

    data = %{
      captured_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      request: %{
        method: req.method,
        url: URI.to_string(req.url),
        headers: mapify_headers(req.headers),
        canonical_json: sanitize_json(encode_info.canonical_json),
        body: encode_body(req.body)
      },
      response: response_data
    }

    # Add chunks field if we have stream data
    data =
      if stream_chunks do
        chunks =
          Enum.map(stream_chunks, fn chunk ->
            # For streaming chunks, we want to preserve the raw binary data
            encoded = 
              cond do
                is_binary(chunk) -> %{"b64" => Base.encode64(chunk)}
                true -> encode_body(chunk)
              end
            
            decoded = if is_binary(chunk), do: chunk, else: inspect(chunk)
            Map.merge(encoded, %{"decoded" => decoded})
          end)

        Map.put(data, "chunks", chunks)
      else
        data
      end

    File.write!(path, Jason.encode!(data, pretty: true))
    Logger.debug("Saved HTTP fixture → #{Path.relative_to_cwd(path)}")
  end

  # ---------------------------------------------------------------------------
  # (De)serialisation helpers
  # ---------------------------------------------------------------------------
  # Always keep headers as map for readability, sanitizing sensitive data
  defp mapify_headers(headers) do
    headers
    |> Map.new(fn {k, v} -> {k, v} end)
    |> sanitize_headers()
  end

  # Remove sensitive headers that might contain API keys or secrets
  defp sanitize_headers(headers) do
    sensitive_keys = [
      "authorization",
      "x-api-key",
      "anthropic-api-key",
      "openai-api-key",
      "x-auth-token",
      "bearer",
      "api-key",
      "access-token"
    ]

    Enum.reduce(sensitive_keys, headers, fn key, acc ->
      case Map.get(acc, key) do
        nil -> acc
        _value -> Map.put(acc, key, ["[REDACTED:#{key}]"])
      end
    end)
  end

  # Sanitize sensitive fields from JSON data (prompts, API keys, etc.)
  # For string JSON, try to decode and sanitize, falling back to regex replacement
  defp sanitize_json(data) when is_binary(data) do
    data
    |> Jason.decode!()
    |> sanitize_json_data()
    |> Jason.encode!()
  rescue
    _ -> sanitize_json_string(data)
  end

  defp sanitize_json(data), do: sanitize_json_data(data)

  # Sanitize JSON data structure
  defp sanitize_json_data(data) when is_map(data) do
    sensitive_keys = ["api_key", "access_token", "password", "secret", "authorization", "bearer"]

    Enum.reduce(data, %{}, fn {key, value}, acc ->
      key_str = to_string(key) |> String.downcase()

      new_value =
        if Enum.any?(sensitive_keys, &String.contains?(key_str, &1)) do
          "[REDACTED:#{key}]"
        else
          sanitize_json_data(value)
        end

      Map.put(acc, key, new_value)
    end)
  end

  defp sanitize_json_data(data) when is_list(data) do
    Enum.map(data, &sanitize_json_data/1)
  end

  defp sanitize_json_data(data), do: data

  # Fallback regex-based sanitization for string JSON
  defp sanitize_json_string(data) do
    data
    |> String.replace(~r/"api_key"\s*:\s*"[^"]*"/i, ~s/"api_key":"[REDACTED:api_key]"/)
    |> String.replace(
      ~r/"access_token"\s*:\s*"[^"]*"/i,
      ~s/"access_token":"[REDACTED:access_token]"/
    )
    |> String.replace(~r/"password"\s*:\s*"[^"]*"/i, ~s/"password":"[REDACTED:password]"/)
  end



  # Body → JSON-friendly encoding
  defp encode_body(%{__struct__: _} = body), do: inspect(body)
  defp encode_body(bin) when is_binary(bin), do: %{"b64" => Base.encode64(bin)}
  # JSON already
  defp encode_body(other), do: other

  # Reverse of the above
  defp decode_body(%{"b64" => b64}), do: Base.decode64!(b64)
  defp decode_body(other), do: other

  # ---------------------------------------------------------------------------
  # Path helper
  # ---------------------------------------------------------------------------
  defp fixture_path(provider, name),
    do: Path.join([__DIR__, "fixtures", to_string(provider), "#{name}.json"])
end
