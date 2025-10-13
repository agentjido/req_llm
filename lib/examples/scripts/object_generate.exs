alias ReqLLM.Scripts.Helpers

defmodule ObjectGenerate do
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

    Logger.configure(level: parse_log_level(opts[:log_level] || "warning"))

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
      occupation: [type: :string, doc: "Person's occupation"],
      location: [type: :string, doc: "Person's location"]
    ]
  end

  defp get_prompt!(opts, remaining_args) do
    cond do
      opts[:prompt] ->
        opts[:prompt]

      not Enum.empty?(remaining_args) ->
        List.first(remaining_args)

      true ->
        IO.puts(:stderr, "Error: Prompt is required\n")
        IO.puts("Usage: mix run #{@script_name} \"Your prompt here\" [options]")
        IO.puts("\nExample:")

        IO.puts(
          "  mix run #{@script_name} \"Create a profile for a software engineer named Alice\""
        )

        IO.puts(
          "  mix run #{@script_name} \"Generate a person profile\" --model anthropic:claude-3-5-sonnet-20241022"
        )

        System.halt(1)
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

  defp build_generation_opts(opts) do
    []
    |> maybe_put(:max_tokens, opts[:max_tokens])
    |> maybe_put(:temperature, opts[:temperature])
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end

ObjectGenerate.run(System.argv())
