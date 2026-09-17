# Run from this repository: mix run demo.exs

unless System.get_env("TYPESAFE_API_KEY") do
  key =
    __DIR__
    |> Stream.iterate(&Path.dirname/1)
    |> Enum.take(4)
    |> Enum.find_value(fn directory ->
      file = Path.join(directory, ".env")

      if File.regular?(file) do
        case Dotenvy.source(file) do
          {:ok, values} -> values["TYPESAFE_API_KEY"]
          {:error, _reason} -> nil
        end
      end
    end)

  if is_binary(key) and key != "", do: System.put_env("TYPESAFE_API_KEY", key)
end

if System.get_env("TYPESAFE_API_KEY") in [nil, ""] do
  raise "Set TYPESAFE_API_KEY or add it to a .env file in this repository or a parent folder"
end

state = %{
  ticket: "I was charged twice for my order and need a refund today.",
  customer_tier: "business"
}

questions = %{
  department: %{
    type: :choice,
    instructions: "Which team should handle this ticket?",
    criteria: %{billing: "Payments and refunds", support: "Other customer requests"}
  },
  severity: %{
    type: :score,
    instructions: "How severe is this ticket?",
    criteria: ["low", "medium", "high"]
  },
  urgent: %{type: :boolean, instructions: "Does this ticket need prompt action?"}
}

IO.inspect(state, label: "State", pretty: true)
IO.inspect(questions, label: "Questions", pretty: true)

response = ReqLLM.evaluate!("typesafe:jev-latest", state, questions)

IO.inspect(response, label: "Complete ReqLLM.Response", pretty: true, limit: :infinity)
IO.inspect(ReqLLM.Response.object(response), label: "Named answers", pretty: true)
IO.inspect(ReqLLM.Response.usage(response), label: "Usage", pretty: true)
IO.inspect(response.provider_meta.raw_response, label: "Raw TypeSafe data", pretty: true)
IO.inspect(ReqLLM.Response.text(response), label: "Chat text (expected nil)")
