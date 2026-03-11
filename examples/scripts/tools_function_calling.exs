#!/usr/bin/env elixir

alias ReqLLM.Scripts.Helpers

defmodule ToolsFunctionCalling do
  @moduledoc """
  Tools/Function Calling Demonstration

  Shows how to use ReqLLM.tool/1 to define tools and enable function calling.
  Demonstrates basic tool calling where the model decides which tools to invoke
  and the script executes them, displaying arguments and results.

  Note: This demonstrates single-round tool calling. For multi-turn conversations
  where tool results are fed back to the model for a final response, see
  tools_round_trip.exs which handles the full tool calling loop.

  ## Usage

      mix run lib/examples/scripts/tools_function_calling.exs [PROMPT]
      mix run lib/examples/scripts/tools_function_calling.exs --model anthropic:claude-sonnet-4-5-20250929 [PROMPT]

  ## Options

    * `--model`, `-m` - Model to use (default: openai:gpt-4o)
    * `--log-level`, `-l` - Log level: debug, info, warning, error (default: warning)
    * `--max-tokens` - Maximum tokens in response
    * `--temperature` - Temperature for sampling

  ## Examples

      # Default prompt with multiple tool calls
      mix run lib/examples/scripts/tools_function_calling.exs

      # Custom prompt
      mix run lib/examples/scripts/tools_function_calling.exs "What's the weather in Tokyo?"

      # Specific model
      mix run lib/examples/scripts/tools_function_calling.exs --model anthropic:claude-sonnet-4-5-20250929 "Get current time"
  """
  @script_name "tools_function_calling.exs"

  def run(argv) do
    Helpers.ensure_app!()

    {parsed_opts, remaining_args} =
      OptionParser.parse!(argv,
        strict: [
          model: :string,
          log_level: :string,
          max_tokens: :integer,
          temperature: :float
        ],
        aliases: [m: :model, l: :log_level]
      )

    prompt = get_prompt(parsed_opts, remaining_args)

    opts = Keyword.put(parsed_opts, :prompt, prompt)

    model = opts[:model] || Helpers.default_text_model()

    Logger.configure(level: Helpers.log_level(opts[:log_level] || "warning"))

    Helpers.banner!(@script_name, "Demonstrates tool/function calling",
      model: model,
      prompt: prompt,
      max_tokens: opts[:max_tokens],
      temperature: opts[:temperature]
    )

    tools = define_tools()

    ctx = Helpers.context(prompt)

    generation_opts = build_generation_opts(opts, tools)

    {response, duration_ms} =
      Helpers.time(fn ->
        case ReqLLM.generate_text(model, ctx, generation_opts) do
          {:ok, initial_response} ->
            handle_tool_calls(model, initial_response, tools, opts)

          error ->
            error
        end
      end)

    case response do
      {:ok, resp} ->
        display_response(resp, duration_ms)

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
        "What's the weather in Paris in Celsius? What time is it? Tell me a joke about programming."
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

  defp handle_tool_calls(_model, response, tools, _opts) do
    last_message = List.last(response.context.messages)

    tool_call_parts =
      last_message.content
      |> Enum.filter(fn part -> part.type == :tool_call end)

    if tool_call_parts != [] do
      IO.puts(IO.ANSI.yellow() <> "\nTool Calls Made:" <> IO.ANSI.reset())

      Enum.each(tool_call_parts, fn tool_call_part ->
        tool = Enum.find(tools, fn t -> t.name == tool_call_part.tool_name end)

        IO.puts("  • #{tool_call_part.tool_name}")
        IO.puts("    Arguments: #{inspect(tool_call_part.input)}")

        if tool do
          case ReqLLM.Tool.execute(tool, tool_call_part.input) do
            {:ok, result} ->
              IO.puts(IO.ANSI.cyan() <> "    Result: #{inspect(result)}" <> IO.ANSI.reset())

            {:error, error} ->
              IO.puts(IO.ANSI.red() <> "    Error: #{inspect(error)}" <> IO.ANSI.reset())
          end
        else
          IO.puts(IO.ANSI.red() <> "    Tool not found!" <> IO.ANSI.reset())
        end
      end)

      IO.puts("")
    end

    {:ok, response}
  end

  defp display_response(response, duration_ms) do
    text = ReqLLM.Response.text(response)

    if text && text != "" do
      IO.puts(IO.ANSI.green() <> "Assistant Response: " <> IO.ANSI.reset() <> text)
      IO.puts("")
    else
      IO.puts(
        IO.ANSI.faint() <>
          "(Model called tools but didn't provide text response)" <> IO.ANSI.reset()
      )

      IO.puts("")
    end

    Helpers.print_usage_and_timing(response.usage, duration_ms, [])
  end
end

ToolsFunctionCalling.run(System.argv())
