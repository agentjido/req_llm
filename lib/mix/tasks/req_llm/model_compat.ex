defmodule Mix.Tasks.ReqLlm.ModelCompat do
  @shortdoc "Validate ReqLLM model coverage with fixture-based testing"
  @moduledoc """
  Validate ReqLLM model coverage using the fixture system.

  Models are sourced from priv/models_dev/*.json (synced via mix req_llm.model_sync).
  Fixture validation state is tracked in priv/supported_models.json (auto-generated).

  ## Usage

      mix req_llm.model_compat                    # List covered models
      mix req_llm.model_compat --available        # List all available models

      ### Test using local fixtures
      mix req_llm.model_compat "anthropic:*"      # Test all Anthropic models
      mix req_llm.model_compat "openai:gpt-4o"    # Test specific model
      mix req_llm.model_compat "*:*"              # Test all models (uses fixtures)

      ### Record new fixtures
      mix req_llm.model_compat --sample           # Test sample models from config/config.exs
      mix req_llm.model_compat "openai:*" --record # Record fixtures for OpenAI models

      ### Debug
      mix req_llm.model_compat --debug            # Verbose output with fixture details

  ## Flags

      --available        List all models from models.dev API registry
      --sample           Test sample model subset (config/config.exs)
      --record           Re-record fixtures (live API calls)
      --record-all       Force re-record all fixtures (ignores state)
      --debug            Enable verbose fixture debugging
  """

  use Mix.Task

  @preferred_cli_env :test

  @impl Mix.Task
  def run(args) do
    Application.ensure_all_started(:req_llm)

    {opts, positional, _} =
      OptionParser.parse(args,
        switches: [
          sample: :boolean,
          available: :boolean,
          record: :boolean,
          record_all: :boolean,
          debug: :boolean
        ]
      )

    if opts[:available] do
      list_models(opts)
    else
      model_spec = List.first(positional)
      run_coverage(model_spec, opts)
    end
  end

  defp list_models(opts) do
    models = load_registry()
    state = load_state()
    sample_specs = if opts[:sample], do: get_sample_models()
    implemented_providers = get_implemented_providers()

    Mix.shell().info("\n#{header(opts[:sample])}\n")

    models
    |> Enum.sort_by(fn {provider, _} -> provider end)
    |> Enum.each(fn {provider, provider_models} ->
      filtered = filter_by_specs(provider_models, provider, sample_specs)

      if not Enum.empty?(filtered) do
        status_text =
          if MapSet.member?(implemented_providers, provider) do
            provider_passing =
              Enum.count(filtered, fn m ->
                Map.get(state, "#{provider}:#{m["id"]}") == "pass"
              end)

            IO.ANSI.faint() <>
              " (#{provider_passing}/#{length(filtered)} passing)" <> IO.ANSI.reset()
          else
            IO.ANSI.faint() <> " (no provider yet)" <> IO.ANSI.reset()
          end

        Mix.shell().info(
          IO.ANSI.cyan() <>
            IO.ANSI.bright() <>
            provider_name(provider) <>
            IO.ANSI.reset() <>
            status_text
        )

        Enum.each(filtered, fn model ->
          print_model_with_status(model, provider, state)
        end)

        Mix.shell().info("")
      end
    end)

    provider_count = map_size(models)

    implemented_count =
      Enum.count(models, fn {p, _} -> MapSet.member?(implemented_providers, p) end)

    total_models = models |> Enum.map(fn {_, ms} -> length(ms) end) |> Enum.sum()
    tested = map_size(state)
    passing = state |> Enum.count(fn {_, status} -> status == "pass" end)

    Mix.shell().info(
      IO.ANSI.faint() <>
        "#{implemented_count}/#{provider_count} providers implemented • #{total_models} models • #{tested} tested • #{passing} passing\n" <>
        IO.ANSI.reset()
    )
  end

  defp run_coverage(model_spec, opts) when is_binary(model_spec) do
    do_run_coverage(model_spec, opts)
  end

  defp run_coverage(nil, opts) do
    if opts[:sample] do
      do_run_coverage(nil, opts)
    else
      show_covered_models()
    end
  end

  defp show_covered_models do
    Mix.shell().info("\n----------------------------------------------------")
    Mix.shell().info("Covered Models")
    Mix.shell().info("----------------------------------------------------\n")

    state = load_state()
    models = load_registry()

    covered =
      state
      |> Enum.filter(fn {_spec, status} -> status == "pass" end)
      |> Enum.map(fn {spec, _} -> spec end)
      |> Enum.sort()

    if Enum.empty?(covered) do
      Mix.shell().info("No models validated yet.\n")
      Mix.shell().info("Run: mix req_llm.model_compat \"*:*\" --record\n")
    else
      covered
      |> Enum.group_by(fn spec ->
        [provider, _] = String.split(spec, ":", parts: 2)
        provider
      end)
      |> Enum.sort_by(fn {provider, _} -> provider end)
      |> Enum.each(fn {provider, specs} ->
        Mix.shell().info(
          IO.ANSI.cyan() <>
            IO.ANSI.bright() <>
            provider_name(provider) <> IO.ANSI.reset()
        )

        Enum.each(specs, fn spec ->
          [_, model_id] = String.split(spec, ":", parts: 2)
          model = find_model(models, provider, model_id)

          if model do
            print_covered_model(model, spec)
          end
        end)

        Mix.shell().info("")
      end)

      total = models |> Enum.map(fn {_, ms} -> length(ms) end) |> Enum.sum()
      pct = Float.round(length(covered) / total * 100, 1)

      Mix.shell().info("Coverage: #{length(covered)}/#{total} models validated (#{pct}%)\n")
    end
  end

  defp do_run_coverage(model_spec, opts) do
    Mix.shell().info("\n----------------------------------------------------")
    Mix.shell().info(header(opts[:sample]))
    Mix.shell().info("----------------------------------------------------\n")

    models = load_registry()
    specs = select_models(models, model_spec, opts)

    if Enum.empty?(specs) do
      Mix.raise("No models match spec: #{inspect(model_spec)}")
    end

    total_specs = length(specs)

    recording = opts[:record_all] || opts[:record]

    mode_text = if recording, do: "#{total_specs} to record", else: "replay mode"

    Mix.shell().info("Testing #{total_specs} model(s) (#{mode_text})...\n")

    start_time = System.monotonic_time(:millisecond)

    results =
      specs
      |> Task.async_stream(
        fn {provider, model_id} ->
          test_model(provider, model_id, opts)
        end,
        max_concurrency: System.schedulers_online() * 2,
        timeout: :infinity,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    elapsed = System.monotonic_time(:millisecond) - start_time

    if recording do
      run_ts = DateTime.utc_now() |> DateTime.truncate(:second)
      save_state(results, run_ts)
    end

    print_summary(results, elapsed)
  end

  defp test_model(provider, model_id, opts) do
    spec = "#{provider}:#{model_id}"
    mode = if opts[:record_all] || opts[:record], do: "record", else: "replay"

    env = [
      {"REQ_LLM_MODELS", spec},
      {"REQ_LLM_FIXTURES_MODE", mode},
      {"REQ_LLM_DEBUG", "1"}
    ]

    Mix.shell().info("  Testing #{spec}...")

    {output, exit_code} =
      System.cmd(
        "mix",
        ["test", "--only", "provider:#{provider}", "--only", "coverage"],
        env: env,
        stderr_to_stdout: true
      )

    if opts[:debug] do
      Mix.shell().info("\n--- Debug Output for #{spec} ---")
      Mix.shell().info(output)
      Mix.shell().info("--- End Debug Output ---\n")
    end

    parse_test_result(provider, model_id, output, exit_code)
  end

  defp parse_test_result(provider, model_id, output, exit_code) do
    {passed, failed, total} =
      cond do
        match = Regex.run(~r/(\d+) tests?, 0 failures/, output) ->
          count = String.to_integer(Enum.at(match, 1))
          {count, 0, count}

        match = Regex.run(~r/(\d+) tests?, (\d+) failures?/, output) ->
          total = String.to_integer(Enum.at(match, 1))
          failed = String.to_integer(Enum.at(match, 2))
          {total - failed, failed, total}

        true ->
          {0, 1, 1}
      end

    status = if exit_code == 0 && failed == 0, do: :pass, else: :fail
    fixtures = extract_fixtures(output)

    %{
      provider: provider,
      model_id: model_id,
      model_spec: "#{provider}:#{model_id}",
      status: status,
      passed: passed,
      failed: failed,
      total: total,
      error: if(failed > 0, do: extract_error(output)),
      fixtures: fixtures
    }
  end

  defp extract_error(output) do
    output
    |> String.split("\n")
    |> Enum.filter(&String.contains?(&1, ["**", "Error", "FAILED", "expected"]))
    |> Enum.take(2)
    |> Enum.join("\n")
    |> String.slice(0..120)
  end

  defp extract_fixtures(output) do
    output
    |> String.split("\n")
    |> Enum.filter(&String.contains?(&1, "[Fixture] step:"))
    |> Enum.map(fn line ->
      case Regex.run(~r/name=(\w+)/, line) do
        [_, name] -> name
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp print_summary(results, elapsed_ms) do
    Mix.shell().info("\n----------------------------------------------------")
    Mix.shell().info("  Summary")
    Mix.shell().info("----------------------------------------------------\n")

    tested = Enum.reject(results, &(&1.status == :skipped))

    tested
    |> Enum.group_by(& &1.provider)
    |> Enum.sort_by(fn {provider, _} -> provider end)
    |> Enum.each(fn {provider, provider_results} ->
      Mix.shell().info(
        IO.ANSI.cyan() <>
          IO.ANSI.bright() <>
          provider_name(provider) <> IO.ANSI.reset()
      )

      Enum.each(provider_results, &print_result/1)
      Mix.shell().info("")
    end)

    total_tested = length(tested)
    passing = Enum.count(tested, &(&1.status == :pass))

    if total_tested > 0 do
      pct = Float.round(passing / total_tested * 100, 1)
      color = if pct == 100.0, do: IO.ANSI.green(), else: IO.ANSI.yellow()

      elapsed_sec = Float.round(elapsed_ms / 1000, 1)

      Mix.shell().info(
        color <>
          "Coverage: #{passing}/#{total_tested} passing (#{pct}%)" <>
          IO.ANSI.reset() <> " in #{elapsed_sec}s\n"
      )

      if passing != total_tested, do: System.halt(1)
    end
  end

  defp print_result(result) do
    icon =
      case result.status do
        :pass -> IO.ANSI.green() <> "PASS"
        :fail -> IO.ANSI.red() <> "FAIL"
      end

    Mix.shell().info("  #{icon} #{result.model_id}#{IO.ANSI.reset()}")

    if result.fixtures && !Enum.empty?(result.fixtures) do
      fixtures_text = Enum.join(result.fixtures, ", ")
      Mix.shell().info("       #{IO.ANSI.faint()}fixtures: #{fixtures_text}#{IO.ANSI.reset()}")
    end

    if result.error do
      Mix.shell().info("       #{IO.ANSI.faint()}#{result.error}#{IO.ANSI.reset()}")
    end
  end

  defp print_model_with_status(model, provider, state) do
    model_spec = "#{provider}:#{model["id"]}"
    status = Map.get(state, model_spec)

    status_icon =
      case status do
        "pass" -> IO.ANSI.green() <> "✓" <> IO.ANSI.reset()
        "fail" -> IO.ANSI.red() <> "✗" <> IO.ANSI.reset()
        _ -> IO.ANSI.faint() <> "•" <> IO.ANSI.reset()
      end

    tier_color =
      case model["tier"] do
        "flagship" -> IO.ANSI.yellow()
        "fast" -> IO.ANSI.green()
        "experimental" -> IO.ANSI.magenta()
        _ -> ""
      end

    tier_text =
      if model["tier"], do: " #{tier_color}(#{model["tier"]})#{IO.ANSI.reset()}", else: ""

    Mix.shell().info("  #{status_icon} #{model["id"]}#{tier_text}")
  end

  defp print_covered_model(model, _spec) do
    tier_color =
      case model["tier"] do
        "flagship" -> IO.ANSI.yellow()
        "fast" -> IO.ANSI.green()
        "experimental" -> IO.ANSI.magenta()
        _ -> ""
      end

    tier_text =
      if model["tier"], do: " #{tier_color}(#{model["tier"]})#{IO.ANSI.reset()}", else: ""

    Mix.shell().info("  #{IO.ANSI.green()}PASS#{IO.ANSI.reset()} #{model["id"]}#{tier_text}")
  end

  defp select_models(registry, spec, opts) do
    all_models =
      registry
      |> Enum.flat_map(fn {provider, models} ->
        Enum.map(models, fn model -> {provider, model["id"]} end)
      end)

    base_filter =
      cond do
        opts[:sample] ->
          sample = get_sample_models()
          Enum.filter(all_models, fn {p, m} -> Enum.member?(sample, "#{p}:#{m}") end)

        is_nil(spec) || spec == "*:*" ->
          all_models

        String.contains?(spec, ":") ->
          [provider_part, model_part] = String.split(spec, ":", parts: 2)

          if model_part == "*" do
            provider_atom = String.to_atom(provider_part)
            Enum.filter(all_models, fn {p, _} -> p == provider_atom end)
          else
            Enum.filter(all_models, fn {p, m} -> "#{p}:#{m}" == spec end)
          end

        true ->
          provider_atom = String.to_atom(spec)
          Enum.filter(all_models, fn {p, _} -> p == provider_atom end)
      end

    if opts[:sample] && spec do
      provider_atom =
        if String.contains?(spec, ":") do
          spec |> String.split(":", parts: 2) |> List.first() |> String.to_atom()
        else
          String.to_atom(spec)
        end

      Enum.filter(base_filter, fn {p, _} -> p == provider_atom end)
    else
      base_filter
    end
  end

  defp filter_by_specs(models, _provider, nil), do: models

  defp filter_by_specs(models, provider, specs) do
    Enum.filter(models, fn model ->
      Enum.member?(specs, "#{provider}:#{model["id"]}")
    end)
  end

  defp load_registry do
    priv_dir = :code.priv_dir(:req_llm)
    models_dir = Path.join(priv_dir, "models_dev")

    if !File.dir?(models_dir) do
      Mix.raise("""
      Models directory not found: #{models_dir}

      Run: mix req_llm.model_sync
      """)
    end

    models_dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".json"))
    |> Enum.map(fn filename ->
      provider = filename |> String.replace_suffix(".json", "") |> String.to_atom()
      path = Path.join(models_dir, filename)

      case File.read(path) do
        {:ok, content} ->
          data = Jason.decode!(content)
          models = Map.get(data, "models", [])
          {provider, models}

        {:error, reason} ->
          Mix.raise("Failed to read #{path}: #{inspect(reason)}")
      end
    end)
    |> Enum.reject(fn {_, models} -> Enum.empty?(models) end)
    |> Map.new()
  end

  defp load_state do
    priv_dir = :code.priv_dir(:req_llm)
    path = Path.join(priv_dir, "supported_models.json")

    case File.read(path) do
      {:ok, content} ->
        data = Jason.decode!(content)
        Map.get(data, "state", %{})

      {:error, _} ->
        %{}
    end
  end

  defp save_state(results, run_ts) do
    priv_dir = :code.priv_dir(:req_llm)
    path = Path.join(priv_dir, "supported_models.json")

    existing =
      case File.read(path) do
        {:ok, content} -> Jason.decode!(content)
        _ -> %{}
      end

    existing_state = Map.get(existing, "state", %{})
    existing_recorded = Map.get(existing, "last_recorded", %{})

    new_state =
      results
      |> Enum.reject(&(&1.status == :skipped))
      |> Enum.reduce(existing_state, fn result, acc ->
        status = if result.status == :pass, do: "pass", else: "fail"
        Map.put(acc, result.model_spec, status)
      end)

    ts = DateTime.to_iso8601(run_ts)

    new_recorded =
      results
      |> Enum.reject(&(&1.status == :skipped))
      |> Enum.reduce(existing_recorded, fn result, acc ->
        Map.put(acc, result.model_spec, ts)
      end)

    json = build_sorted_json(new_state, new_recorded)

    case File.read(path) do
      {:ok, prev} when prev == json -> :ok
      _ -> File.write!(path, json)
    end
  end

  defp build_sorted_json(state, last_recorded) do
    state_json =
      state
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.map_join(",\n    ", fn {k, v} ->
        ~s("#{k}": "#{v}")
      end)

    recorded_json =
      last_recorded
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.map_join(",\n    ", fn {k, v} ->
        ~s("#{k}": "#{v}")
      end)

    """
    {
      "state": {
        #{state_json}
      },
      "last_recorded": {
        #{recorded_json}
      }
    }
    """
  end

  defp find_model(registry, provider, model_id) do
    provider_atom = if is_binary(provider), do: String.to_atom(provider), else: provider

    case Map.get(registry, provider_atom) do
      nil -> nil
      models -> Enum.find(models, fn m -> m["id"] == model_id end)
    end
  end

  defp provider_name(provider) when is_atom(provider) do
    provider |> to_string() |> provider_name()
  end

  defp provider_name("anthropic"), do: "Anthropic"
  defp provider_name("openai"), do: "OpenAI"
  defp provider_name("google"), do: "Google"
  defp provider_name("groq"), do: "Groq"
  defp provider_name("xai"), do: "xAI"
  defp provider_name("openrouter"), do: "OpenRouter"
  defp provider_name(provider), do: String.capitalize(provider)

  defp header(true), do: "Sample Models"
  defp header(_), do: "Model Coverage"

  defp get_sample_models do
    Application.get_env(:req_llm, :test_models, [])
  end

  defp get_implemented_providers do
    providers = ReqLLM.Provider.Registry.list_implemented_providers()
    MapSet.new(providers)
  end
end
