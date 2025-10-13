alias ReqLLM.Scripts.Helpers

defmodule JSONSchemaExamples do
  @script_name "json_schema_examples.exs"

  def run(args) do
    Helpers.ensure_app!()

    opts = parse_args(args)
    Logger.configure(level: parse_log_level(opts[:log_level]))

    model = opts[:model]

    Helpers.banner!(@script_name, "Demonstrates structured object generation with schemas",
      model: model
    )

    example_simple_person(model)
    example_product(model)
    example_event(model)
  end

  defp parse_args(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [model: :string, log_level: :string],
        aliases: [m: :model, l: :log_level]
      )

    [
      model: opts[:model] || Helpers.default_text_model(),
      log_level: opts[:log_level] || "warning"
    ]
  end

  defp example_simple_person(model) do
    IO.puts("\n=== Simple Person Schema ===\n")

    schema = [
      name: [type: :string, required: true],
      age: [type: :integer, required: true],
      occupation: [type: :string, required: true]
    ]

    prompt = "Generate information for a software engineer named Alice who is 28 years old"

    {result, time} =
      Helpers.time(fn ->
        ReqLLM.Generation.generate_object(model, prompt, schema)
      end)

    case result do
      {:ok, response} ->
        IO.puts("Generated person:")
        IO.inspect(response.object, pretty: true)
        IO.puts("\nCompleted in #{time}ms")

      {:error, error} ->
        IO.puts("Error: #{inspect(error)}")
    end
  end

  defp example_product(model) do
    IO.puts("\n=== Product Schema ===\n")

    schema = [
      name: [type: :string, required: true],
      price: [type: :float, required: true],
      category: [type: :string, required: true],
      features: [type: {:list, :string}, required: true],
      in_stock: [type: :boolean, required: true]
    ]

    prompt = "Generate a product listing for a wireless mechanical keyboard priced at $129.99"

    {result, time} =
      Helpers.time(fn ->
        ReqLLM.Generation.generate_object(model, prompt, schema)
      end)

    case result do
      {:ok, response} ->
        IO.puts("Generated product:")
        IO.inspect(response.object, pretty: true)
        IO.puts("\nCompleted in #{time}ms")

      {:error, error} ->
        IO.puts("Error: #{inspect(error)}")
    end
  end

  defp example_event(model) do
    IO.puts("\n=== Event Schema with Lists and Enums ===\n")

    schema = [
      title: [type: :string, required: true],
      date: [type: :string, required: true],
      attendees: [type: {:list, :string}, required: true],
      status: [type: {:in, ["scheduled", "cancelled", "completed"]}, required: true],
      max_capacity: [type: :pos_integer, required: true]
    ]

    prompt = "Generate a tech meetup event for next Friday with 5 attendees, max 50 people"

    {result, time} =
      Helpers.time(fn ->
        ReqLLM.Generation.generate_object(model, prompt, schema)
      end)

    case result do
      {:ok, response} ->
        IO.puts("Generated event:")
        IO.inspect(response.object, pretty: true)
        IO.puts("\nCompleted in #{time}ms")

      {:error, error} ->
        IO.puts("Error: #{inspect(error)}")
    end
  end

  defp parse_log_level(level_str) do
    case level_str do
      "debug" -> :debug
      "info" -> :info
      "warning" -> :warning
      "error" -> :error
      _ -> :warning
    end
  end
end

JSONSchemaExamples.run(System.argv())
