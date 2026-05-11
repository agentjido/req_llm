defmodule ReqLLM.OpenTelemetry.Shared do
  @moduledoc """
  Cross-cutting helpers shared by `ReqLLM.OpenTelemetry` and
  `ReqLLM.Telemetry.OpenTelemetry` — option parsing, Langfuse cost-details
  merging, error rendering.

  Both surfaces accept the same `:content` and `:langfuse` options and need
  to render error values the same way. This module is where that small but
  easy-to-drift logic lives.

  `content_mode/1` resolves the user-facing option to a canonical mode:

      content_mode(content: :attributes)  #=> :attributes
      content_mode(content: true)         #=> :attributes
      content_mode(content: :event)       #=> :event
      content_mode([])                    #=> :none

  `merge_langfuse/3` adds `"langfuse.observation.cost_details"` (a
  JSON-encoded `input`/`output`/`reasoning`/`total` breakdown) to an
  attribute map when `langfuse: true` is set and ReqLLM has cost data. If
  encoding fails it logs at debug and drops the attribute rather than
  raising — span emission keeps working.
  """

  require Logger

  alias ReqLLM.OpenTelemetry.Attributes

  @langfuse_cost_attr "langfuse.observation.cost_details"
  @langfuse_completion_start_attr "langfuse.observation.completion_start_time"

  @type content_mode :: :none | :attributes | :event

  @doc """
  Resolves the `:content` option to one of `:none | :attributes | :event`.

  Accepts `true` as an alias for `:attributes` and `false` (or anything
  unrecognized) as an alias for `:none`.
  """
  @spec content_mode(keyword()) :: content_mode()
  def content_mode(opts) do
    case Keyword.get(opts, :content, :none) do
      :attributes -> :attributes
      :event -> :event
      :none -> :none
      true -> :attributes
      false -> :none
      _ -> :none
    end
  end

  @doc """
  Merges `langfuse.observation.cost_details` into `attributes` when
  `langfuse: true` is set in `opts` and ReqLLM has a cost breakdown.
  """
  @spec merge_langfuse(map(), map(), keyword()) :: map()
  def merge_langfuse(attributes, metadata, opts) do
    if Keyword.get(opts, :langfuse, false) do
      attributes
      |> maybe_merge_cost(metadata)
      |> maybe_merge_completion_start_time(metadata)
    else
      attributes
    end
  end

  defp maybe_merge_cost(attributes, metadata) do
    case Attributes.cost_breakdown(metadata) do
      %{} = breakdown -> put_langfuse_cost(attributes, breakdown)
      _ -> attributes
    end
  end

  defp maybe_merge_completion_start_time(attributes, metadata) do
    case completion_start_time_iso(metadata) do
      iso when is_binary(iso) ->
        Map.put(attributes, @langfuse_completion_start_attr, iso)

      _ ->
        attributes
    end
  end

  defp completion_start_time_iso(metadata) do
    with %{first_chunk_at: first_chunk_at, time_to_first_chunk: ttfc}
         when is_integer(first_chunk_at) and is_integer(ttfc) <-
           Map.get(metadata, :streaming) || %{},
         start_system_time when is_integer(start_system_time) <-
           Map.get(metadata, :request_started_system_time) do
      first_chunk_microseconds =
        start_system_time
        |> System.convert_time_unit(:native, :microsecond)
        |> Kernel.+(System.convert_time_unit(ttfc, :native, :microsecond))

      DateTime.from_unix!(first_chunk_microseconds, :microsecond)
      |> DateTime.to_iso8601()
    else
      _ -> nil
    end
  end

  @doc """
  Renders an error value into a span-status / exception-event message string.
  """
  @spec error_message(any()) :: String.t() | nil
  def error_message(nil), do: nil
  def error_message(%{__exception__: true} = error), do: Exception.message(error)
  def error_message(error) when is_binary(error), do: error
  def error_message(error) when is_atom(error), do: Atom.to_string(error)
  def error_message(error), do: inspect(error)

  defp put_langfuse_cost(attributes, breakdown) do
    case Jason.encode(breakdown) do
      {:ok, json} ->
        Map.put(attributes, @langfuse_cost_attr, json)

      {:error, reason} ->
        Logger.debug(fn ->
          "ReqLLM.OpenTelemetry: dropping #{@langfuse_cost_attr} — " <>
            "Jason.encode failed: #{inspect(reason)}"
        end)

        attributes
    end
  end
end
