defmodule Mix.Tasks.ReqLlm.Cover do
  @shortdoc "Validate ReqLLM model coverage with fixture-based testing"
  @moduledoc """
  Validate ReqLLM model coverage using the fixture system.
  
  Models are sourced from priv/models_dev/*.json (synced via mix req_llm.model_sync).
  Fixture validation state is tracked in priv/supported_models.json (auto-generated).
  
  ## Usage
  
      mix req_llm.cover                    # List covered models
      mix req_llm.cover "*:*"              # Test all models (uses fixtures)
      mix req_llm.cover anthropic          # Test all Anthropic models
      mix req_llm.cover "openai:gpt-4o"    # Test specific model
      mix req_llm.cover --quick            # Test quick set from config/test.exs
      mix req_llm.cover --list             # List all available models
      mix req_llm.cover "openai:*" --record # Record fixtures for OpenAI models
      mix req_llm.cover --debug            # Verbose output with fixture details
  
  ## Flags
  
      --quick        Test quick model subset (config/test.exs)
      --list         List all models from registry
      --record       Re-record fixtures (live API calls)
      --record-all   Force re-record all fixtures (ignores state)
      --debug        Enable verbose fixture debugging
  """
  
  use Mix.Task
  
  @impl Mix.Task
  def run(args) do
    {opts, positional, _} = OptionParser.parse(args,
      switches: [quick: :boolean, list: :boolean, record: :boolean, 
                 record_all: :boolean, debug: :boolean]
    )
    
    if opts[:list] do
      list_models(opts)
    else
      model_spec = List.first(positional)
      run_coverage(model_spec, opts)
    end
  end
  
  defp list_models(opts) do
    models = load_registry()
    quick_specs = if opts[:quick], do: get_quick_models(), else: nil
    
    Mix.shell().info("\n#{header(opts[:quick])}\n")
    
    models
    |> Enum.sort_by(fn {provider, _} -> provider end)
    |> Enum.each(fn {provider, provider_models} ->
      filtered = filter_by_specs(provider_models, provider, quick_specs)
      
      if length(filtered) > 0 do
        Mix.shell().info(IO.ANSI.cyan() <> IO.ANSI.bright() <> 
                        provider_name(provider) <> IO.ANSI.reset())
        Enum.each(filtered, &print_model/1)
        Mix.shell().info("")
      end
    end)
  end
  
  defp run_coverage(model_spec, opts) when is_binary(model_spec) do
    do_run_coverage(model_spec, opts)
  end
  
  defp run_coverage(nil, opts) do
    if opts[:quick] do
      do_run_coverage(nil, opts)
    else
      show_covered_models()
    end
  end
  
  defp show_covered_models do
    Mix.shell().info("\n════════════════════════════════════════════════════")
    Mix.shell().info("Covered Models")
    Mix.shell().info("════════════════════════════════════════════════════\n")
    
    state = load_state()
    models = load_registry()
    
    covered = state
    |> Enum.filter(fn {_spec, status} -> status == "pass" end)
    |> Enum.map(fn {spec, _} -> spec end)
    |> Enum.sort()
    
    if Enum.empty?(covered) do
      Mix.shell().info("No models validated yet.\n")
      Mix.shell().info("Run: mix req_llm.cover \"*:*\" --record\n")
    else
      covered
      |> Enum.group_by(fn spec -> 
        [provider, _] = String.split(spec, ":", parts: 2)
        provider
      end)
      |> Enum.sort_by(fn {provider, _} -> provider end)
      |> Enum.each(fn {provider, specs} ->
        Mix.shell().info(IO.ANSI.cyan() <> IO.ANSI.bright() <> 
                        provider_name(provider) <> IO.ANSI.reset())
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
    Mix.shell().info("\n════════════════════════════════════════════════════")
    Mix.shell().info(header(opts[:quick]))
    Mix.shell().info("════════════════════════════════════════════════════\n")
    
    models = load_registry()
    specs = select_models(models, model_spec, opts)
    state = load_state()
    
    if Enum.empty?(specs) do
      Mix.raise("No models match spec: #{inspect(model_spec)}")
    end
    
    total_specs = length(specs)
    to_test = Enum.count(specs, fn {provider, model_id} ->
      opts[:record_all] || opts[:record] || 
      Map.get(state, "#{provider}:#{model_id}") != "pass"
    end)
    
    Mix.shell().info("Testing #{total_specs} model(s) (#{to_test} to run, #{total_specs - to_test} cached)...\n")
    
    start_time = System.monotonic_time(:millisecond)
    
    results = specs
    |> Task.async_stream(
      fn {provider, model_id} ->
        should_test = opts[:record_all] || opts[:record] || 
                      Map.get(state, "#{provider}:#{model_id}") != "pass"
        
        if should_test do
          test_model(provider, model_id, opts)
        else
          skip_model(provider, model_id)
        end
      end,
      max_concurrency: System.schedulers_online() * 2,
      timeout: :infinity,
      ordered: false
    )
    |> Enum.map(fn {:ok, result} -> result end)
    
    elapsed = System.monotonic_time(:millisecond) - start_time
    
    save_state(results)
    print_summary(results, elapsed)
  end
  
  defp test_model(provider, model_id, opts) do
    spec = "#{provider}:#{model_id}"
    mode = if opts[:record_all] || opts[:record], do: "record", else: "replay"
    
    env = [
      {"REQ_LLM_MODELS", spec},
      {"REQ_LLM_FIXTURES_MODE", mode}
    ]
    
    if opts[:debug], do: System.put_env("REQ_LLM_DEBUG", "1")
    
    Mix.shell().info("  Testing #{spec}...")
    
    {output, exit_code} = System.cmd(
      "mix", 
      ["test", "--only", "provider:#{provider}", "--only", "coverage"],
      env: env,
      stderr_to_stdout: true
    )
    
    parse_test_result(provider, model_id, output, exit_code)
  end
  
  defp skip_model(provider, model_id) do
    %{
      provider: provider,
      model_id: model_id,
      model_spec: "#{provider}:#{model_id}",
      status: :skipped,
      passed: 0,
      failed: 0,
      total: 0,
      error: nil
    }
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
    
    %{
      provider: provider,
      model_id: model_id,
      model_spec: "#{provider}:#{model_id}",
      status: status,
      passed: passed,
      failed: failed,
      total: total,
      error: if(failed > 0, do: extract_error(output), else: nil)
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
  
  defp print_summary(results, elapsed_ms) do
    Mix.shell().info("\n════════════════════════════════════════════════════")
    Mix.shell().info("  Summary")
    Mix.shell().info("════════════════════════════════════════════════════\n")
    
    tested = Enum.reject(results, &(&1.status == :skipped))
    
    tested
    |> Enum.group_by(& &1.provider)
    |> Enum.sort_by(fn {provider, _} -> provider end)
    |> Enum.each(fn {provider, provider_results} ->
      Mix.shell().info(IO.ANSI.cyan() <> IO.ANSI.bright() <> 
                      provider_name(provider) <> IO.ANSI.reset())
      Enum.each(provider_results, &print_result/1)
      Mix.shell().info("")
    end)
    
    skipped = Enum.count(results, &(&1.status == :skipped))
    if skipped > 0 do
      Mix.shell().info(IO.ANSI.yellow() <> "Skipped: #{skipped} (already passing)" <> 
                      IO.ANSI.reset() <> "\n")
    end
    
    total_tested = length(tested)
    passing = Enum.count(tested, &(&1.status == :pass))
    
    if total_tested > 0 do
      pct = Float.round(passing / total_tested * 100, 1)
      color = if pct == 100.0, do: IO.ANSI.green(), else: IO.ANSI.yellow()
      
      elapsed_sec = Float.round(elapsed_ms / 1000, 1)
      Mix.shell().info(color <> "Coverage: #{passing}/#{total_tested} passing (#{pct}%)" <> 
                      IO.ANSI.reset() <> " in #{elapsed_sec}s\n")
      
      if passing != total_tested, do: System.halt(1)
    end
  end
  
  defp print_result(result) do
    icon = case result.status do
      :pass -> IO.ANSI.green() <> "PASS"
      :fail -> IO.ANSI.red() <> "FAIL"
    end
    
    Mix.shell().info("  #{icon} #{result.model_id} (#{result.passed}/#{result.total})#{IO.ANSI.reset()}")
    
    if result.error do
      Mix.shell().info("       #{IO.ANSI.faint()}#{result.error}#{IO.ANSI.reset()}")
    end
  end
  
  defp print_model(model) do
    tier_color = case model["tier"] do
      "flagship" -> IO.ANSI.yellow()
      "fast" -> IO.ANSI.green()
      "experimental" -> IO.ANSI.magenta()
      _ -> ""
    end
    
    tier_text = if model["tier"], do: " #{tier_color}(#{model["tier"]})#{IO.ANSI.reset()}", else: ""
    Mix.shell().info("  • #{model["id"]}#{tier_text}")
  end
  
  defp print_covered_model(model, _spec) do
    tier_color = case model["tier"] do
      "flagship" -> IO.ANSI.yellow()
      "fast" -> IO.ANSI.green()
      "experimental" -> IO.ANSI.magenta()
      _ -> ""
    end
    
    tier_text = if model["tier"], do: " #{tier_color}(#{model["tier"]})#{IO.ANSI.reset()}", else: ""
    Mix.shell().info("  #{IO.ANSI.green()}PASS#{IO.ANSI.reset()} #{model["id"]}#{tier_text}")
  end
  
  defp select_models(registry, spec, opts) do
    all_models = registry
    |> Enum.flat_map(fn {provider, models} ->
      Enum.map(models, fn model -> {provider, model["id"]} end)
    end)
    
    cond do
      opts[:quick] ->
        quick = get_quick_models()
        Enum.filter(all_models, fn {p, m} -> 
          Enum.member?(quick, "#{p}:#{m}")
        end)
      
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
    
    unless File.dir?(models_dir) do
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
  
  defp save_state(results) do
    priv_dir = :code.priv_dir(:req_llm)
    path = Path.join(priv_dir, "supported_models.json")
    
    existing_state = load_state()
    
    new_state = results
    |> Enum.reject(&(&1.status == :skipped))
    |> Enum.reduce(existing_state, fn result, acc ->
      status = if result.status == :pass, do: "pass", else: "fail"
      Map.put(acc, result.model_spec, status)
    end)
    
    sorted_state = new_state
    |> Enum.sort_by(fn {key, _} -> key end)
    
    json = build_sorted_json(sorted_state, DateTime.utc_now() |> DateTime.to_iso8601())
    File.write!(path, json)
  end
  
  defp build_sorted_json(state, timestamp) do
    state_json = state
    |> Enum.map(fn {key, value} ->
      ~s("#{key}": "#{value}")
    end)
    |> Enum.join(",\n    ")
    
    """
    {
      "last_validated": "#{timestamp}",
      "state": {
        #{state_json}
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
  
  defp header(true), do: "Quick Test Models"
  defp header(_), do: "Model Coverage"
  
  defp get_quick_models do
    Application.get_env(:req_llm, :test_models, [])
  end
end
