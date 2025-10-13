alias ReqLLM.Scripts.Helpers

defmodule EmbeddingsBatchSimilarity do
  @moduledoc """
  Demonstrates batch embedding and cosine similarity analysis using ReqLLM.

  Generates embeddings for multiple texts in a single API call and calculates
  pairwise cosine similarities to identify the most and least similar text pairs.

  ## Usage

      mix run lib/examples/scripts/embeddings_batch_similarity.exs [options]

  ## Options

    * `--model, -m` - Model to use (default: openai:text-embedding-3-small)
    * `--log-level, -l` - Log level: debug, info, warning, error (default: warning)

  ## Examples

      # Run similarity analysis with default texts
      mix run lib/examples/scripts/embeddings_batch_similarity.exs

      # Use specific model
      mix run lib/examples/scripts/embeddings_batch_similarity.exs --model openai:text-embedding-3-large

      # Enable debug logging
      mix run lib/examples/scripts/embeddings_batch_similarity.exs --log-level debug
  """

  @script_name "embeddings_batch_similarity.exs"

  @texts [
    "Functional programming in Elixir enables elegant solutions through pattern matching and immutability",
    "OTP behaviors provide robust building blocks for fault-tolerant distributed systems",
    "Making sourdough bread requires patience, proper fermentation, and careful temperature control",
    "Phoenix LiveView brings real-time server-rendered interactivity without JavaScript frameworks",
    "Neural networks learn complex patterns through layers of weighted connections and backpropagation"
  ]

  def run(argv) do
    Helpers.ensure_app!()

    {parsed_opts, _remaining_args} =
      OptionParser.parse!(argv,
        strict: [
          model: :string,
          log_level: :string
        ],
        aliases: [m: :model, l: :log_level]
      )

    model = parsed_opts[:model] || Helpers.default_embedding_model()

    Logger.configure(level: Helpers.log_level(parsed_opts[:log_level] || "warning"))

    Helpers.banner!(@script_name, "Demonstrates batch embedding and similarity analysis",
      model: model,
      texts_count: length(@texts)
    )

    {result, duration_ms} =
      Helpers.time(fn ->
        ReqLLM.embed(model, @texts, [])
      end)

    case result do
      {:ok, embeddings} -> print_similarity_analysis(embeddings, duration_ms)
      {:error, error} -> raise error
    end
  rescue
    error -> Helpers.handle_error!(error, @script_name, [])
  end

  defp print_similarity_analysis(embeddings, duration_ms) do
    IO.puts(IO.ANSI.green() <> "Embeddings Generated:" <> IO.ANSI.reset())
    IO.puts("  Texts embedded: #{length(embeddings)}")
    IO.puts("")

    similarities = calculate_all_similarities(embeddings)

    {max_pair, max_sim} = Enum.max_by(similarities, fn {_, sim} -> sim end)
    {min_pair, min_sim} = Enum.min_by(similarities, fn {_, sim} -> sim end)

    IO.puts(IO.ANSI.green() <> "Similarity Analysis:" <> IO.ANSI.reset())
    print_pair("Most similar", max_pair, max_sim)
    print_pair("Least similar", min_pair, min_sim)
    IO.puts("")
    Helpers.print_usage_and_timing(nil, duration_ms, [])
  end

  defp calculate_all_similarities(embeddings) do
    indexed_embeddings = Enum.with_index(embeddings)

    for {emb_a, idx_a} <- indexed_embeddings,
        {emb_b, idx_b} <- indexed_embeddings,
        idx_a < idx_b do
      similarity = ReqLLM.cosine_similarity(emb_a, emb_b)
      {{idx_a, idx_b}, similarity}
    end
  end

  defp print_pair(label, {idx_a, idx_b}, similarity) do
    text_a = Enum.at(@texts, idx_a)
    text_b = Enum.at(@texts, idx_b)

    IO.puts("  #{label}: #{Float.round(similarity, 4)}")
    IO.puts("    [#{idx_a}] #{truncate(text_a, 60)}")
    IO.puts("    [#{idx_b}] #{truncate(text_b, 60)}")
  end

  defp truncate(text, max_length) do
    if String.length(text) > max_length do
      String.slice(text, 0, max_length - 3) <> "..."
    else
      text
    end
  end
end

EmbeddingsBatchSimilarity.run(System.argv())
