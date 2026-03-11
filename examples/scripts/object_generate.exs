alias ReqLLM.Scripts.Helpers

defmodule ObjectGenerate do
  @moduledoc """
  Demonstrates structured object generation using JSON schemas.

  Generates a structured object (Person profile) from a natural language prompt
  using `ReqLLM.generate_object/4` with a NimbleOptions schema definition.

  ## Usage

      mix run lib/examples/scripts/object_generate.exs "Your prompt" [options]

  ## Options

    * `--model` (`-m`) - Model identifier (default: openai:gpt-4o)
    * `--log-level` (`-l`) - Log level: debug, info, warning, error (default: warning)
    * `--max-tokens` - Maximum tokens to generate
    * `--temperature` - Sampling temperature (0.0-2.0)

  ## Examples

      # Basic usage
      mix run lib/examples/scripts/object_generate.exs "Create a profile for Alice, a 30 year old software engineer"

      # With specific model
      mix run lib/examples/scripts/object_generate.exs "Generate a person profile" --model anthropic:claude-sonnet-4-5-20250929

      # With generation parameters
      mix run lib/examples/scripts/object_generate.exs "Create a person" --temperature 0.5 --max-tokens 150

      # With debug logging
      mix run lib/examples/scripts/object_generate.exs "Generate profile" --log-level debug
  """

  @script_name "object_generate.exs"

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

    prompt = get_prompt!(parsed_opts, remaining_args)

    opts = Keyword.put(parsed_opts, :prompt, prompt)

    model = opts[:model] || Helpers.default_text_model()

    Logger.configure(level: Helpers.log_level(opts[:log_level] || "warning"))

    Helpers.banner!(@script_name, "Demonstrates structured object generation",
      model: model,
      prompt: prompt,
      max_tokens: opts[:max_tokens],
      temperature: opts[:temperature]
    )

    schema = person_schema()

    ctx = Helpers.context(prompt)

    generation_opts = build_generation_opts(opts)

    {result, duration_ms} =
      Helpers.time(fn ->
        ReqLLM.generate_object(model, ctx, schema, generation_opts)
      end)

    case result do
      {:ok, response} ->
        object = ReqLLM.Response.object(response)
        usage = ReqLLM.Response.usage(response)
        Helpers.print_object_response(object, usage, duration_ms)

      {:error, error} ->
        raise error
    end
  rescue
    error -> Helpers.handle_error!(error, @script_name, [])
  end

  defp person_schema do
    [
      name: [type: :string, required: true, doc: "Person's name"],
      age: [type: :pos_integer, required: true, doc: "Person's age"],
      occupation: [type: :string, required: true, doc: "Person's occupation"],
      location: [type: :string, required: true, doc: "Person's location"]
    ]
  end

  defp get_prompt!(opts, remaining_args) do
    cond do
      opts[:prompt] ->
        opts[:prompt]

      not Enum.empty?(remaining_args) ->
        List.first(remaining_args)

      true ->
        "Create a profile for a software developer named Alex who is 28 years old."
    end
  end

  defp build_generation_opts(opts) do
    []
    |> Helpers.maybe_put(:max_tokens, opts[:max_tokens])
    |> Helpers.maybe_put(:temperature, opts[:temperature])
  end
end

ObjectGenerate.run(System.argv())
