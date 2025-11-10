# lib/req_llm/ontology/parser.ex
# Purpose: Lossless-enough JSON-LD → plain maps to rehydrate domain values for tests and adapters.

defmodule ReqLLM.Ontology.Parser do
  @moduledoc """
  Parses JSON-LD emitted by Emitter back into plain maps (struct-friendly).
  Designed for round-trip tests and adapter hooks.
  """

  @spec parse_response(map()) :: {:ok, map()} | {:error, term()}
  def parse_response(%{"@type" => "Response"} = ld) do
    out = %{
      id: ld["id"],
      context: parse_context(ld["hasContext"]),
      message: parse_message(ld["hasMessageOut"]),
      usage: parse_usage(ld["hasUsage"]),
      finish_reason: to_atom(ld["finishReason"])
    }

    {:ok, drop_nils(out)}
  end

  def parse_response(other), do: {:error, {:unexpected_type, other}}

  @spec parse_context(nil | map()) :: nil | map()
  def parse_context(nil), do: nil
  def parse_context(%{"@type" => "Context"} = ld) do
    %{
      external_id: ld["externalId"],
      messages: Enum.map(List.wrap(ld["hasMessage"] || []), &parse_message/1)
    }
    |> drop_nils()
  end

  @spec parse_message(nil | map()) :: nil | map()
  def parse_message(nil), do: nil
  def parse_message(%{"@type" => "Message"} = ld) do
    %{
      role: to_atom(ld["role"]),
      position: ld["position"],
      parts: Enum.map(List.wrap(ld["hasPart"] || []), &parse_part/1)
    }
    |> drop_nils()
  end

  @spec parse_part(map()) :: map()
  def parse_part(%{"@type" => "TextPart"} = ld), do: %{type: :TextPart, text: ld["text"]} |> drop_nils()
  def parse_part(%{"@type" => "ImageURLPart"} = ld), do: %{type: :ImageURLPart, url: ld["url"]} |> drop_nils()
  def parse_part(%{"@type" => "ImagePart"} = ld), do: %{type: :ImagePart, media_type: ld["mediaType"], payload: ld["payload"]} |> drop_nils()
  def parse_part(%{"@type" => "FilePart"} = ld), do: %{type: :FilePart, media_type: ld["mediaType"], payload: ld["payload"]} |> drop_nils()
  def parse_part(%{"@type" => "ThinkingPart"} = ld), do: %{type: :ThinkingPart, thinking: ld["thinkingText"]} |> drop_nils()
  def parse_part(%{"@type" => "ToolCallPart"} = ld), do: %{type: :ToolCallPart, tool_name: ld["toolName"], arguments_json: ld["argumentsJson"]} |> drop_nils()
  def parse_part(%{"@type" => "ToolResultPart"} = ld), do: %{type: :ToolResultPart, tool_call_id: ld["toolCallId"], result_json: ld["resultJson"]} |> drop_nils()

  @spec parse_usage(nil | map()) :: nil | map()
  def parse_usage(nil), do: nil
  def parse_usage(%{"@type" => "Usage"} = ld) do
    %{
      input_tokens: ld["inputTokens"],
      output_tokens: ld["outputTokens"],
      reasoning_tokens: ld["reasoningTokens"],
      total_tokens: ld["totalTokens"],
      input_cost: ld["inputCost"],
      output_cost: ld["outputCost"],
      total_cost: ld["totalCost"]
    }
    |> drop_nils()
  end

  # -- helpers
  defp to_atom(nil), do: nil
  defp to_atom(v) when is_atom(v), do: v
  defp to_atom(v) when is_binary(v) do
    try do
      String.to_existing_atom(v)
    rescue
      ArgumentError -> String.to_atom(v)
    end
  end

  defp drop_nils(map) do
    map |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()
  end
end
