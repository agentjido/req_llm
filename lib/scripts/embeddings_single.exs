alias ReqLLM.Scripts.Helpers

defmodule EmbeddingsSingle do
  @script_name "embeddings_single.exs"

  def run(argv) do
    Helpers.ensure_app!()

    {parsed_opts, remaining_args} =
      OptionParser.parse!(argv,
        strict: [
          model: :string,
          log_level: :string
        ],
        aliases: [m: :model, l: :log_level]
      )

    text = get_text!(parsed_opts, remaining_args)

    opts = Keyword.put(parsed_opts, :text, text)

    model = opts[:model] || Helpers.default_embedding_model()

    Logger.configure(level: parse_log_level(opts[:log_level] || "warning"))

    Helpers.banner!(@script_name, "Demonstrates single text embedding",
      model: model,
      text: text
    )

    {result, duration_ms} =
      Helpers.time(fn ->
        ReqLLM.Embedding.embed(model, text, [])
      end)

    case result do
      {:ok, embedding} -> print_embedding_result(embedding, duration_ms)
      {:error, error} -> raise error
    end
  rescue
    error -> Helpers.handle_error!(error, @script_name, [])
  end

  defp get_text!(opts, remaining_args) do
    cond do
      opts[:text] ->
        opts[:text]

      not Enum.empty?(remaining_args) ->
        List.first(remaining_args)

      true ->
        IO.puts(:stderr, "Error: Text is required\n")
        IO.puts("Usage: mix run #{@script_name} \"Your text here\" [options]")
        IO.puts("\nOptions:")
        IO.puts("  --model, -m      Model to use (default: openai:text-embedding-3-small)")
        IO.puts("  --log-level, -l  Log level: debug, info, warning, error")
        IO.puts("\nExample:")
        IO.puts("  mix run #{@script_name} \"Elixir is a dynamic, functional language\"")

        IO.puts(
          "  mix run #{@script_name} \"Machine learning\" --model openai:text-embedding-3-large"
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

  defp print_embedding_result(embedding, duration_ms) do
    dimensions = length(embedding)
    preview = Enum.take(embedding, 8)

    IO.puts(IO.ANSI.green() <> "Embedding Generated:" <> IO.ANSI.reset())
    IO.puts("  Dimensions: #{dimensions}")
    IO.puts("  First 8 values: #{inspect(preview)}")
    IO.puts("")
    Helpers.print_usage_and_timing(nil, duration_ms, [])
  end
end

EmbeddingsSingle.run(System.argv())
