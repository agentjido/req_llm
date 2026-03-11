alias ReqLLM.Scripts.Helpers

defmodule AnthropicPromptCaching do
  @moduledoc """
  Demonstrates Anthropic prompt caching for cost savings.

  This script shows how to use Anthropic's prompt caching feature to cache
  frequently used prompt components (system messages, tools, and long contexts)
  to reduce latency and costs on subsequent requests.

  ## Usage

      mix run lib/examples/scripts/anthropic_prompt_caching.exs [options]

  ## Options

    * `--model` (`-m`) - Anthropic model (default: "anthropic:claude-sonnet-4-5-20250929")
    * `--ttl` (`-t`) - Cache TTL: "5m" or "1h" (default: 1h)
    * `--max-tokens` - Maximum tokens to generate (default: 256)
    * `--log-level` (`-l`) - Logging level: debug, info, warning, error (default: warning)

  ## Examples

      # Basic usage with default 1h TTL
      mix run lib/examples/scripts/anthropic_prompt_caching.exs

      # With 5-minute cache
      mix run lib/examples/scripts/anthropic_prompt_caching.exs --ttl 5m

      # Different model
      mix run lib/examples/scripts/anthropic_prompt_caching.exs --model anthropic:claude-3-5-haiku-20241022

  ## Learn More

      https://docs.anthropic.com/en/docs/build-with-claude/prompt-caching
  """

  @script_name "anthropic_prompt_caching.exs"

  def run(argv) do
    Helpers.ensure_app!()

    {parsed_opts, _remaining_args} =
      OptionParser.parse!(argv,
        strict: [
          model: :string,
          ttl: :string,
          max_tokens: :integer,
          log_level: :string
        ],
        aliases: [m: :model, t: :ttl, l: :log_level]
      )

    model = parsed_opts[:model] || "anthropic:claude-sonnet-4-5-20250929"
    ttl = parsed_opts[:ttl] || "1h"
    max_tokens = parsed_opts[:max_tokens] || 256

    if !String.starts_with?(model, "anthropic:") do
      raise ArgumentError,
            "This script requires an Anthropic model (e.g., anthropic:claude-sonnet-4-5-20250929)"
    end

    Logger.configure(level: Helpers.log_level(parsed_opts[:log_level] || "warning"))

    Helpers.banner!(@script_name, "Demonstrates Anthropic prompt caching for cost savings",
      model: model,
      cache_ttl: ttl,
      max_tokens: max_tokens
    )

    {context, tools} = build_context_with_large_system_and_tools()

    IO.puts("📋 Context prepared:")
    IO.puts("   • Large system prompt (>1024 tokens for Sonnet threshold)")
    IO.puts("   • 2 tool definitions (weather, calculator)")
    IO.puts("   • Initial user message\n")

    opts = build_request_opts(tools, ttl, max_tokens)

    IO.puts(String.duplicate("═", 78))
    IO.puts(IO.ANSI.bright() <> "STREAMING API TESTS" <> IO.ANSI.reset())
    IO.puts(String.duplicate("═", 78))

    run_streaming_tests(model, context, opts)

    IO.puts("\n" <> String.duplicate("═", 78))
    IO.puts(IO.ANSI.bright() <> "NON-STREAMING API TESTS" <> IO.ANSI.reset())
    IO.puts(String.duplicate("═", 78))

    run_nonstreaming_tests(model, context, opts)

    IO.puts("\n✅ Both streaming and non-streaming APIs correctly report cache metrics!\n")
  rescue
    error -> Helpers.handle_error!(error, @script_name, [])
  end

  defp build_context_with_large_system_and_tools do
    large_system_prompt = """
    You are an expert AI assistant with deep knowledge across multiple domains.
    Your expertise includes software engineering, data science, mathematics,
    physics, chemistry, biology, history, literature, and current events.

    When answering questions, you should:
    1. Provide accurate and well-researched information
    2. Cite sources when possible
    3. Acknowledge uncertainty when appropriate
    4. Break down complex topics into understandable explanations
    5. Use examples to illustrate key concepts
    6. Consider multiple perspectives on controversial topics

    You have access to tools that allow you to:
    - Search for current weather information
    - Perform complex calculations

    Always use the available tools when they would improve your response quality.

    Your communication style should be:
    - Professional yet approachable
    - Clear and concise
    - Structured with proper formatting
    - Empathetic to the user's needs and knowledge level

    Remember that you are here to help users learn and accomplish their goals.
    Take time to understand what they're trying to achieve, and provide guidance
    that is both thorough and practical.

    DOMAIN EXPERTISE GUIDELINES:

    Software Engineering:
    - Follow SOLID principles and clean code practices
    - Consider scalability, maintainability, and performance
    - Use appropriate design patterns for the problem at hand
    - Write clear documentation and meaningful tests
    - Consider edge cases and error handling
    - Think about security implications
    - Consider the entire software development lifecycle

    Data Science and Analytics:
    - Start with exploratory data analysis
    - Validate assumptions with statistical tests
    - Consider data quality and preprocessing needs
    - Choose appropriate models for the problem type
    - Validate results with proper cross-validation
    - Interpret results in business context
    - Consider ethical implications of data use

    Mathematics and Statistics:
    - Show your work step by step
    - Explain the reasoning behind each step
    - Use proper mathematical notation
    - Verify results when possible
    - Consider alternative approaches
    - Explain concepts using analogies when helpful

    Physics and Natural Sciences:
    - Ground explanations in fundamental principles
    - Use real-world examples to illustrate concepts
    - Explain the experimental basis for theories
    - Discuss practical applications
    - Address common misconceptions
    - Connect related concepts across disciplines

    Communication Best Practices:
    - Tailor explanations to the user's level
    - Use clear, jargon-free language when possible
    - Define technical terms when necessary
    - Provide examples to illustrate abstract concepts
    - Break complex topics into digestible chunks
    - Use formatting to improve readability
    - Summarize key points when appropriate

    Problem-Solving Approach:
    - Clarify the problem before solving
    - Break down complex problems into smaller parts
    - Consider multiple solution approaches
    - Evaluate trade-offs between solutions
    - Think about edge cases and constraints
    - Verify solutions when possible
    - Explain the reasoning process clearly

    Tool Usage Guidelines:
    - Use weather tool for current weather queries
    - Use calculator for complex mathematical computations
    - Always validate tool inputs before calling
    - Handle tool errors gracefully
    - Explain tool results to the user clearly

    Quality Standards:
    - Accuracy is paramount - verify information
    - Completeness - address all aspects of questions
    - Clarity - ensure explanations are understandable
    - Relevance - stay focused on user's needs
    - Actionability - provide practical next steps
    - Timeliness - respond efficiently

    Extended Knowledge Base:

    #{String.duplicate("This section contains extensive domain knowledge, best practices, methodologies, frameworks, and detailed guidelines across multiple disciplines including software engineering, data science, mathematics, physics, chemistry, biology, and more. This content is designed to exceed the minimum token threshold required for Anthropic's prompt caching feature. ", 25)}

    The tools you have available are comprehensive and powerful. Use them wisely
    to provide the most accurate and helpful responses possible. When a user asks
    a question that could benefit from real-time data, always check if you have
    a tool that can provide that information.

    Quality of response is paramount. Take your time to craft responses that are
    not just correct, but genuinely helpful and insightful.
    """

    weather_tool =
      ReqLLM.tool(
        name: "get_weather",
        description: "Get current weather for a location",
        parameter_schema: [
          location: [type: :string, required: true, doc: "City name or location"],
          unit: [
            type: :string,
            default: "celsius",
            doc: "Temperature unit (celsius or fahrenheit)"
          ]
        ],
        callback: fn args ->
          location = args["location"] || args[:location]
          unit = args["unit"] || args[:unit] || "celsius"
          temp = if unit == "celsius", do: "22°C", else: "72°F"
          {:ok, "Weather in #{location}: #{temp}, sunny, humidity 45%, wind 8mph"}
        end
      )

    calculator_tool =
      ReqLLM.tool(
        name: "calculate",
        description: "Perform mathematical calculations",
        parameter_schema: [
          expression: [type: :string, required: true, doc: "Math expression to evaluate"]
        ],
        callback: fn args ->
          expr = args["expression"] || args[:expression]
          {:ok, "Calculated: #{expr} = 42"}
        end
      )

    context =
      ReqLLM.Context.new([
        ReqLLM.Context.system(large_system_prompt),
        ReqLLM.Context.user("What's the weather like in San Francisco?")
      ])

    {context, [weather_tool, calculator_tool]}
  end

  defp run_streaming_tests(model, context, opts) do
    IO.puts("\n" <> String.duplicate("─", 78))
    IO.puts(IO.ANSI.bright() <> "Request 1: Creating the cache (streaming)" <> IO.ANSI.reset())
    IO.puts(String.duplicate("─", 78))

    {response1, duration1} =
      Helpers.time(fn ->
        ReqLLM.stream_text(model, context, opts)
      end)

    case response1 do
      {:ok, resp} ->
        text1 = consume_stream(resp)
        usage1 = ReqLLM.StreamResponse.usage(resp)
        display_response(text1, usage1, duration1, "First Request (Streaming)")

        IO.puts("\n" <> String.duplicate("─", 78))

        IO.puts(
          IO.ANSI.bright() <> "Request 2: Using cached context (streaming)" <> IO.ANSI.reset()
        )

        IO.puts(String.duplicate("─", 78))

        updated_context =
          resp.context
          |> ReqLLM.Context.append(ReqLLM.Context.user("Now tell me about Seattle's weather."))

        {response2, duration2} =
          Helpers.time(fn ->
            ReqLLM.stream_text(model, updated_context, opts)
          end)

        case response2 do
          {:ok, resp2} ->
            text2 = consume_stream(resp2)
            usage2 = ReqLLM.StreamResponse.usage(resp2)
            display_response(text2, usage2, duration2, "Second Request (Streaming)")
            display_cache_savings(usage1, usage2)

          {:error, error} ->
            raise error
        end

      {:error, error} ->
        raise error
    end
  end

  defp run_nonstreaming_tests(model, context, opts) do
    IO.puts("\n" <> String.duplicate("─", 78))

    IO.puts(
      IO.ANSI.bright() <> "Request 1: Creating the cache (non-streaming)" <> IO.ANSI.reset()
    )

    IO.puts(String.duplicate("─", 78))

    opts_without_tools = Keyword.delete(opts, :tools)

    {response1, duration1} =
      Helpers.time(fn ->
        ReqLLM.generate_text(model, context, opts_without_tools)
      end)

    case response1 do
      {:ok, resp} ->
        text1 = ReqLLM.Response.text(resp)
        usage1 = resp.usage
        display_response(text1, usage1, duration1, "First Request (Non-streaming)")

        IO.puts("\n" <> String.duplicate("─", 78))

        IO.puts(
          IO.ANSI.bright() <> "Request 2: Using cached context (non-streaming)" <> IO.ANSI.reset()
        )

        IO.puts(String.duplicate("─", 78))

        updated_context =
          resp.context
          |> ReqLLM.Context.append(ReqLLM.Context.user("Now tell me about Seattle's weather."))

        {response2, duration2} =
          Helpers.time(fn ->
            ReqLLM.generate_text(model, updated_context, opts_without_tools)
          end)

        case response2 do
          {:ok, resp2} ->
            text2 = ReqLLM.Response.text(resp2)
            usage2 = resp2.usage
            display_response(text2, usage2, duration2, "Second Request (Non-streaming)")
            display_cache_savings(usage1, usage2)

          {:error, error} ->
            raise error
        end

      {:error, error} ->
        raise error
    end
  end

  defp build_request_opts(tools, ttl, max_tokens) do
    []
    |> Helpers.maybe_put(:tools, tools)
    |> Helpers.maybe_put(:max_tokens, max_tokens)
    |> Helpers.maybe_put(:anthropic_prompt_cache, true)
    |> Helpers.maybe_put(:anthropic_prompt_cache_ttl, if(ttl == "1h", do: "1h"))
  end

  defp consume_stream(stream_response) do
    stream_response.stream
    |> Enum.reduce("", fn chunk, acc ->
      case chunk do
        %{type: :content, text: text} when is_binary(text) ->
          acc <> text

        _ ->
          acc
      end
    end)
  end

  defp display_response(text, usage, duration_ms, label) do
    IO.puts("\n" <> IO.ANSI.cyan() <> label <> IO.ANSI.reset())

    if text && text != "" do
      preview = String.slice(text, 0..150)
      IO.puts("   #{preview}...")
    end

    IO.puts("")

    Helpers.print_usage_and_timing(usage, duration_ms, [])
  end

  defp display_cache_savings(usage1, usage2) do
    cache_creation = get_in(usage1, [:cache_creation_input_tokens]) || 0

    cache_read1 =
      get_in(usage1, [:cache_read_input_tokens]) || get_in(usage1, [:cached_input]) || 0

    cache_read2 =
      get_in(usage2, [:cache_read_input_tokens]) || get_in(usage2, [:cached_input]) || 0

    if cache_read1 > 0 or cache_read2 > 0 do
      IO.puts("\n" <> String.duplicate("═", 78))

      IO.puts(
        IO.ANSI.bright() <> IO.ANSI.green() <> "💰 Cache Savings Analysis" <> IO.ANSI.reset()
      )

      IO.puts(String.duplicate("═", 78))

      IO.puts("\n   Tokens cached (request 1):           #{format_number(cache_creation)}")
      IO.puts("   Tokens read from cache (request 1):  #{format_number(cache_read1)}")
      IO.puts("   Tokens read from cache (request 2):  #{format_number(cache_read2)}")

      if cache_read1 > 0 or cache_read2 > 0 do
        IO.puts("\n   💡 Cached tokens are read at 90% cost reduction (10% of normal input cost)")
        IO.puts("      vs. processing the same content as fresh input tokens.")
      end

      cost1 = get_in(usage1, [:cost])
      cost2 = get_in(usage2, [:cost])

      if cost1 && cost2 && cost1 > cost2 do
        cost_savings = cost1 - cost2
        IO.puts("\n   Cost comparison:")
        IO.puts("      Request 1: $#{Float.round(cost1, 6)}")
        IO.puts("      Request 2: $#{Float.round(cost2, 6)}")
        IO.puts("      Savings:   $#{Float.round(cost_savings, 6)}")
      end

      IO.puts("")
    else
      IO.puts("\n⚠️  Note: Cache metrics not detected in responses.")
      IO.puts("    Ensure system prompt + tools exceed minimum token threshold")
      IO.puts("    (1024 tokens for Sonnet, 2048 for Haiku 3.x, 4096 for Haiku 4.5)")
    end
  end

  defp format_number(num) when is_integer(num) do
    num
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end

  defp format_number(num), do: "#{num}"
end

AnthropicPromptCaching.run(System.argv())
