defmodule ReqLLM.Step.Fixture.Backend do
  @moduledoc """
  HTTP fixture recording & replay system for ReqLLM tests.

  Automatically handles LIVE vs REPLAY modes based on LIVE environment variable.
  Use via the fixture: option in ReqLLM.generate_text/3 and related functions.
  """

  import ReqLLM.Debug, only: [dbug: 2]

  require Logger

  @doc """
  Save streaming fixture using HTTPContext from Finch streaming pipeline.

  ## Parameters

    * `http_context` - HTTPContext with request/response metadata
    * `path` - Fixture file path
    * `canonical_json` - Request body JSON
    * `model` - ReqLLM.Model struct
    * `chunks` - List of raw binary chunks
  """
  def save_streaming_fixture(
        %ReqLLM.Streaming.Fixtures.HTTPContext{} = http_context,
        path,
        canonical_json,
        model,
        chunks
      ) do
    if path do
      encode_info = %{canonical_json: canonical_json}
      save_fixture_with_chunks(path, encode_info, http_context, model, chunks)
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

      mode = ReqLLM.Test.Fixtures.mode()
      path = fixture_path_for_mode(model, safe_fixture_name, mode)

      dbug(
        fn ->
          "[Fixture] step: model=#{model.provider}:#{model.provider_model_id || model.id}, name=#{safe_fixture_name}"
        end,
        component: :fixtures
      )

      dbug(fn -> "[Fixture] path: #{Path.relative_to_cwd(path)}" end, component: :fixtures)

      dbug(
        fn -> "[Fixture] mode: #{mode}, exists: #{File.exists?(path)}" end,
        component: :fixtures
      )

      Logger.debug(
        "Fixture step: model=#{model.provider}:#{model.provider_model_id || model.id}, name=#{safe_fixture_name}"
      )

      Logger.debug("Fixture path: #{path}")
      Logger.debug("Fixture mode: #{mode}")
      Logger.debug("Fixture exists: #{File.exists?(path)}")

      # Store fixture metadata for potential credential fallback
      request =
        request
        |> Req.Request.put_private(:llm_fixture_path, path)
        |> Req.Request.put_private(:llm_fixture_name, safe_fixture_name)
        |> Req.Request.put_private(:llm_fixture_model, model)
        |> maybe_put_fixture_canonical_json()

      if live?() do
        dbug(
          fn -> "[Fixture] RECORD mode - will save to #{Path.relative_to_cwd(path)}" end,
          component: :fixtures
        )

        Logger.debug("Fixture RECORD mode - will save to #{Path.relative_to_cwd(path)}")

        request = maybe_insert_credential_fallback_handler(request, path, model)

        # For streaming, fixture saving is handled in StreamServer callback
        # For non-streaming, save fixture BEFORE decoding to capture raw response
        if real_time_streaming?(request) do
          Logger.debug("Fixture streaming request - saving handled in StreamServer")
          request
        else
          Logger.debug("Fixture non-streaming request - inserting save step")
          insert_save_step(request)
        end
      else
        Logger.debug("Fixture REPLAY mode - loading from #{Path.relative_to_cwd(path)}")
        {:ok, response} = handle_replay(path, model)
        Logger.debug("Fixture loaded successfully, status=#{response.status}")

        request = Req.Request.put_private(request, :llm_fixture_replay, true)
        {request, response}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Mode helpers
  # ---------------------------------------------------------------------------
  defp live?, do: ReqLLM.Test.Env.fixtures_mode() == :record

  defp real_time_streaming?(%Req.Request{} = request) do
    request.private[:real_time_stream] != nil
  end

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
  @doc """
  Load a fixture file and return it as a Req.Response.

  This function is public to support credential fallback in generation.ex.
  """
  def handle_replay(path, model) do
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
           headers: req_response_headers(ReqLLM.Test.VCR.headers(transcript)),
           body: body
         }}

      {:error, _} ->
        raise """
        Failed to load Transcript fixture: #{path}
        Delete and regenerate with REQ_LLM_FIXTURES_MODE=record.
        """
    end
  end

  defp provider_module(provider), do: ReqLLM.Providers.get!(provider)

  defp req_response_headers(headers) do
    Map.new(headers, fn {key, value} ->
      {String.downcase(to_string(key)), List.wrap(value)}
    end)
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
  defp capture_request_body(%Req.Request{} = request) do
    canonical_json =
      case request.private[:llm_canonical_json] do
        nil ->
          capture_request_body_payload(request)

        json_map ->
          json_map
      end

    %{canonical_json: canonical_json}
  end

  defp capture_request_body_payload(%Req.Request{options: %{form_multipart: parts}})
       when is_list(parts) do
    Enum.map(parts, fn
      {key, {data, opts}} when is_binary(data) and is_list(opts) ->
        %{
          name: to_string(key),
          file: %{
            filename: Keyword.get(opts, :filename),
            content_type: Keyword.get(opts, :content_type),
            bytes: byte_size(data)
          }
        }

      {key, value} ->
        %{name: to_string(key), value: to_string(value)}
    end)
  end

  defp capture_request_body_payload(%Req.Request{body: {:json, json_map}}), do: json_map

  defp capture_request_body_payload(%Req.Request{body: body, headers: headers})
       when is_binary(body) do
    decode_request_body(body, headers)
  end

  defp capture_request_body_payload(%Req.Request{body: body, headers: headers})
       when is_list(body) do
    body
    |> IO.iodata_to_binary()
    |> decode_request_body(headers)
  end

  defp capture_request_body_payload(%Req.Request{body: body}), do: body

  defp decode_request_body(body, headers) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _error} -> non_json_request_body(body, headers)
    end
  end

  defp non_json_request_body(body, headers) do
    %{
      "_fixture_body" => "non_json",
      "byte_size" => byte_size(body),
      "content_type" => request_header(headers, "content-type")
    }
  end

  defp request_header(headers, target) do
    headers
    |> Enum.find_value(fn {key, value} ->
      if String.downcase(to_string(key)) == target do
        value |> List.wrap() |> Enum.join("; ")
      end
    end)
  end

  defp maybe_put_fixture_canonical_json(%Req.Request{private: private} = request) do
    if Map.has_key?(private, :llm_canonical_json) do
      request
    else
      Req.Request.put_private(request, :llm_canonical_json, capture_request_body_payload(request))
    end
  end

  # ---------------------------------------------------------------------------
  # Record branch - Use VCR/Transcript format (non-streaming only)
  # ---------------------------------------------------------------------------
  defp save_fixture(path, encode_info, %Req.Request{} = req, %Req.Response{} = resp) do
    dbug(fn -> "[Fixture] Saving to #{Path.relative_to_cwd(path)}" end, component: :fixtures)
    Logger.debug("Fixture saving: path=#{Path.relative_to_cwd(path)}")

    model = req.private[:req_llm_model]
    model_spec = "#{model.provider}:#{model.provider_model_id || model.id}"

    dbug(fn -> "[Fixture] Model: #{model_spec}" end, component: :fixtures)
    Logger.debug("Fixture model_spec: #{model_spec}")

    if streaming_response?(resp) and req.private[:real_time_stream] == nil do
      raise """
      Legacy streaming path detected in RECORD mode for #{path}
      This should not happen - all streaming should use :real_time_stream/StreamServer.
      If you see this, there's a code path that still uses Req SSE streaming.
      """
    end

    request_meta = %{
      method: to_string(req.method),
      url: URI.to_string(req.url),
      headers: mapify_headers(req.headers),
      canonical_json: encode_info.canonical_json
    }

    response_meta = %{
      status: resp.status,
      headers: resp.headers |> Enum.to_list()
    }

    Logger.debug("Fixture request: method=#{request_meta.method}, url=#{request_meta.url}")
    Logger.debug("Fixture response: status=#{response_meta.status}")

    body = Jason.encode!(encode_body(resp.body))
    body_size = byte_size(body)

    Logger.debug("Fixture recording non-streaming response, body_size=#{body_size}")

    result =
      try do
        ReqLLM.Test.VCR.record(path,
          provider: model.provider,
          model: model_spec,
          request: request_meta,
          response: response_meta,
          body: body
        )
      rescue
        e ->
          Logger.error("VCR.record exception: #{Exception.format(:error, e, __STACKTRACE__)}")
          reraise e, __STACKTRACE__
      end

    case result do
      :ok ->
        dbug(
          fn ->
            "[Fixture] Saved successfully (non-streaming) → #{Path.relative_to_cwd(path)}"
          end,
          component: :fixtures
        )

        Logger.debug("Fixture saved successfully → #{Path.relative_to_cwd(path)}")

      {:error, reason} ->
        dbug(
          fn -> "[Fixture] ERROR saving (non-streaming): #{inspect(reason)}" end,
          component: :fixtures
        )

        case reason do
          %FunctionClauseError{} = e ->
            Logger.error("FunctionClauseError in VCR.record: #{Exception.message(e)}")
            Logger.error("Module: #{e.module}, Function: #{e.function}, Arity: #{e.arity}")

          _ ->
            Logger.error("Fixture save failed: #{inspect(reason)}")
        end

        raise "Fixture save failed for #{Path.relative_to_cwd(path)}: #{inspect(reason)}"
    end
  end

  defp save_fixture_with_chunks(
         path,
         encode_info,
         %ReqLLM.Streaming.Fixtures.HTTPContext{} = http_context,
         model,
         chunks
       )
       when is_list(chunks) do
    model_spec = "#{model.provider}:#{model.provider_model_id || model.id}"

    request_meta = %{
      method: String.upcase(to_string(http_context.method)),
      url: http_context.url,
      headers: http_context.req_headers || %{},
      canonical_json: encode_info.canonical_json
    }

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

    if chunks in [nil, []] do
      raise "Fixture save failed for #{Path.relative_to_cwd(path)}: no chunks provided"
    else
      {:ok, collector} = ReqLLM.Test.ChunkCollector.start_link()

      Enum.each(chunks, fn chunk ->
        binary = if is_binary(chunk), do: chunk, else: inspect(chunk)
        ReqLLM.Test.ChunkCollector.add_chunk(collector, binary)
      end)

      case ReqLLM.Test.VCR.record(path,
             provider: model.provider,
             model: model_spec,
             request: request_meta,
             response: response_meta,
             collector: collector
           ) do
        :ok ->
          dbug(
            fn -> "[Fixture] Saved successfully (streaming) → #{Path.relative_to_cwd(path)}" end,
            component: :fixtures
          )

          Logger.debug("Saved Transcript fixture (chunks) → #{Path.relative_to_cwd(path)}")

        {:error, reason} ->
          dbug(fn -> "[Fixture] ERROR saving: #{inspect(reason)}" end, component: :fixtures)
          Logger.error("Fixture save failed: #{inspect(reason)}")
          raise "Fixture save failed for #{Path.relative_to_cwd(path)}: #{inspect(reason)}"
      end
    end
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
      "x-amz-security-token",
      "anthropic-api-key",
      "openai-api-key",
      "x-auth-token",
      "bearer",
      "api-key",
      "access-token",
      "cookie",
      "set-cookie",
      "anthropic-organization-id",
      "openai-organization"
    ]

    Enum.reduce(headers, %{}, fn {key, value}, acc ->
      normalized_key = String.downcase(to_string(key))

      sanitized_value =
        if normalized_key in sensitive_keys, do: ["[REDACTED:#{normalized_key}]"], else: value

      Map.put(acc, key, sanitized_value)
    end)
  end

  # Body → JSON-friendly encoding
  defp encode_body(bin) when is_binary(bin), do: %{"b64" => Base.encode64(bin)}
  # JSON already
  defp encode_body(other), do: other

  # ---------------------------------------------------------------------------
  # Credential fallback handler
  # ---------------------------------------------------------------------------
  defp fixture_path_for_mode(model, fixture_name, :record) do
    ReqLLM.Test.Fixtures.capture_path(model, fixture: fixture_name) ||
      ReqLLM.Test.FixturePath.file(model, fixture_name)
  end

  defp fixture_path_for_mode(model, fixture_name, _mode) do
    ReqLLM.Test.FixturePath.file(model, fixture_name)
  end

  defp maybe_insert_credential_fallback_handler(request, fixture_path, model) do
    if credential_fallback_allowed?() do
      insert_credential_fallback_handler(request, fixture_path, model)
    else
      request
    end
  end

  defp credential_fallback_allowed? do
    System.get_env("REQ_LLM_FIXTURE_ALLOW_CREDENTIAL_FALLBACK") in ~w(1 true yes on)
  end

  defp insert_credential_fallback_handler(request, fixture_path, model) do
    # Add an error handler that catches credential errors and falls back to fixture
    Req.Request.prepend_error_steps(request,
      llm_credential_fallback: fn {request, exception} ->
        handle_credential_error(request, exception, fixture_path, model)
      end
    )
  end

  defp handle_credential_error(request, exception, fixture_path, model) do
    # Get provider module to check if this is a credential error
    provider_id = model.provider
    {:ok, provider_module} = ReqLLM.Providers.get(provider_id)

    is_credential_error =
      function_exported?(provider_module, :credential_missing?, 1) and
        provider_module.credential_missing?(exception)

    fixture_exists = File.exists?(fixture_path)

    if is_credential_error and fixture_exists do
      # Log warning and fall back to fixture
      require Logger

      Logger.warning("""
      Credentials missing for #{provider_id}:#{model.model} during fixture recording.
      Falling back to existing fixture: #{Path.relative_to_cwd(fixture_path)}
      """)

      # Load fixture and return as if we succeeded
      {:ok, response} = handle_replay(fixture_path, model)
      # Return success - this stops error propagation
      {request, response}
    else
      # Not a credential error or no fixture - propagate error
      {request, exception}
    end
  end
end
