# tutorial/agents/17_external_api_tool.exs
#
# Chapter 18: External HTTP API Tool
# Goal: Integrate a real (or mocked) external API as a tool.
#
# Run with:
#   mix run tutorial/agents/17_external_api_tool.exs

# Ensure dotenvy loads .env file if present
_ = Dotenvy.source(".env")
Logger.configure(level: :warning)

defmodule ExternalTools do
  alias ReqLLM.Tool

  def weather_tool do
    Tool.new!(
      name: "weather",
      description: "Get current weather for a city",
      parameter_schema: [
        city: [type: :string, required: true, doc: "City name"]
      ],
      callback: &weather_callback/1
    )
  end

  defp weather_callback(args) do
    city = args[:city] || args["city"]
    api_key = System.get_env("WEATHER_API_KEY")

    IO.puts("   [HTTP Tool] Fetching weather for #{city}...")

    case Req.get(
           "https://api.openweathermap.org/data/2.5/weather",
           params: [q: city, appid: api_key, units: "metric"]
         ) do
      {:ok, %{status: 200, body: body}} ->
        temp = body["main"]["temp"]
        desc = body["weather"] |> List.first() |> Map.get("description")
        {:ok, "#{temp}°C, #{desc}"}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, "Network error: #{inspect(reason)}"}
    end
  end

  # Mock version for testing without API key
  def mock_weather_tool do
    Tool.new!(
      name: "weather",
      description: "Get current weather (mocked)",
      parameter_schema: [city: [type: :string, required: true]],
      callback: fn args ->
        city = args[:city] || args["city"]
        # Simulate network delay
        Process.sleep(500)
        {:ok, "#{city}: 20°C, partly cloudy"}
      end
    )
  end
end

# --- AGENT (Sync) ---
defmodule SimpleAgent.Sync do
  use GenServer

  import ReqLLM.Context

  alias ReqLLM.{Context, Tool, ToolCall}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def ask(pid, text), do: GenServer.call(pid, {:ask, text}, 120_000)

  @impl true
  def init(opts) do
    model = Keyword.get(opts, :model)
    tools = Keyword.get(opts, :tools, [])
    ctx = Context.new([system("You are a helpful assistant.")])
    {:ok, %{model: model, context: ctx, tools: tools}}
  end

  @impl true
  def handle_call({:ask, text}, _from, state) do
    ctx = Context.append(state.context, user(text))

    # Phase 1
    IO.puts("   [Phase 1] Asking model...")
    {:ok, response} = ReqLLM.generate_text(state.model, ctx.messages, tools: state.tools)
    calls = ReqLLM.Response.tool_calls(response)
    ctx2 = Context.append(ctx, response.message)

    if calls == [] do
      reply = ReqLLM.Response.text(response)
      {:reply, {:ok, reply}, %{state | context: ctx2}}
    else
      # Phase 2
      IO.puts("   [Phase 2] Executing #{length(calls)} tool(s)...")

      ctx3 =
        Enum.reduce(calls, ctx2, fn call, acc ->
          args = ToolCall.args_map(call)
          res = Tool.execute(List.first(state.tools), args) |> elem(1)
          IO.puts("      Result: #{inspect(res)}")
          Context.append(acc, Context.tool_result(call.id, to_string(res)))
        end)

      # Phase 3
      IO.puts("   [Phase 3] Final answer...")
      {:ok, final} = ReqLLM.generate_text(state.model, ctx3.messages, tools: [])
      reply = ReqLLM.Response.text(final)
      IO.puts("assistant> #{reply}")

      {:reply, {:ok, reply}, %{state | context: Context.append(ctx3, final.message)}}
    end
  end
end

# --- MAIN ---
model = System.get_env("REQ_LLM_MODEL", "anthropic:claude-haiku-4.5")
IO.puts("=== Chapter 18: External HTTP API Tool ===\n")

# Use mock if no API key
tool =
  if System.get_env("WEATHER_API_KEY") do
    ExternalTools.weather_tool()
  else
    IO.puts("Note: Using mock weather (set WEATHER_API_KEY for real API)\n")
    ExternalTools.mock_weather_tool()
  end

{:ok, pid} =
  SimpleAgent.Sync.start_link(
    model: model,
    tools: [tool]
  )

IO.puts(">> What's the weather in London?")
SimpleAgent.Sync.ask(pid, "What's the weather in London?")
