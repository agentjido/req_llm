alias ReqLLM.Scripts.Helpers

defmodule ObjectStream do
  @moduledoc """
  Demonstrates streaming structured object generation with ReqLLM.

  This script showcases the `ReqLLM.stream_object/4` function, which extracts
  structured data from LLM responses using a schema definition. The example
  extracts person information (name, age, occupation, location) from natural
  language prompts.

  ## Usage

      mix run lib/examples/scripts/object_stream.exs "Your prompt here" [options]

  ## Options

    * `--model`, `-m` - Model to use (default: openai:gpt-4o)
    * `--log-level`, `-l` - Logging level: debug, info, warning, error (default: warning)
    * `--max-tokens` - Maximum tokens to generate
    * `--temperature` - Temperature for generation (0.0-2.0)

  ## Examples

      # Extract person information from text
      mix run lib/examples/scripts/object_stream.exs "Extract person info: Jane Smith, 32, architect in Berlin"

      # Use a different model
      mix run lib/examples/scripts/object_stream.exs "Generate a person profile" --model anthropic:claude-sonnet-4-5-20250929

      # Control generation parameters
      mix run lib/examples/scripts/object_stream.exs "Person: Alice, 28" --temperature 0.7 --max-tokens 500
  """

  @script_name "object_stream.exs"

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

    Helpers.banner!(@script_name, "Demonstrates streaming structured object generation",
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
        case ReqLLM.stream_object(model, ctx, schema, generation_opts) do
          {:ok, stream_response} ->
            ReqLLM.StreamResponse.to_response(stream_response)

          {:error, error} ->
            {:error, error}
        end
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
        "Create a profile for a designer named Jordan who is 32 years old."
    end
  end

  defp build_generation_opts(opts) do
    []
    |> Helpers.maybe_put(:max_tokens, opts[:max_tokens])
    |> Helpers.maybe_put(:temperature, opts[:temperature])
  end
end

ObjectStream.run(System.argv())
