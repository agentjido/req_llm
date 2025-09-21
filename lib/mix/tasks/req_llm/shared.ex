defmodule Mix.Tasks.ReqLlm.Shared do
  @moduledoc """
  Shared utilities for ReqLLM mix tasks.
  """

  @common_switches [
    model: :string,
    system: :string,
    max_tokens: :integer,
    temperature: :float,
    log_level: :string,
    debug_dir: :string
  ]

  @common_aliases [
    l: :log_level,
    d: :debug_dir
  ]

  def parse_args(args, extra_switches \\ []) do
    switches = Keyword.merge(@common_switches, extra_switches)
    aliases = @common_aliases

    OptionParser.parse(args, switches: switches, aliases: aliases)
  end

  def validate_prompt(args_list, task_name) do
    case args_list do
      [prompt | _] ->
        {:ok, prompt}

      [] ->
        show_usage(task_name)
        {:error, :no_prompt}
    end
  end

  def show_usage(task_name) do
    examples =
      case task_name do
        "generate_text" ->
          [
            ~s(  mix req.llm.generate_text "Explain APIs" --model groq:gemma2-9b-it),
            ~s(  mix req.llm.generate_text "Write a story" --model openai:gpt-4o --temperature 0.8)
          ]

        "stream_text" ->
          [
            ~s(  mix req.llm.stream_text "Explain streaming" --model groq:gemma2-9b-it),
            ~s(  mix req.llm.stream_text "Write a poem" --model openai:gpt-4o --log-level verbose)
          ]

        "generate_object" ->
          [
            ~s(  mix req.llm.generate_object "Generate a user profile" --model openai:gpt-4o-mini),
            ~s(  mix req.llm.generate_object "Extract person info" --model anthropic:claude-3-sonnet)
          ]

        "stream_object" ->
          [
            ~s(  mix req.llm.stream_object "Generate a user profile" --model openai:gpt-4o-mini),
            ~s(  mix req.llm.stream_object "Extract person info" --model anthropic:claude-3-sonnet)
          ]
      end

    IO.puts(~s(Usage: mix req.llm.#{task_name} "Your prompt here" --model provider:model-name))
    IO.puts("")
    IO.puts("Examples:")
    Enum.each(examples, &IO.puts/1)
  end

  def parse_log_level(level_string) do
    case String.downcase(level_string || "normal") do
      "quiet" ->
        :quiet

      "normal" ->
        :normal

      "verbose" ->
        :verbose

      "debug" ->
        :debug

      _ ->
        IO.puts("Warning: Unknown log level '#{level_string}'. Using 'normal'.")
        :normal
    end
  end

  def build_generate_opts(opts) do
    []
    |> maybe_add_option(opts, :system_prompt, :system)
    |> maybe_add_option(opts, :max_tokens)
    |> maybe_add_option(opts, :temperature)
    |> Enum.reject(fn {_key, val} -> is_nil(val) end)
  end

  def default_object_schema do
    [
      name: [type: :string, required: true, doc: "Full name of the person"],
      age: [type: :pos_integer, doc: "Age in years"],
      occupation: [type: :string, doc: "Job or profession"],
      location: [type: :string, doc: "City or region where they live"]
    ]
  end

  def handle_common_errors({:error, %ReqLLM.Error.Invalid.Provider{provider: provider}}) do
    IO.puts(
      "Error: Unknown provider '#{provider}'. Please check that the provider is supported and properly configured."
    )

    IO.puts("Available providers: openai, groq, xai (others may require additional setup)")
    System.halt(1)
  end

  def handle_common_errors({:error, %ReqLLM.Error.Invalid.Parameter{parameter: param}}) do
    IO.puts("Error: #{param}")
    System.halt(1)
  end

  def handle_common_errors({:error, %ReqLLM.Error.API.Request{reason: reason, status: status}})
      when not is_nil(status) do
    IO.puts("API Error (#{status}): #{reason}")
    System.halt(1)
  end

  def handle_common_errors({:error, %ReqLLM.Error.API.Request{reason: reason}}) do
    IO.puts("API Error: #{reason}")
    System.halt(1)
  end

  def handle_common_errors({:error, error}) do
    IO.puts("Operation failed: #{format_error(error)}")
    System.halt(1)
  end

  def handle_common_errors({:ok, result}), do: {:ok, result}

  @spec handle_rescue_error(any()) :: no_return()
  def handle_rescue_error(%UndefinedFunctionError{module: nil, function: :prepare_request}) do
    IO.puts(
      "Error: Provider not properly configured or not available. Please check your model specification."
    )

    System.halt(1)
  end

  def handle_rescue_error(%UndefinedFunctionError{} = error) do
    IO.puts("Unexpected error: #{format_error(error)}")
    System.halt(1)
  end

  def handle_rescue_error(error) do
    IO.puts("Unexpected error: #{format_error(error)}")
    System.halt(1)
  end

  def show_stats(content, start_time, model_spec, prompt, response, type \\ :text) do
    end_time = System.monotonic_time(:millisecond)
    response_time = end_time - start_time

    input_tokens = get_nested(response, [:usage, :input_tokens], 0)
    output_tokens = get_nested(response, [:usage, :output_tokens], 0)
    estimated_cost = calculate_cost(model_spec, input_tokens + output_tokens)

    IO.puts("   Response time: #{response_time}ms")

    case type do
      :text ->
        output_tokens_est = estimate_tokens(content)
        input_tokens_est = estimate_tokens(prompt)
        IO.puts("   Output tokens: #{output_tokens} (est: #{output_tokens_est})")
        IO.puts("   Input tokens: #{input_tokens} (est: #{input_tokens_est})")

      :object ->
        object_json = Jason.encode!(content)
        object_size = byte_size(object_json)
        field_count = count_fields(content)
        IO.puts("   Object size: #{object_size} bytes")
        IO.puts("   Field count: #{field_count}")
        IO.puts("   Input tokens: #{input_tokens}")
        IO.puts("   Output tokens: #{output_tokens}")

      :stream ->
        chunk_count = Map.get(response, :chunk_count, 0)
        IO.puts("   Chunks received: #{chunk_count}")
        IO.puts("   Output tokens: #{output_tokens}")
        IO.puts("   Input tokens: #{input_tokens}")
    end

    IO.puts("   Total tokens: #{input_tokens + output_tokens}")

    if estimated_cost > 0 do
      IO.puts("   Estimated cost: $#{Float.round(estimated_cost, 6)}")
    else
      IO.puts("   Estimated cost: Unknown")
    end
  end

  # Private helper functions
  defp maybe_add_option(opts_list, parsed_opts, target_key, source_key \\ nil) do
    source_key = source_key || target_key

    case Keyword.get(parsed_opts, source_key) do
      nil -> opts_list
      value -> Keyword.put(opts_list, target_key, value)
    end
  end

  defp format_error(%{__struct__: _} = error), do: Exception.message(error)

  defp format_error(error), do: inspect(error)

  defp estimate_tokens(text), do: max(1, div(String.length(text), 4))

  defp calculate_cost(model_spec, tokens) do
    cost_per_million =
      cond do
        String.contains?(model_spec, "claude-3-haiku") -> 0.25
        String.contains?(model_spec, "claude-3-5-sonnet") -> 3.0
        String.contains?(model_spec, "claude-3-sonnet") -> 3.0
        String.contains?(model_spec, "claude-3-opus") -> 15.0
        String.contains?(model_spec, "gpt-4o-mini") -> 0.6
        String.contains?(model_spec, "gpt-4o") -> 2.4
        String.contains?(model_spec, "deepseek") -> 0.28
        String.contains?(model_spec, "groq:") -> 0.1
        true -> 0.0
      end

    tokens / 1_000_000 * cost_per_million
  end

  defp count_fields(obj) when is_map(obj) do
    Enum.reduce(obj, 0, fn {_key, value}, acc ->
      acc + 1 + count_fields(value)
    end)
  end

  defp count_fields(obj) when is_list(obj) do
    Enum.reduce(obj, 0, fn item, acc ->
      acc + count_fields(item)
    end)
  end

  defp count_fields(_), do: 0

  defp get_nested(map, keys, default) do
    Enum.reduce(keys, map, fn key, acc ->
      case acc do
        %{} -> Map.get(acc, key, default)
        _ -> default
      end
    end)
  end
end
