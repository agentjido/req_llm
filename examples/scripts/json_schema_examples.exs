alias ReqLLM.Scripts.Helpers

defmodule JSONSchemaExamples do
  @moduledoc """
  Demonstrates structured object generation using JSON schemas.

  Shows how to use `ReqLLM.generate_object/4` with various schema definitions
  to generate structured data conforming to specified types and constraints.

  ## Usage

      elixir lib/examples/scripts/json_schema_examples.exs [options]

  ## Options

    * `-m, --model` - Model identifier (default: "openai:gpt-4o")
    * `-l, --log-level` - Log level: debug, info, warning, error (default: "warning")

  ## Examples

  Run with default model:

      elixir lib/examples/scripts/json_schema_examples.exs

  Use a specific model:

      elixir lib/examples/scripts/json_schema_examples.exs -m anthropic:claude-sonnet-4-5-20250929

  Enable debug logging:

      elixir lib/examples/scripts/json_schema_examples.exs -l debug
  """

  @script_name "json_schema_examples.exs"

  def run(args) do
    Helpers.ensure_app!()

    opts = parse_args(args)
    Logger.configure(level: Helpers.log_level(opts[:log_level]))

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
    context = Helpers.context(prompt)

    {result, time} =
      Helpers.time(fn ->
        ReqLLM.generate_object(model, context, schema)
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
    context = Helpers.context(prompt)

    {result, time} =
      Helpers.time(fn ->
        ReqLLM.generate_object(model, context, schema)
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
    context = Helpers.context(prompt)

    {result, time} =
      Helpers.time(fn ->
        ReqLLM.generate_object(model, context, schema)
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
end

JSONSchemaExamples.run(System.argv())
