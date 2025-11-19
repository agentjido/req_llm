defmodule SimpleAgent.Parser do
  @moduledoc """
  Helper functions for parsing streaming chunks from ReqLLM.

  This module extracts common patterns used across tutorial examples:
  - Extracting text content from streaming chunks
  - Reconstructing tool calls with JSON argument fragments
  - Normalizing response shapes from generate_text/3
  """

  @doc """
  Extracts all text content from streaming chunks.

  ## Examples

      chunks = [%{type: :content, text: "Hello"}, %{type: :content, text: " world"}]
      SimpleAgent.Parser.text_from_chunks(chunks)
      #=> "Hello world"

  """
  def text_from_chunks(chunks) do
    chunks
    |> Enum.reduce("", fn ch, acc ->
      if ch.type == :content and is_binary(ch.text), do: acc <> ch.text, else: acc
    end)
  end

  @doc """
  Extracts tool calls from streaming chunks and reconstructs JSON arguments.

  Tool calls arrive in chunks with:
  - `:tool_call` type chunks containing name and metadata
  - `:meta` type chunks with `tool_call_args.fragment` containing JSON pieces

  This function:
  1. Collects all tool_call chunks
  2. Groups JSON fragments by index
  3. Decodes complete JSON into arguments map

  ## Examples

      chunks = [
        %{type: :tool_call, name: "calculator", metadata: %{id: "call_123", index: 0}},
        %{type: :meta, metadata: %{tool_call_args: %{index: 0, fragment: "{\"expr"}}},
        %{type: :meta, metadata: %{tool_call_args: %{index: 0, fragment: "ession\":\"2+2\"}"}}
      ]
      SimpleAgent.Parser.tool_calls_from_chunks(chunks)
      #=> [%{id: "call_123", name: "calculator", arguments: %{"expression" => "2+2"}}]

  """
  def tool_calls_from_chunks(chunks) do
    calls =
      chunks
      |> Enum.filter(&(&1.type == :tool_call))
      |> Enum.map(fn ch ->
        %{
          id: Map.get(ch.metadata, :id) || "call_#{:erlang.unique_integer()}",
          name: ch.name,
          arguments: ch.arguments || %{},
          index: Map.get(ch.metadata, :index, 0)
        }
      end)

    arg_fragments =
      chunks
      |> Enum.filter(fn
        %{type: :meta, metadata: %{tool_call_args: _}} -> true
        _ -> false
      end)
      |> Enum.group_by(& &1.metadata.tool_call_args.index)
      |> Map.new(fn {idx, frags} ->
        json = Enum.map_join(frags, "", & &1.metadata.tool_call_args.fragment)
        {idx, json}
      end)

    Enum.map(calls, fn call ->
      case Map.get(arg_fragments, call.index) do
        nil ->
          Map.delete(call, :index)

        json ->
          case Jason.decode(json) do
            {:ok, m} -> call |> Map.put(:arguments, m) |> Map.delete(:index)
            _ -> Map.delete(call, :index)
          end
      end
    end)
  end

  @doc """
  Normalizes different response shapes from ReqLLM.generate_text/3.

  The API may return:
  - Response struct with nested message.content
  - Plain string
  - Other formats

  This function extracts the text consistently.

  ## Examples

      # Response struct format
      response = {:ok, %{message: %{content: [%{text: "Hello", type: :text}]}}}
      SimpleAgent.Parser.normalize_final_text(response)
      #=> {:ok, "Hello"}

      # Plain string format
      SimpleAgent.Parser.normalize_final_text({:ok, "Hello"})
      #=> {:ok, "Hello"}

      # Error passthrough
      SimpleAgent.Parser.normalize_final_text({:error, :timeout})
      #=> {:error, :timeout}

  """
  def normalize_final_text({:ok, %{message: %{content: [%{text: t, type: :text} | _]}}})
      when is_binary(t) do
    {:ok, t}
  end

  def normalize_final_text({:ok, t}) when is_binary(t), do: {:ok, t}
  def normalize_final_text(other), do: other
end
