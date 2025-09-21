defmodule Mix.Tasks.ReqLlm.Models do
  @shortdoc "List supported AI models and providers"

  @moduledoc """
  List all supported AI models and providers available in ReqLLM.

  ## Usage

      # List all models
      mix req_llm.models

      # List models for specific provider
      mix req_llm.models --provider openai

      # Show detailed information
      mix req_llm.models --verbose

  ## Options

      --provider      Filter by specific provider (e.g., openai, anthropic)
      --verbose       Show detailed model information including costs and capabilities

  ## Examples

      # List all models
      mix req_llm.models

      # Show only OpenAI models
      mix req_llm.models --provider openai

      # Show detailed information
      mix req_llm.models --verbose
  """

  use Mix.Task

  @preferred_cli_env ["req_llm.models": :dev]
  @models_dir "priv/models_dev"

  @spec run([String.t()]) :: :ok
  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [
          provider: :string,
          verbose: :boolean
        ],
        aliases: [
          p: :provider,
          v: :verbose
        ]
      )

    provider_filter = Keyword.get(opts, :provider)
    verbose = Keyword.get(opts, :verbose, false)

    models_dir = Path.join(File.cwd!(), @models_dir)

    if not File.exists?(models_dir) do
      IO.puts("No model data found. Run 'mix req_llm.model_sync' to sync model data.")
      System.halt(1)
    end

    provider_files = get_provider_files(models_dir, provider_filter)

    if Enum.empty?(provider_files) do
      case provider_filter do
        nil ->
          IO.puts("No provider data found. Run 'mix req_llm.model_sync' to sync model data.")

        provider ->
          available_providers = get_available_providers(models_dir)
          IO.puts("Provider '#{provider}' not found.")

          if not Enum.empty?(available_providers) do
            IO.puts("Available providers: #{Enum.join(available_providers, ", ")}")
          end
      end

      System.halt(1)
    end

    if verbose do
      output_verbose_table(provider_files)
    else
      output_simple_table(provider_files)
    end

    :ok
  end

  defp get_provider_files(models_dir, nil) do
    Path.wildcard(Path.join(models_dir, "*.json"))
    |> Enum.map(fn file ->
      provider = Path.basename(file, ".json")
      {provider, file}
    end)
    |> Enum.sort()
  end

  defp get_provider_files(models_dir, provider_filter) do
    file_path = Path.join(models_dir, "#{provider_filter}.json")

    if File.exists?(file_path) do
      [{provider_filter, file_path}]
    else
      []
    end
  end

  defp get_available_providers(models_dir) do
    Path.wildcard(Path.join(models_dir, "*.json"))
    |> Enum.map(fn file -> Path.basename(file, ".json") end)
    |> Enum.sort()
  end

  defp output_simple_table(provider_files) do
    IO.puts("Available Models:\n")

    for {provider, file_path} <- provider_files do
      case read_provider_file(file_path) do
        {:ok, models} when models != [] ->
          IO.puts("#{String.upcase(provider)} (#{length(models)} models):")

          for model <- models do
            model_id = Map.get(model, "id", "unknown")
            IO.puts("  #{provider}:#{model_id}")
          end

          IO.puts("")

        {:ok, []} ->
          IO.puts("#{String.upcase(provider)}: No models available")
          IO.puts("")

        {:error, reason} ->
          IO.puts("#{String.upcase(provider)}: Error loading models - #{reason}")
          IO.puts("")
      end
    end

    IO.puts("Usage: ReqLLM.generate_text(\"provider:model\", \"Your prompt\")")
  end

  defp output_verbose_table(provider_files) do
    IO.puts("Detailed Model Information:\n")

    for {provider, file_path} <- provider_files do
      case read_provider_file(file_path) do
        {:ok, models} when models != [] ->
          IO.puts("=== #{String.upcase(provider)} ===")

          for model <- models do
            model_id = Map.get(model, "id", "unknown")
            IO.puts("#{provider}:#{model_id}")

            # Show name if different from ID
            name = Map.get(model, "name")

            if name && name != model_id do
              IO.puts("  Name: #{name}")
            end

            # Show cost information
            case Map.get(model, "cost") do
              %{"input" => input_cost, "output" => output_cost} ->
                IO.puts("  Cost: $#{input_cost}/1K input, $#{output_cost}/1K output")

              _ ->
                nil
            end

            # Show limits
            case Map.get(model, "limit") do
              %{} = limit ->
                if context = Map.get(limit, "context") do
                  IO.puts("  Context: #{format_number(context)} tokens")
                end

                if output = Map.get(limit, "output") do
                  IO.puts("  Max Output: #{format_number(output)} tokens")
                end

              _ ->
                nil
            end

            # Show capabilities
            capabilities = []

            capabilities =
              if Map.get(model, "reasoning"), do: ["reasoning" | capabilities], else: capabilities

            capabilities =
              if Map.get(model, "tool_call"), do: ["tool_call" | capabilities], else: capabilities

            capabilities =
              if Map.get(model, "temperature"),
                do: ["temperature" | capabilities],
                else: capabilities

            capabilities =
              if Map.get(model, "attachment"),
                do: ["attachment" | capabilities],
                else: capabilities

            if capabilities != [] do
              IO.puts("  Capabilities: #{Enum.join(Enum.reverse(capabilities), ", ")}")
            end

            # Show modalities
            case Map.get(model, "modalities") do
              %{"input" => input_modalities, "output" => output_modalities}
              when is_list(input_modalities) and is_list(output_modalities) ->
                IO.puts("  Input: #{Enum.join(input_modalities, ", ")}")
                IO.puts("  Output: #{Enum.join(output_modalities, ", ")}")

              _ ->
                nil
            end

            IO.puts("")
          end

        {:ok, []} ->
          IO.puts("=== #{String.upcase(provider)} ===")
          IO.puts("No models available")
          IO.puts("")

        {:error, reason} ->
          IO.puts("=== #{String.upcase(provider)} ===")
          IO.puts("Error loading models: #{reason}")
          IO.puts("")
      end
    end
  end

  defp read_provider_file(file_path) do
    with {:ok, content} <- File.read(file_path),
         {:ok, data} <- decode_json(content) do
      models = Map.get(data, "models", [])
      {:ok, models}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # Simple JSON decoder that works without Jason
  defp decode_json(content) do
    try do
      # Try to use Jason if available (when running in full Mix environment)
      Jason.decode(content)
    rescue
      UndefinedFunctionError ->
        # Fallback: use a simple regex-based parser for basic JSON structure
        # This works for the well-structured model files
        case parse_simple_json(content) do
          {:ok, data} -> {:ok, data}
          {:error, _} -> {:error, "JSON parsing not available and simple parser failed"}
        end
    end
  end

  # Very simple JSON parser for well-structured model files
  # This is a fallback when Jason is not available
  defp parse_simple_json(content) do
    try do
      # Extract all model IDs directly from the content
      model_ids = Regex.scan(~r/"id":\s*"([^"]+)"/s, content)
                  |> Enum.map(fn [_, id] -> id end)

      models = Enum.map(model_ids, fn id -> %{"id" => id} end)
      {:ok, %{"models" => models}}
    rescue
      _ -> {:error, "Failed to parse JSON"}
    end
  end

  defp extract_model_ids(models_json) do
    # Extract model IDs using regex - simple but works for our structured data
    Regex.scan(~r/"id":\s*"([^"]+)"/s, models_json)
    |> Enum.map(fn [_, id] -> id end)
  end

  defp format_number(num) when num >= 1_000_000 do
    "#{Float.round(num / 1_000_000, 1)}M"
  end

  defp format_number(num) when num >= 1_000 do
    "#{Float.round(num / 1_000, 1)}K"
  end

  defp format_number(num) do
    to_string(num)
  end
end