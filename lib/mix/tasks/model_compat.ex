defmodule Mix.Tasks.ReqLlm.ModelCompat do
  @shortdoc "Validate ReqLLM model coverage with fixture-based testing"
  @moduledoc """
  Validate ReqLLM model coverage using the fixture system.

  Models are sourced from priv/models_dev/*.json (synced via mix req_llm.model_sync).
  Fixture validation state is tracked in priv/supported_models.json (auto-generated).

  ## Selection Principles

  Models are selected using clear precedence: **spec → type → sample**

  - **spec**: Pattern over providers/models
    - When **no spec provided** (just `mix mc`): Uses default sets from config (`:test_models` or `:test_embedding_models`)
    - When **spec provided** (e.g., `"anthropic:*"`, `"*:*"`): Uses ALL matching models from registry
  - **type**: Filters by operation capability using registry metadata
    - `text` (default): Only text-generation models
    - `embedding`: Only embedding models
    - `all`: Both text and embedding models
  - **sample** (optional): Further reduces using `:sample_text_models` or `:sample_embedding_models`.
    If not configured, falls back to one model per provider.

  **Important**: 
  - Only **implemented providers** are included (registry models without implementation are skipped)
  - Config lists (`:test_models`, `:test_embedding_models`) are defaults only, not hard filters
  - Explicit specs like `"anthropic:*"` test ALL registry models for that provider

  ## Usage

      mix req_llm.model_compat                    # Show covered models (passing fixtures)
      mix req_llm.model_compat --sample           # Test sample models from config
      mix req_llm.model_compat --available        # List all registry models (unfiltered)

      ### Test using local fixtures
      mix req_llm.model_compat "anthropic:*"      # ALL Anthropic text models from registry
      mix req_llm.model_compat "openai:gpt-4o"    # Specific model
      mix req_llm.model_compat "*:*"              # ALL models from implemented providers

      ### Test by operation type
      mix req_llm.model_compat "google:*" --type all        # Google text + embedding models
      mix req_llm.model_compat "google:*" --type embedding  # Google embedding models only
      mix req_llm.model_compat "*:*" --type text            # All implemented text models

      ### Sample subset testing
      mix req_llm.model_compat --sample           # Sample subset (~1 per provider if not configured)
      mix req_llm.model_compat "anthropic:*" --sample --type text

      ### Record new fixtures
      mix req_llm.model_compat "openai:*" --record
      mix req_llm.model_compat "google:*" --type embedding --record

  ## Flags

      --available        List all models from models.dev API registry (no implementation filter)
      --sample           Further reduce to sample subset (see :sample_* config or fallback)
      --type TYPE        Operation type: text (default), embedding, or all
      --record           Re-record fixtures (live API calls)
      --record-all       Force re-record all fixtures (ignores state)
      --debug            Enable verbose fixture debugging

  ## Notes

  - When no spec is provided (or `"*:*"` is used), only implemented providers are considered
  - If a spec refers to an unimplemented provider, it will be skipped with a warning
  - The final model list is deterministic and stable
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
          type: :string,
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
    sample_specs = if opts[:sample], do: default_specs_for_operation(:text)
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
                model_id = m["id"]
                has_fixtures = has_fixtures?(provider, model_id)

                case Map.get(state, "#{provider}:#{model_id}") do
                  %{"status" => "pass"} when has_fixtures -> true
                  _ -> false
                end
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

    passing =
      state
      |> Enum.count(fn {spec, entry} ->
        case entry do
          %{"status" => "pass"} ->
            [provider, model_id] = String.split(spec, ":", parts: 2)
            has_fixtures?(String.to_atom(provider), model_id)

          _ ->
            false
        end
      end)

    excluded =
      state
      |> Enum.count(fn {_, entry} ->
        case entry do
          %{"status" => "excluded"} -> true
          _ -> false
        end
      end)

    Mix.shell().info(
      IO.ANSI.faint() <>
        "#{implemented_count}/#{provider_count} providers implemented • #{total_models} models • #{tested} tested • #{passing} passing • #{excluded} excluded\n" <>
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
    Mix.shell().info("Model Coverage Status")
    Mix.shell().info("----------------------------------------------------\n")

    state = load_state()
    models = load_registry()
    implemented = get_implemented_providers()

    models
    |> Enum.filter(fn {provider, _} -> MapSet.member?(implemented, provider) end)
    |> Enum.map(fn {provider, provider_models} ->
      allowed_models =
        Enum.filter(provider_models, fn model ->
          ReqLLM.Catalog.allowed_spec?(provider, model["id"])
        end)

      {provider, allowed_models}
    end)
    |> Enum.reject(fn {_provider, models} -> Enum.empty?(models) end)
    |> Enum.sort_by(fn {provider, _} -> provider end)
    |> Enum.each(fn {provider, provider_models} ->
      Mix.shell().info(
        IO.ANSI.cyan() <>
          IO.ANSI.bright() <>
          provider_name(provider) <> IO.ANSI.reset()
      )

      statuses = %{pass: 0, fail: 0, excluded: 0, untested: 0}

      statuses =
        provider_models
        |> Enum.sort_by(fn model -> model["id"] end)
        |> Enum.reduce(statuses, fn model, acc ->
          spec = "#{provider}:#{model["id"]}"
          model_id = model["id"]
          has_fixtures = has_fixtures?(provider, model_id)

          status =
            case Map.get(state, spec) do
              %{"status" => s} when has_fixtures -> s
              _ -> "untested"
            end

          print_model_status(model, spec, status)
          Map.update(acc, String.to_atom(status), 1, &(&1 + 1))
        end)

      total = length(provider_models)
      pass_pct = Float.round(statuses.pass / total * 100, 1)

      Mix.shell().info(
        "  " <>
          IO.ANSI.faint() <>
          "#{statuses.pass} pass, #{statuses.fail} fail, #{statuses.excluded} excluded, #{statuses.untested} untested | #{pass_pct}% coverage" <>
          IO.ANSI.reset()
      )

      Mix.shell().info("")
    end)

    total_models = models |> Enum.map(fn {_, ms} -> length(ms) end) |> Enum.sum()

    total_pass =
      state
      |> Enum.count(fn {spec, entry} ->
        case entry do
          %{"status" => "pass"} ->
            [provider, model_id] = String.split(spec, ":", parts: 2)
            has_fixtures?(String.to_atom(provider), model_id)

          _ ->
            false
        end
      end)

    total_pct = Float.round(total_pass / total_models * 100, 1)

    Mix.shell().info(
      "Overall Coverage: #{total_pass}/#{total_models} models validated (#{total_pct}%)\n"
    )
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

    run_ts = DateTime.utc_now() |> DateTime.truncate(:second)
    save_state(results, run_ts)

    print_summary(results, elapsed)
  end

  defp test_model(provider, model_id, opts) do
    spec = "#{provider}:#{model_id}"
    mode = if opts[:record_all] || opts[:record], do: "record", else: "replay"
    operation = parse_operation_type(opts[:type])
    category = operation_to_category(operation)

    # Propagate AWS credentials from current environment
    aws_env_vars =
      for key <- [
            "AWS_ACCESS_KEY_ID",
            "AWS_SECRET_ACCESS_KEY",
            "AWS_SESSION_TOKEN",
            "AWS_REGION",
            "AWS_DEFAULT_REGION"
          ],
          value = System.get_env(key),
          not is_nil(value) do
        {key, value}
      end

    env =
      [
        {"REQ_LLM_MODELS", spec},
        {"REQ_LLM_OPERATION", Atom.to_string(operation)},
        {"REQ_LLM_FIXTURES_MODE", mode},
        {"REQ_LLM_DEBUG", "1"},
        {"REQ_LLM_INCLUDE_RESPONSES", "1"}
      ] ++ aws_env_vars

    Mix.shell().info("  Testing #{spec} (#{operation})...")

    test_args =
      build_test_args(provider, category, operation)

    {output, exit_code} =
      System.cmd(
        "mix",
        test_args,
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

  defp build_test_args(provider, _category, operation) do
    case operation do
      :all ->
        ["test", "--only", "provider:#{provider}"]

      :embedding ->
        ["test", "test/coverage/#{provider}/embedding_test.exs", "--only", "provider:#{provider}"]

      :text ->
        [
          "test",
          "test/coverage/#{provider}/comprehensive_test.exs",
          "--only",
          "provider:#{provider}"
        ]
    end
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

      provider_results
      |> Enum.sort_by(& &1.model_id)
      |> Enum.each(&print_result/1)

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
    model_id = model["id"]
    has_fixtures = has_fixtures?(provider, model_id)

    status =
      case Map.get(state, model_spec) do
        %{"status" => s} when has_fixtures -> s
        _ -> nil
      end

    status_icon =
      case status do
        "pass" -> IO.ANSI.green() <> "✓" <> IO.ANSI.reset()
        "fail" -> IO.ANSI.red() <> "✗" <> IO.ANSI.reset()
        "excluded" -> IO.ANSI.yellow() <> "⊘" <> IO.ANSI.reset()
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

  defp print_model_status(model, _spec, status) do
    tier_color =
      case model["tier"] do
        "flagship" -> IO.ANSI.yellow()
        "fast" -> IO.ANSI.green()
        "experimental" -> IO.ANSI.magenta()
        _ -> ""
      end

    tier_text =
      if model["tier"], do: " #{tier_color}(#{model["tier"]})#{IO.ANSI.reset()}", else: ""

    {status_icon, status_color} =
      case status do
        "pass" -> {"✓", IO.ANSI.green()}
        "fail" -> {"✗", IO.ANSI.red()}
        "excluded" -> {"−", IO.ANSI.yellow()}
        "untested" -> {"?", IO.ANSI.faint()}
        _ -> {"?", IO.ANSI.faint()}
      end

    Mix.shell().info(
      "  #{status_color}#{status_icon}#{IO.ANSI.reset()} #{model["id"]}#{tier_text}"
    )
  end

  defp select_models(registry, raw_spec, opts) do
    operation = parse_operation_type(opts[:type])
    implemented = get_implemented_providers()

    candidates =
      if is_nil(raw_spec) do
        default_specs_for_operation(operation)
        |> Enum.map(&parse_spec_tuple/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.filter(fn {p, m} ->
          MapSet.member?(implemented, p) and model_in_registry?(registry, p, m)
        end)
      else
        registry
        |> expand_spec_to_candidates(raw_spec, implemented)
        |> Enum.filter(fn {p, m} ->
          model_supports_operation?(registry, p, m, operation)
        end)
      end

    final =
      if opts[:sample] do
        sample_set = sample_model_set(operation, registry, candidates)
        candidates |> Enum.filter(fn {p, m} -> MapSet.member?(sample_set, "#{p}:#{m}") end)
      else
        candidates
      end

    final |> Enum.uniq() |> Enum.sort()
  end

  defp default_specs_for_operation(:text) do
    Application.get_env(:req_llm, :sample_text_models, [])
  end

  defp default_specs_for_operation(:embedding) do
    Application.get_env(:req_llm, :sample_embedding_models, [])
  end

  defp default_specs_for_operation(:all) do
    Application.get_env(:req_llm, :sample_text_models, []) ++
      Application.get_env(:req_llm, :sample_embedding_models, [])
  end

  defp parse_spec_tuple(spec) when is_binary(spec) do
    case String.split(spec, ":", parts: 2) do
      [provider, model_id] -> {String.to_atom(provider), model_id}
      _ -> nil
    end
  end

  defp model_in_registry?(registry, provider, model_id) do
    find_model(registry, provider, model_id) != nil
  end

  defp model_supports_operation?(_registry, _p, _m, :all), do: true

  defp model_supports_operation?(registry, provider, model_id, :embedding) do
    case find_model(registry, provider, model_id) do
      nil -> false
      model -> embedding_model?(model)
    end
  end

  defp model_supports_operation?(registry, provider, model_id, :text) do
    case find_model(registry, provider, model_id) do
      nil -> false
      model -> not embedding_model?(model)
    end
  end

  defp embedding_model?(model) do
    t = Map.get(model, "type")
    outputs = get_in(model, ["modalities", "output"]) || []
    t == "embedding" or Enum.member?(outputs, "embedding")
  end

  defp expand_spec_to_candidates(registry, spec, implemented) do
    cond do
      is_nil(spec) or spec == "*:*" ->
        all_implemented_pairs(registry, implemented)

      String.contains?(spec, ":") ->
        [provider_part, model_part] = String.split(spec, ":", parts: 2)
        provider_atom = String.to_atom(provider_part)

        cond do
          not MapSet.member?(implemented, provider_atom) ->
            Mix.shell().info("  Skipping #{provider_part}: provider not implemented")
            []

          model_part == "*" ->
            pairs_for_provider(registry, provider_atom)

          String.ends_with?(model_part, "*") ->
            prefix = String.trim_trailing(model_part, "*")

            case Map.get(registry, provider_atom) do
              nil ->
                []

              models ->
                models
                |> Enum.filter(fn m -> String.starts_with?(m["id"], prefix) end)
                |> Enum.map(fn m -> {provider_atom, m["id"]} end)
            end

          true ->
            case find_model(registry, provider_atom, model_part) do
              nil ->
                Mix.shell().info("  Skipping #{provider_part}:#{model_part} (not in registry)")

                []

              _ ->
                [{provider_atom, model_part}]
            end
        end

      true ->
        provider_atom = String.to_atom(spec)

        if MapSet.member?(implemented, provider_atom) do
          pairs_for_provider(registry, provider_atom)
        else
          Mix.shell().info("  Skipping #{spec}: provider not implemented")
          []
        end
    end
  end

  defp all_implemented_pairs(registry, implemented) do
    registry
    |> Enum.flat_map(fn {provider, models} ->
      if MapSet.member?(implemented, provider) do
        models
        |> Enum.filter(fn m ->
          ReqLLM.Catalog.allowed_spec?(provider, m["id"])
        end)
        |> Enum.map(fn m -> {provider, m["id"]} end)
      else
        []
      end
    end)
  end

  defp pairs_for_provider(registry, provider) do
    case Map.get(registry, provider) do
      nil ->
        []

      models ->
        models
        |> Enum.filter(fn m ->
          ReqLLM.Catalog.allowed_spec?(provider, m["id"])
        end)
        |> Enum.map(fn m -> {provider, m["id"]} end)
    end
  end

  defp sample_model_set(operation, _registry, current_candidates) do
    cfg =
      case operation do
        :text ->
          Application.get_env(:req_llm, :sample_text_models, [])

        :embedding ->
          Application.get_env(:req_llm, :sample_embedding_models, [])

        :all ->
          Application.get_env(:req_llm, :sample_text_models, []) ++
            Application.get_env(:req_llm, :sample_embedding_models, [])
      end

    sample_specs =
      if cfg == [] do
        current_candidates
        |> Enum.group_by(fn {p, _m} -> p end)
        |> Enum.flat_map(fn {_provider, models} ->
          models
          |> Enum.sort_by(fn {_p, m} -> m end)
          |> Enum.take(1)
        end)
        |> Enum.map(fn {p, m} -> "#{p}:#{m}" end)
      else
        cfg
      end

    MapSet.new(sample_specs)
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
        Jason.decode!(content)

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

    excluded_models = load_excluded_models()

    ts = DateTime.to_iso8601(run_ts)

    new_state =
      results
      |> Enum.reject(&(&1.status == :skipped))
      |> Enum.reduce(existing, fn result, acc ->
        status = if result.status == :pass, do: "pass", else: "fail"

        Map.put(acc, result.model_spec, %{
          "status" => status,
          "last_checked" => ts
        })
      end)
      |> then(fn state ->
        Enum.reduce(excluded_models, state, fn spec, acc ->
          existing_entry = Map.get(existing, spec, %{})

          Map.put(acc, spec, %{
            "status" => "excluded",
            "last_checked" => Map.get(existing_entry, "last_checked")
          })
        end)
      end)

    json = build_sorted_json(new_state)

    case File.read(path) do
      {:ok, prev} when prev == json -> :ok
      _ -> File.write!(path, json)
    end
  end

  defp build_sorted_json(state) do
    entries_json =
      state
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.map_join(",\n  ", fn {k, v} ->
        status = Map.get(v, "status")
        last_checked = Map.get(v, "last_checked")

        last_checked_json =
          if last_checked,
            do: ~s("last_checked": "#{last_checked}"),
            else: ~s("last_checked": null)

        ~s("#{k}": {\n    "status": "#{status}",\n    #{last_checked_json}\n  })
      end)

    """
    {
      #{entries_json}
    }
    """
  end

  defp find_model(registry, provider, model_id) do
    provider_atom = if is_binary(provider), do: String.to_atom(provider), else: provider

    # Normalize model_id using provider's callback if available
    # This allows providers to handle model ID aliases (e.g., Bedrock inference profiles)
    normalized_model_id =
      case ReqLLM.Provider.Registry.get_provider(provider_atom) do
        {:ok, provider_module} when not is_nil(provider_module) ->
          if function_exported?(provider_module, :normalize_model_id, 1) do
            provider_module.normalize_model_id(model_id)
          else
            model_id
          end

        _ ->
          model_id
      end

    case Map.get(registry, provider_atom) do
      nil -> nil
      models -> Enum.find(models, fn m -> m["id"] == normalized_model_id end)
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

  defp get_implemented_providers do
    providers = ReqLLM.Provider.Registry.list_implemented_providers()
    MapSet.new(providers)
  end

  defp load_excluded_models do
    priv_dir = :code.priv_dir(:req_llm)
    patches_dir = Path.join(priv_dir, "models_local")

    if File.dir?(patches_dir) do
      patches_dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".json"))
      |> Enum.flat_map(fn filename ->
        path = Path.join(patches_dir, filename)

        case File.read(path) do
          {:ok, content} ->
            case Jason.decode(content) do
              {:ok, %{"provider" => %{"id" => provider_id}, "exclude" => exclusions}} ->
                Enum.map(exclusions, fn model_id -> "#{provider_id}:#{model_id}" end)

              _ ->
                []
            end

          _ ->
            []
        end
      end)
    else
      []
    end
  end

  defp parse_operation_type(nil), do: :text
  defp parse_operation_type("all"), do: :all
  defp parse_operation_type("text"), do: :text
  defp parse_operation_type("embedding"), do: :embedding
  defp parse_operation_type(type), do: String.to_atom(type)

  defp operation_to_category(:text), do: "core"
  defp operation_to_category(:embedding), do: "embedding"
  defp operation_to_category(_), do: "core"

  defp has_fixtures?(provider, model_id) do
    model_dir = model_id_to_fixture_dir(model_id)
    fixture_path = Path.join(["test", "support", "fixtures", to_string(provider), model_dir])

    if File.dir?(fixture_path) do
      case File.ls(fixture_path) do
        {:ok, files} ->
          files
          |> Enum.filter(&String.ends_with?(&1, ".json"))
          |> Enum.any?()

        {:error, _} ->
          false
      end
    else
      false
    end
  end

  defp model_id_to_fixture_dir(model_id) do
    model_id
    |> String.replace("-", "_")
    |> String.replace(".", "_")
    |> String.replace(":", "_")
    |> String.replace("/", "_")
  end
end
