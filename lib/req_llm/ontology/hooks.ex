# lib/req_llm/ontology/hooks.ex
# Purpose: Runtime decorators and hooks for ontology-aware functions (KNHK phase)

defmodule ReqLLM.Ontology.Hooks do
  @moduledoc """
  Runtime decorators and hooks for ontology-tagged functions.

  Automatically instruments functions with telemetry, validation,
  and audit logging based on ontology metadata.

  ## Usage

  ```elixir
  defmodule MyModule do
    use ReqLLM.Ontology.Hooks

    @ontology_hook response: "req:Response", validate: true, audit: true
    def generate_response(context) do
      # ... implementation
      response
    end
  end
  ```

  This automatically:
  - Validates input/output against SHACL constraints
  - Emits telemetry events with RDF metadata
  - Logs to audit trail
  - Tracks ontology coverage
  """

  alias ReqLLM.Ontology.{Validator, Telemetry, AuditLogger}

  @doc """
  Hook for Response generation.

  Wraps a function that returns a Response with:
  - Validation
  - Telemetry emission
  - Audit logging
  """
  defmacro with_response_hook(opts \\ [], do: block) do
    quote do
      start_time = System.monotonic_time(:millisecond)
      validate? = Keyword.get(unquote(opts), :validate, true)
      audit? = Keyword.get(unquote(opts), :audit, true)

      result = unquote(block)

      case result do
        {:ok, response} ->
          duration = System.monotonic_time(:millisecond) - start_time

          # Validate if enabled
          if validate? do
            case Validator.validate_response(response) do
              :ok ->
                :ok

              {:error, errors} ->
                Telemetry.emit_validation_result("req:Response", {:error, errors})
                AuditLogger.log_validation_error("req:Response", errors, response)
            end
          end

          # Emit telemetry
          Telemetry.emit_response_complete(response,
            duration_ms: duration,
            provider: Keyword.get(unquote(opts), :provider),
            model: Keyword.get(unquote(opts), :model)
          )

          # Audit logging
          if audit? do
            usage = get_in(response, [Access.key(:usage)]) || get_in(response, [Access.key(:stats)])
            finish_reason = get_in(response, [Access.key(:finish_reason)]) || get_in(response, [Access.key(:finishReason)])

            if usage do
              AuditLogger.log_usage(usage,
                provider: Keyword.get(unquote(opts), :provider),
                model: Keyword.get(unquote(opts), :model),
                session_id: Keyword.get(unquote(opts), :session_id)
              )
            end

            if finish_reason do
              AuditLogger.log_finish_reason(finish_reason,
                provider: Keyword.get(unquote(opts), :provider),
                model: Keyword.get(unquote(opts), :model),
                response_id: get_in(response, [Access.key(:id)]),
                session_id: Keyword.get(unquote(opts), :session_id)
              )
            end
          end

          {:ok, response}

        other ->
          other
      end
    end
  end

  @doc """
  Hook for StreamChunk processing.

  Wraps streaming logic with chunk-level telemetry and audit logging.
  """
  defmacro with_stream_hook(chunk, index, opts \\ [], do: block) do
    quote do
      audit? = Keyword.get(unquote(opts), :audit, false)

      # Emit telemetry for chunk
      Telemetry.emit_stream_chunk(unquote(chunk), unquote(index),
        provider: Keyword.get(unquote(opts), :provider)
      )

      # Log to audit trail if enabled
      if audit? do
        AuditLogger.log_stream_chunk(unquote(chunk), unquote(index),
          provider: Keyword.get(unquote(opts), :provider),
          session_id: Keyword.get(unquote(opts), :session_id)
        )
      end

      unquote(block)
    end
  end

  @doc """
  Hook for validation operations.

  Automatically emits validation telemetry.
  """
  defmacro with_validation_hook(type, data, do: block) do
    quote do
      result = unquote(block)

      Telemetry.emit_validation_result(unquote(type), result)

      case result do
        {:error, errors} ->
          AuditLogger.log_validation_error(unquote(type), errors, unquote(data))

        :ok ->
          :ok
      end

      result
    end
  end
end
