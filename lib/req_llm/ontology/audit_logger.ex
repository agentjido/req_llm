# lib/req_llm/ontology/audit_logger.ex
# Purpose: Audit trail persistence for compliance and debugging (KNHK phase)

defmodule ReqLLM.Ontology.AuditLogger do
  @moduledoc """
  Persistent audit trail for ontology events.

  Logs Usage metrics, FinishReasons, and StreamChunks to disk/database
  for compliance, debugging, and cost analysis.

  ## Storage

  By default, logs to `./audit_logs/` directory with daily rotation.
  Configure via:

  ```elixir
  config :req_llm, ReqLLM.Ontology.AuditLogger,
    enabled: true,
    log_dir: "./audit_logs",
    format: :jsonl  # or :csv
  ```

  ## Log Files

  - `usage_YYYY-MM-DD.jsonl` - Usage metrics
  - `finish_reasons_YYYY-MM-DD.jsonl` - Finish reasons
  - `stream_chunks_YYYY-MM-DD.jsonl` - Stream chunks (if enabled)
  - `validations_YYYY-MM-DD.jsonl` - Validation errors
  """

  require Logger

  @default_log_dir "./audit_logs"

  @doc """
  Log Usage metrics to audit trail.

  ## Fields
  - timestamp (ISO8601)
  - ontology_type ("req:Usage")
  - input_tokens, output_tokens, total_tokens
  - input_cost, output_cost, total_cost
  - provider, model
  - session_id (optional)
  """
  def log_usage(usage, opts \\ []) do
    if enabled?() do
      entry = %{
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
        ontology_type: "req:Usage",
        ontology_version: "2aeb94264b64",
        input_tokens: get_any(usage, [:input_tokens, :inputTokens], 0),
        output_tokens: get_any(usage, [:output_tokens, :outputTokens], 0),
        reasoning_tokens: get_any(usage, [:reasoning_tokens, :reasoningTokens], 0),
        total_tokens: get_any(usage, [:total_tokens, :totalTokens], 0),
        input_cost: get_any(usage, [:input_cost, :inputCost], 0.0),
        output_cost: get_any(usage, [:output_cost, :outputCost], 0.0),
        total_cost: get_any(usage, [:total_cost, :totalCost], 0.0),
        provider: Keyword.get(opts, :provider),
        model: Keyword.get(opts, :model),
        session_id: Keyword.get(opts, :session_id)
      }

      write_log("usage", entry)
    end

    :ok
  end

  @doc """
  Log FinishReason to audit trail for error monitoring.

  ## Fields
  - timestamp
  - finish_reason (:stop, :length, :tool_calls, :content_filter, :error)
  - provider, model
  - response_id (optional)
  """
  def log_finish_reason(finish_reason, opts \\ []) do
    if enabled?() do
      entry = %{
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
        ontology_type: "req:FinishReason",
        ontology_version: "2aeb94264b64",
        finish_reason: to_string(finish_reason),
        provider: Keyword.get(opts, :provider),
        model: Keyword.get(opts, :model),
        response_id: Keyword.get(opts, :response_id),
        session_id: Keyword.get(opts, :session_id)
      }

      write_log("finish_reasons", entry)
    end

    :ok
  end

  @doc """
  Log StreamChunk to audit trail (for compliance/debugging).

  ## Fields
  - timestamp
  - chunk_type (:content, :thinking, :tool_call, :meta)
  - chunk_text
  - chunk_index
  - session_id
  """
  def log_stream_chunk(chunk, index, opts \\ []) do
    if enabled?() and log_stream_chunks?() do
      entry = %{
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
        ontology_type: "req:StreamChunk",
        ontology_version: "2aeb94264b64",
        chunk_type: to_string(get_any(chunk, [:type, :chunk_type, :chunkType], "")),
        chunk_text: get_any(chunk, [:text, :delta, :content, :chunkText]),
        chunk_index: index,
        provider: Keyword.get(opts, :provider),
        session_id: Keyword.get(opts, :session_id)
      }

      write_log("stream_chunks", entry)
    end

    :ok
  end

  @doc """
  Log validation failure to audit trail.

  ## Fields
  - timestamp
  - ontology_type (type being validated)
  - validation_errors (list of error messages)
  - data_sample (truncated sample of invalid data)
  """
  def log_validation_error(type, errors, data \\ nil) do
    if enabled?() do
      entry = %{
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
        ontology_type: type,
        ontology_version: "2aeb94264b64",
        validation_errors: errors,
        error_count: length(errors),
        data_sample: truncate_sample(data)
      }

      write_log("validations", entry)
    end

    :ok
  end

  @doc """
  Read usage logs for a date range.

  Returns list of usage entries.
  """
  def read_usage_logs(from_date, to_date) do
    read_logs("usage", from_date, to_date)
  end

  @doc """
  Read finish reason logs for a date range.

  Returns list of finish reason entries.
  """
  def read_finish_reason_logs(from_date, to_date) do
    read_logs("finish_reasons", from_date, to_date)
  end

  @doc """
  Aggregate usage metrics for a date range.

  Returns summary:
  - total_requests
  - total_input_tokens
  - total_output_tokens
  - total_cost
  - by_provider breakdown
  - by_model breakdown
  """
  def aggregate_usage(from_date, to_date) do
    logs = read_usage_logs(from_date, to_date)

    summary = %{
      total_requests: length(logs),
      total_input_tokens: Enum.sum(Enum.map(logs, & &1["input_tokens"])),
      total_output_tokens: Enum.sum(Enum.map(logs, & &1["output_tokens"])),
      total_cost: Enum.sum(Enum.map(logs, & &1["total_cost"])),
      by_provider: aggregate_by_key(logs, "provider"),
      by_model: aggregate_by_key(logs, "model")
    }

    summary
  end

  @doc """
  Aggregate finish reasons for monitoring.

  Returns distribution of finish reasons:
  - stop: count
  - length: count
  - tool_calls: count
  - content_filter: count
  - error: count
  """
  def aggregate_finish_reasons(from_date, to_date) do
    logs = read_finish_reason_logs(from_date, to_date)

    logs
    |> Enum.group_by(& &1["finish_reason"])
    |> Enum.map(fn {reason, entries} -> {reason, length(entries)} end)
    |> Enum.into(%{})
  end

  # -- Private Helpers --

  defp enabled? do
    Application.get_env(:req_llm, __MODULE__, [])
    |> Keyword.get(:enabled, true)
  end

  defp log_stream_chunks? do
    Application.get_env(:req_llm, __MODULE__, [])
    |> Keyword.get(:log_stream_chunks, false)
  end

  defp log_dir do
    Application.get_env(:req_llm, __MODULE__, [])
    |> Keyword.get(:log_dir, @default_log_dir)
  end

  defp write_log(category, entry) do
    date = Date.utc_today() |> Date.to_string()
    filename = "#{category}_#{date}.jsonl"
    path = Path.join(log_dir(), filename)

    # Ensure log directory exists
    File.mkdir_p!(log_dir())

    # Append JSONL entry
    json = Jason.encode!(entry)
    File.write!(path, json <> "\n", [:append])
  rescue
    error ->
      Logger.warning("Failed to write audit log: #{inspect(error)}")
      :ok
  end

  defp read_logs(category, from_date, to_date) do
    from_date = Date.from_iso8601!(from_date)
    to_date = Date.from_iso8601!(to_date)

    date_range = Date.range(from_date, to_date)

    entries =
      for date <- date_range do
        date_str = Date.to_string(date)
        filename = "#{category}_#{date_str}.jsonl"
        path = Path.join(log_dir(), filename)

        if File.exists?(path) do
          path
          |> File.stream!()
          |> Stream.map(&Jason.decode!/1)
          |> Enum.to_list()
        else
          []
        end
      end
      |> List.flatten()

    entries
  end

  defp aggregate_by_key(logs, key) do
    logs
    |> Enum.group_by(& &1[key])
    |> Enum.map(fn {k, entries} ->
      {k,
       %{
         count: length(entries),
         total_tokens: Enum.sum(Enum.map(entries, & &1["total_tokens"])),
         total_cost: Enum.sum(Enum.map(entries, & &1["total_cost"]))
       }}
    end)
    |> Enum.into(%{})
  end

  defp truncate_sample(nil), do: nil

  defp truncate_sample(data) when is_binary(data) do
    String.slice(data, 0, 200)
  end

  defp truncate_sample(data) do
    inspect(data, limit: 50, pretty: true)
  end

  defp get_any(term, keys, default \\ nil) do
    data = to_map(term)
    Enum.find_value(keys, default, &Map.get(data, &1))
  end

  defp to_map(%_{} = struct), do: Map.from_struct(struct)
  defp to_map(map) when is_map(map), do: map
  defp to_map(_), do: %{}
end
