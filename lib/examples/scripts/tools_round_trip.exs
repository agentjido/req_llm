#!/usr/bin/env elixir

alias ReqLLM.Scripts.Helpers

defmodule ToolsRoundTrip do
  @moduledoc """
  Multi-Turn Tool Calling Demonstration

  Shows the full round-trip loop of tool calling with ReqLLM:
  1. Model responds with tool calls
  2. Tools are executed and results collected
  3. Tool results are appended to context
  4. Process repeats until model provides final answer or max rounds reached

  ## Usage

      mix run lib/examples/scripts/tools_round_trip.exs [PROMPT]
      mix run lib/examples/scripts/tools_round_trip.exs --model anthropic:claude-sonnet-4-5-20250929 [PROMPT]
      mix run lib/examples/scripts/tools_round_trip.exs --max-rounds 5 "What's the weather in Paris?"

  ## Options

    * `--model`, `-m` - Model to use (default: openai:gpt-4o)
    * `--log-level`, `-l` - Log level: debug, info, warning, error (default: warning)
    * `--max-tokens` - Maximum tokens in response
    * `--temperature` - Temperature for sampling
    * `--max-rounds` - Maximum tool calling rounds (default: 3)

  ## Examples

      # Default complex multi-step prompt
      mix run lib/examples/scripts/tools_round_trip.exs

      # Custom prompt with multiple tool calls
      mix run lib/examples/scripts/tools_round_trip.exs "Check time, get Paris weather, tell weather joke"

      # Specific model with more rounds
      mix run lib/examples/scripts/tools_round_trip.exs --model anthropic:claude-sonnet-4-5-20250929 --max-rounds 5
  """
  @script_name "tools_round_trip.exs"
  @default_max_rounds 3

  def run(argv) do
    Helpers.ensure_app!()

    {parsed_opts, remaining_args} =
      OptionParser.parse!(argv,
        strict: [
          model: :string,
          log_level: :string,
          max_tokens: :integer,
          temperature: :float,
          max_rounds: :integer
        ],
        aliases: [m: :model, l: :log_level]
      )

    prompt = get_prompt(parsed_opts, remaining_args)
    opts = Keyword.put(parsed_opts, :prompt, prompt)
    model = opts[:model] || Helpers.default_text_model()
    max_rounds = opts[:max_rounds] || @default_max_rounds

    Logger.configure(level: Helpers.log_level(opts[:log_level] || "warning"))

    banner_opts =
      [
        model: model,
        prompt: prompt,
        max_rounds: max_rounds
      ]
      |> Helpers.maybe_add(:max_tokens, opts[:max_tokens])
      |> Helpers.maybe_add(:temperature, opts[:temperature])

    Helpers.banner!(@script_name, "Demonstrates multi-turn tool calling loop", banner_opts)

    tools = define_tools()
    ctx = Helpers.context(prompt)
    generation_opts = build_generation_opts(opts, tools)

    {final_response, duration_ms} =
      Helpers.time(fn ->
        tool_calling_loop(model, ctx, generation_opts, tools, max_rounds)
      end)

    case final_response do
      {:ok, resp} ->
        display_final_response(resp, duration_ms)

      {:error, error} ->
        raise error
    end
  rescue
    error -> Helpers.handle_error!(error, @script_name, [])
  end

  defp get_prompt(opts, remaining_args) do
    cond do
      opts[:prompt] ->
        opts[:prompt]

      not Enum.empty?(remaining_args) ->
        List.first(remaining_args)

      true ->
        "First, check what the current time is. Then, get the weather in Paris using Celsius. Finally, based on the time and weather, tell me an appropriate joke (use the time to decide if it should be a morning joke or evening joke, and use the weather to make it weather-related)."
    end
  end

  defp define_tools do
    weather_tool =
      ReqLLM.tool(
        name: "get_weather",
        description: "Get the current weather for a location",
        parameter_schema: [
          location: [type: :string, required: true, doc: "City name or location"],
          unit: [
            type: :string,
            default: "fahrenheit",
            doc: "Temperature unit (celsius or fahrenheit)"
          ]
        ],
        callback: fn args ->
          location = args["location"] || args[:location]
          unit = args["unit"] || args[:unit] || "fahrenheit"
          temp = if unit == "celsius", do: "22°C", else: "72°F"
          {:ok, "The weather in #{location} is #{temp}, sunny with clear skies."}
        end
      )

    joke_tool =
      ReqLLM.tool(
        name: "tell_joke",
        description: "Tell a joke, optionally about a specific topic",
        parameter_schema: [
          topic: [type: :string, default: "general", doc: "Topic for the joke (optional)"]
        ],
        callback: fn args ->
          topic = args["topic"] || args[:topic] || "general"

          jokes = %{
            "programming" => "Why do programmers prefer dark mode? Because light attracts bugs!",
            "general" => "Why don't scientists trust atoms? Because they make up everything!"
          }

          joke = Map.get(jokes, topic, jokes["general"])
          {:ok, joke}
        end
      )

    time_tool =
      ReqLLM.tool(
        name: "get_time",
        description: "Get the current time",
        parameter_schema: [],
        callback: fn _args ->
          time = DateTime.utc_now() |> DateTime.to_string()
          {:ok, "The current UTC time is #{time}"}
        end
      )

    [weather_tool, joke_tool, time_tool]
  end

  defp build_generation_opts(opts, tools) do
    []
    |> Helpers.maybe_put(:max_tokens, opts[:max_tokens])
    |> Helpers.maybe_put(:temperature, opts[:temperature])
    |> Keyword.put(:tools, tools)
  end

  defp tool_calling_loop(model, ctx, generation_opts, tools, max_rounds, round \\ 1) do
    IO.puts(IO.ANSI.blue() <> "\n=== Round #{round} ===" <> IO.ANSI.reset())

    case ReqLLM.generate_text(model, ctx, generation_opts) do
      {:ok, response} ->
        tool_calls = ReqLLM.Response.tool_calls(response)

        if tool_calls == [] do
          IO.puts(
            IO.ANSI.green() <> "No more tool calls - final answer received" <> IO.ANSI.reset()
          )

          {:ok, response}
        else
          if round >= max_rounds do
            IO.puts(
              IO.ANSI.yellow() <>
                "\nMax rounds (#{max_rounds}) reached - stopping loop" <> IO.ANSI.reset()
            )

            {:ok, response}
          else
            display_tool_calls(tool_calls)

            updated_ctx = execute_tools_and_append(response.context, tool_calls, tools)

            tool_calling_loop(model, updated_ctx, generation_opts, tools, max_rounds, round + 1)
          end
        end

      {:error, _} = error ->
        error
    end
  end

  defp display_tool_calls(tool_calls) do
    IO.puts(IO.ANSI.yellow() <> "\nTool Calls:" <> IO.ANSI.reset())

    Enum.each(tool_calls, fn call ->
      {name, id, args} = extract_tool_call_fields(call)
      IO.puts("  • #{name}")
      IO.puts("    ID: #{id}")
      IO.puts("    Args: #{inspect(args)}")
    end)
  end

  defp execute_tools_and_append(context, tool_calls, tools) do
    IO.puts(IO.ANSI.cyan() <> "\nExecuting Tools:" <> IO.ANSI.reset())

    Enum.reduce(tool_calls, context, fn tool_call, ctx ->
      {name, id, args} = extract_tool_call_fields(tool_call)
      tool = Enum.find(tools, fn t -> t.name == name end)

      if tool do
        case ReqLLM.Tool.execute(tool, args) do
          {:ok, result} ->
            IO.puts("  ✓ #{name}: #{inspect(result)}")

            result_str = if is_binary(result), do: result, else: Jason.encode!(result)
            tool_result_msg = ReqLLM.Context.tool_result(id, name, result_str)
            ReqLLM.Context.append(ctx, tool_result_msg)

          {:error, error} ->
            IO.puts(
              IO.ANSI.red() <>
                "  ✗ #{name}: Error - #{inspect(error)}" <> IO.ANSI.reset()
            )

            tool_result_msg =
              ReqLLM.Context.tool_result(id, name, "Error: #{inspect(error)}")

            ReqLLM.Context.append(ctx, tool_result_msg)
        end
      else
        IO.puts(IO.ANSI.red() <> "  ✗ #{name}: Tool not found!" <> IO.ANSI.reset())

        tool_result_msg = ReqLLM.Context.tool_result(id, name, "Error: Tool not found")
        ReqLLM.Context.append(ctx, tool_result_msg)
      end
    end)
  end

  defp extract_tool_call_fields(%ReqLLM.ToolCall{id: id, function: function}) do
    args =
      case Jason.decode(function.arguments) do
        {:ok, decoded} -> decoded
        _ -> function.arguments
      end

    {function.name, id, args}
  end

  defp extract_tool_call_fields(%{name: name, id: id, arguments: arguments}) do
    {name, id, arguments}
  end

  defp display_final_response(response, duration_ms) do
    IO.puts(IO.ANSI.blue() <> "\n=== Final Response ===" <> IO.ANSI.reset())

    text = ReqLLM.Response.text(response)

    if text && text != "" do
      IO.puts(IO.ANSI.green() <> "\nAssistant: " <> IO.ANSI.reset() <> text)
    else
      IO.puts(
        IO.ANSI.faint() <>
          "\n(No text response - only tool calls)" <> IO.ANSI.reset()
      )
    end

    IO.puts("")
    Helpers.print_usage_and_timing(response.usage, duration_ms, [])
  end
end

ToolsRoundTrip.run(System.argv())
