defmodule ReqLLM.OpenTelemetry.Shared do
  @moduledoc false

  require Logger

  alias ReqLLM.OpenTelemetry.Attributes

  @langfuse_cost_attr "langfuse.observation.cost_details"

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
      case Attributes.cost_breakdown(metadata) do
        %{} = breakdown -> put_langfuse_cost(attributes, breakdown)
        _ -> attributes
      end
    else
      attributes
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
