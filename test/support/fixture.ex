defmodule ReqLLM.Step.Fixture.Backend do
  @moduledoc """
  HTTP fixture recording & replay system for ReqLLM tests.

  Automatically handles LIVE vs REPLAY modes based on LIVE environment variable.
  Use via the fixture: option in ReqLLM.generate_text/3 and related functions.
  """

  require Logger

  # ---------------------------------------------------------------------------
  # Export for external chunk capture (used by streaming)
  # ---------------------------------------------------------------------------
  def capture_raw_chunk(path, chunk) when is_binary(chunk) do
    put_raw_chunk(path, chunk)
  end

  def save_streaming_fixture(%Req.Request{} = request, %Req.Response{} = response) do
    case request.private[:llm_fixture_path] do
      nil ->
        :ok

      path ->
        encode_info = capture_request_body(request)
        save_fixture(path, encode_info, request, response)
    end
  end

  @doc """
  Save streaming fixture using HTTPContext instead of Req.Request/Response.

  This version is used by the new Finch streaming pipeline which doesn't use
  Req.Request/Response structs but provides HTTPContext with minimal metadata.
  """
  def save_streaming_fixture(
        %ReqLLM.Streaming.Fixtures.HTTPContext{} = http_context,
        path,
        canonical_json,
        model
      ) do
    if path do
      encode_info = %{canonical_json: canonical_json}
      save_fixture_with_context(path, encode_info, http_context, model)
    else
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Main entry point – returns a Req request step (arity-1 function)
  # ---------------------------------------------------------------------------
  def step(_provider, fixture_name) do
    # Validate fixture name to prevent path traversal
    safe_fixture_name = Path.basename(fixture_name)

    if safe_fixture_name != fixture_name do
      raise ArgumentError, "fixture name cannot contain path separators: #{inspect(fixture_name)}"
    end

    fn request ->
      # Get model from request private data (set by provider attach)
      model = request.private[:req_llm_model]

      if !model do
        raise ArgumentError, "Model not found in request.private[:req_llm_model]"
      end

      path = ReqLLM.Test.FixturePath.file(model, safe_fixture_name)
      mode = ReqLLM.Test.Fixtures.mode()

      if debug?() do
        IO.puts(
          "[Fixture] step: model=#{model.provider}:#{model.model}, name=#{safe_fixture_name}"
        )

        IO.puts("[Fixture] path: #{Path.relative_to_cwd(path)}")
        IO.puts("[Fixture] mode: #{mode}, exists: #{File.exists?(path)}")
      end

      Logger.debug(
        "Fixture step: model=#{model.provider}:#{model.model}, name=#{safe_fixture_name}"
      )

      Logger.debug("Fixture path: #{path}")
      Logger.debug("Fixture mode: #{mode}")
      Logger.debug("Fixture exists: #{File.exists?(path)}")

      if live?() do
        debug?() && IO.puts("[Fixture] RECORD mode - will save to #{Path.relative_to_cwd(path)}")
        Logger.debug("Fixture RECORD mode - will save to #{Path.relative_to_cwd(path)}")
        # Tag the request and add response steps to capture the response
        request =
          request
          |> Req.Request.put_private(:llm_fixture_path, path)
          |> Req.Request.put_private(:llm_fixture_name, safe_fixture_name)

        Logger.debug("Fixture request tagged with path")

        # Insert a non-invasive tap step to capture RAW SSE bytes after decompression
        # but before our SSE parsing step. If we can't find the stream step, fall back
        # to placing before provider decode.
        request = insert_tap_step(request)

        # For streaming, fixture saving is handled in the :into callback completion
        # For non-streaming, save fixture BEFORE decoding to capture raw response
        if is_real_time_streaming?(request) do
          Logger.debug("Fixture streaming request - saving handled in callback")
          request
        else
          Logger.debug("Fixture non-streaming request - inserting save step")
          insert_save_step(request)
        end
      else
        Logger.debug("Fixture REPLAY mode - loading from #{Path.relative_to_cwd(path)}")
        # Short-circuit the pipeline with stubbed response
        {:ok, response} = handle_replay(path, model)
        Logger.debug("Fixture loaded successfully, status=#{response.status}")
        {request, response}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Mode helpers
  # ---------------------------------------------------------------------------
  defp live?, do: ReqLLM.Test.Env.fixtures_mode() == :record

  defp debug?, do: System.get_env("REQ_LLM_DEBUG") in ["1", "true"]

  defp is_real_time_streaming?(%Req.Request{} = request) do
    # Check if the request has a real-time stream stored (indicating streaming mode)
    request.private[:real_time_stream] != nil
  end

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
    start_key = {:llmfixture_start_time, path}

    # Initialize start time on first chunk
    start_time =
      case Process.get(start_key) do
        nil ->
          time = System.monotonic_time(:microsecond)
          Process.put(start_key, time)
          time

        time ->
          time
      end

    # Calculate timestamp relative to start
    timestamp_us = System.monotonic_time(:microsecond) - start_time

    current = Process.get(key) || []
    chunk_with_timing = %{bin: chunk, t_us: timestamp_us}
    Process.put(key, [chunk_with_timing | current])
  end

  # Insert our tap step just before the stream parsing step if present, otherwise
  # before provider decode. As a last resort, prepend.
  defp insert_tap_step(%Req.Request{} = req) do
    steps = req.response_steps
    tap = {:llm_fixture_tap, &tap_stream_response/1}

    cond do
      Enum.any?(steps, fn {name, _} -> name == :stream_sse end) ->
        {before_steps, after_steps} =
          Enum.split_while(steps, fn {name, _} -> name != :stream_sse end)

        %{req | response_steps: before_steps ++ [tap] ++ after_steps}

      Enum.any?(steps, fn {name, _} -> name == :llm_decode_response end) ->
        {before_steps, after_steps} =
          Enum.split_while(steps, fn {name, _} -> name != :llm_decode_response end)

        %{req | response_steps: before_steps ++ [tap] ++ after_steps}

      true ->
        Req.Request.prepend_response_steps(req, [tap])
    end
  end

  # Insert the save step before :llm_decode_response to capture raw response
  defp insert_save_step(%Req.Request{} = req) do
    steps = req.response_steps
    save = {:llm_fixture_save, &save_fixture_response/1}

    if Enum.any?(steps, fn {name, _} -> name == :llm_decode_response end) do
      {before_steps, after_steps} =
        Enum.split_while(steps, fn {name, _} -> name != :llm_decode_response end)

      %{req | response_steps: before_steps ++ [save] ++ after_steps}
    else
      # If no :llm_decode_response step, append at the end
      Req.Request.append_response_steps(req, [save])
    end
  end

  # ---------------------------------------------------------------------------
  # Replay branch
  # ---------------------------------------------------------------------------
  defp handle_replay(path, model) do
    if !File.exists?(path) do
      raise """
      Fixture not found: #{path}
      Run the test once with REQ_LLM_FIXTURES_MODE=record to capture it.
      """
    end

    case ReqLLM.Test.VCR.load(path) do
      {:ok, transcript} ->
        body =
          if ReqLLM.Test.VCR.streaming?(transcript) do
            provider_mod = provider_module(model.provider)
            ReqLLM.Test.VCR.replay_as_stream(transcript, provider_mod, model)
          else
            ReqLLM.Test.VCR.replay_response_body(transcript)
          end

        {:ok,
         %Req.Response{
           status: ReqLLM.Test.VCR.status(transcript),
           headers: ReqLLM.Test.VCR.headers(transcript),
           body: body
         }}

      {:error, _} ->
        raise """
        Failed to load Transcript fixture: #{path}
        The fixture may be in legacy format. Delete and regenerate with REQ_LLM_FIXTURES_MODE=record.
        """
    end
  end

  defp provider_module(:anthropic), do: ReqLLM.Providers.Anthropic
  defp provider_module(:openai), do: ReqLLM.Providers.OpenAI
  defp provider_module(:google), do: ReqLLM.Providers.Google
  defp provider_module(:groq), do: ReqLLM.Providers.Groq
  defp provider_module(:openrouter), do: ReqLLM.Providers.OpenRouter
  defp provider_module(:xai), do: ReqLLM.Providers.XAI

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
  defp capture_request_body(%Req.Request{} = request) do
    canonical_json =
      case request.private[:llm_canonical_json] do
        nil ->
          case request.body do
            {:json, json_map} -> json_map
            other when is_binary(other) -> Jason.decode!(other)
            other -> other
          end

        json_map ->
          json_map
      end

    %{canonical_json: canonical_json}
  end

  # ---------------------------------------------------------------------------
  # Record branch - Use VCR/Transcript format
  # ---------------------------------------------------------------------------
  defp save_fixture(path, encode_info, %Req.Request{} = req, %Req.Response{} = resp) do
    debug?() && IO.puts("[Fixture] Saving to #{Path.relative_to_cwd(path)}")
    Logger.debug("Fixture saving: path=#{Path.relative_to_cwd(path)}")

    # Check if we captured stream chunks (prefer raw tap capture)
    stream_chunks =
      case Process.delete({:llmfixture_raw_stream_chunks, path}) do
        nil -> Process.delete({:llmfixture_stream_chunks, path})
        raw when is_list(raw) -> Enum.reverse(raw)
      end

    debug?() &&
      IO.puts("[Fixture] Stream chunks: #{if stream_chunks, do: length(stream_chunks), else: 0}")

    Logger.debug("Fixture stream chunks: #{if stream_chunks, do: length(stream_chunks), else: 0}")

    # Get model from request private data
    model = req.private[:req_llm_model]
    model_spec = "#{model.provider}:#{model.model}"

    debug?() && IO.puts("[Fixture] Model: #{model_spec}")
    Logger.debug("Fixture model_spec: #{model_spec}")

    request_meta = %{
      method: to_string(req.method),
      url: URI.to_string(req.url),
      headers: mapify_headers(req.headers),
      canonical_json: encode_info.canonical_json
    }

    response_meta = %{
      status: resp.status,
      headers: mapify_headers(resp.headers)
    }

    Logger.debug("Fixture request: method=#{request_meta.method}, url=#{request_meta.url}")
    Logger.debug("Fixture response: status=#{response_meta.status}")

    if stream_chunks do
      # Use ChunkCollector for streaming
      {:ok, collector} = ReqLLM.Test.ChunkCollector.start_link()

      Enum.each(stream_chunks, fn chunk ->
        binary =
          case chunk do
            %{bin: bin} -> bin
            bin when is_binary(bin) -> bin
            other -> inspect(other)
          end

        ReqLLM.Test.ChunkCollector.add_chunk(collector, binary)
      end)

      Logger.debug("Fixture recording streaming response with collector")

      case ReqLLM.Test.VCR.record(path,
             provider: model.provider,
             model: model_spec,
             request: request_meta,
             response: response_meta,
             collector: collector
           ) do
        :ok ->
          debug?() &&
            IO.puts("[Fixture] Saved successfully (streaming) → #{Path.relative_to_cwd(path)}")

          Logger.debug("Fixture saved successfully → #{Path.relative_to_cwd(path)}")

        {:error, reason} ->
          debug?() && IO.puts("[Fixture] ERROR saving (streaming): #{inspect(reason)}")
          Logger.error("Fixture save failed: #{inspect(reason)}")
      end
    else
      # Non-streaming - encode body as JSON
      body = Jason.encode!(encode_body(resp.body))
      body_size = byte_size(body)

      Logger.debug("Fixture recording non-streaming response, body_size=#{body_size}")

      case ReqLLM.Test.VCR.record(path,
             provider: model.provider,
             model: model_spec,
             request: request_meta,
             response: response_meta,
             body: body
           ) do
        :ok ->
          debug?() &&
            IO.puts(
              "[Fixture] Saved successfully (non-streaming) → #{Path.relative_to_cwd(path)}"
            )

          Logger.debug("Fixture saved successfully → #{Path.relative_to_cwd(path)}")

        {:error, reason} ->
          debug?() && IO.puts("[Fixture] ERROR saving (non-streaming): #{inspect(reason)}")
          Logger.error("Fixture save failed: #{inspect(reason)}")
      end
    end
  end

  # HTTPContext version for Finch streaming pipeline - Use VCR/Transcript format
  defp save_fixture_with_context(
         path,
         encode_info,
         %ReqLLM.Streaming.Fixtures.HTTPContext{} = http_context,
         model
       ) do
    debug?() &&
      IO.puts("[Fixture] save_fixture_with_context called for #{Path.relative_to_cwd(path)}")

    # Check if we captured stream chunks (prefer raw tap capture)
    stream_chunks =
      case Process.delete({:llmfixture_raw_stream_chunks, path}) do
        nil ->
          debug?() && IO.puts("[Fixture] No raw stream chunks, checking regular chunks")
          Process.delete({:llmfixture_stream_chunks, path})

        raw when is_list(raw) ->
          debug?() && IO.puts("[Fixture] Found #{length(raw)} raw stream chunks")
          Enum.reverse(raw)
      end

    debug?() &&
      IO.puts(
        "[Fixture] stream_chunks: #{inspect(stream_chunks != nil)}, count: #{if stream_chunks, do: length(stream_chunks), else: 0}"
      )

    model_spec = "#{model.provider}:#{model.model}"

    request_meta = %{
      method: String.upcase(to_string(http_context.method)),
      url: http_context.url,
      headers: http_context.req_headers || %{},
      canonical_json: encode_info.canonical_json
    }

    # Convert headers to list format (VCR expects a list, not a map)
    headers =
      case http_context.resp_headers do
        h when is_map(h) -> Enum.to_list(h)
        h when is_list(h) -> h
        _ -> []
      end

    response_meta = %{
      status: http_context.status || 200,
      headers: headers
    }

    debug?() && IO.puts("[Fixture] response_meta: #{inspect(response_meta)}")

    if stream_chunks do
      # Use ChunkCollector for streaming
      debug?() &&
        IO.puts("[Fixture] Creating ChunkCollector for #{length(stream_chunks)} chunks")

      debug?() && IO.puts("[Fixture] First chunk: #{inspect(Enum.at(stream_chunks, 0))}")
      {:ok, collector} = ReqLLM.Test.ChunkCollector.start_link()

      Enum.each(stream_chunks, fn chunk ->
        binary =
          case chunk do
            %{bin: bin} -> bin
            bin when is_binary(bin) -> bin
            other -> inspect(other)
          end

        ReqLLM.Test.ChunkCollector.add_chunk(collector, binary)
      end)

      debug?() &&
        IO.puts(
          "[Fixture] Calling VCR.record for streaming fixture at #{Path.relative_to_cwd(path)}"
        )

      result =
        ReqLLM.Test.VCR.record(path,
          provider: model.provider,
          model: model_spec,
          request: request_meta,
          response: response_meta,
          collector: collector
        )

      debug?() && IO.puts("[Fixture] VCR.record result: #{inspect(result)}")
      result
    else
      # Non-streaming (though HTTPContext is usually for streaming)
      ReqLLM.Test.VCR.record(path,
        provider: model.provider,
        model: model_spec,
        request: request_meta,
        response: response_meta,
        body: ""
      )
    end

    Logger.debug("Saved Transcript fixture (HTTPContext) → #{Path.relative_to_cwd(path)}")
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

  # Body → JSON-friendly encoding
  defp encode_body(bin) when is_binary(bin), do: %{"b64" => Base.encode64(bin)}
  # JSON already
  defp encode_body(other), do: other
end
