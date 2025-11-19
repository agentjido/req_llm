defmodule SimpleAgent.Helpers do
  alias ReqLLM.{Context, Tool}
  import ReqLLM.Context

  def system_prompt do
    """
    You are a helpful assistant with access to tools.

    - When a user asks a math question or expression, use the calculator tool with the "expression" parameter.
    - Provide only valid JSON for tool arguments; do not add extra text in the arguments.
    - After tool results are provided, give a concise final answer.
    """
  end

  def calculator_tool do
    Tool.new!(
      name: "calculator",
      description: "Safely evaluate a mathematical expression string. Example: {\"expression\":\"(2+3)*7\"}",
      parameter_schema: [
        expression: [type: :string, required: true, doc: "Math expression to evaluate"]
      ],
      callback: fn
        %{expression: expr} when is_binary(expr) -> eval_expression(expr)
        %{"expression" => expr} when is_binary(expr) -> eval_expression(expr)
        args -> {:error, "Expected %{expression: string}. Got: #{inspect(args)}"}
      end
    )
  end

  def stream_with_tools(model, context, tools, opts \\ []) do
    case ReqLLM.stream_text(model, context.messages, Keyword.merge([tools: tools], opts)) do
      {:ok, stream_response} ->
        chunks = Enum.to_list(stream_response.stream)

        Enum.each(chunks, fn ch ->
          if ch.type == :content and is_binary(ch.text), do: IO.write(ch.text)
        end)

        IO.write("\n")

        {:ok, %{
          assistant_text: extract_text(chunks),
          tool_calls: extract_tool_calls(chunks)
        }}

      error -> error
    end
  end

  def execute_tools(context, tools, tool_calls) do
    Enum.reduce(tool_calls, context, fn call, ctx ->
      case Enum.find(tools, &(&1.name == call.name)) do
        %Tool{} = tool ->
          case Tool.execute(tool, call.arguments) do
            {:ok, result} ->
              IO.puts("[tool] #{call.name}(#{inspect(call.arguments)}) -> #{inspect(result)}")
              Context.append(ctx, tool_result_message(call.name, call.id, result))

            {:error, reason} ->
              error_str = if is_binary(reason), do: reason, else: inspect(reason)
              IO.puts("[error] #{call.name} error: #{error_str}")
              Context.append(ctx, tool_result_message(call.name, call.id, %{error: error_str}))
          end

        nil ->
          IO.puts("[error] Tool not found: #{call.name}")
          ctx
      end
    end)
  end

  def finalize(model, context, opts \\ []) do
    case ReqLLM.generate_text(model, context.messages, opts) do
      {:ok, %{message: %{content: [%{text: t, type: :text} | _]}}} when is_binary(t) -> {:ok, t}
      {:ok, t} when is_binary(t) -> {:ok, t}
      other -> other
    end
  end

  def extract_text(chunks) do
    chunks
    |> Enum.reduce("", fn ch, acc ->
      if ch.type == :content and is_binary(ch.text), do: acc <> ch.text, else: acc
    end)
  end

  def extract_tool_calls(chunks) do
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
        nil -> Map.delete(call, :index)
        json ->
          case Jason.decode(json) do
            {:ok, m} -> call |> Map.put(:arguments, m) |> Map.delete(:index)
            _ -> Map.delete(call, :index)
          end
      end
    end)
  end

  defp eval_expression(expr) do
    case Abacus.eval(expr) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, "Invalid expression: #{inspect(reason)}"}
    end
  end
end
