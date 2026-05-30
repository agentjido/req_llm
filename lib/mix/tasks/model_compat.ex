defmodule Mix.Tasks.ReqLlm.ModelCompat do
  @shortdoc "Validate ReqLLM model coverage with fixture-based testing"
  @moduledoc """
  Validate ReqLLM model coverage using the fixture system.

  Models are sourced from LLMDB
  Fixture validation state is tracked in priv/supported_models.json (auto-generated).

  ## Selection Principles

  Models are selected using clear precedence: **spec → type → sample**

  - **spec**: Pattern over providers/models
    - When **no spec provided** (just `mix mc`): Uses default sets from config (`:test_models` or `:test_embedding_models`)
    - When **spec provided** (e.g., `"anthropic:*"`, `"*:*"`): Uses ALL matching models from registry
  - **type**: Filters by operation capability using registry metadata
    - `text` (default): Only text-generation models
    - `embedding`: Only embedding models
    - `image`, `speech`, `transcription`, `rerank`, `ocr`: Specialty operation models
    - `all`: All implemented registry models
  - **sample** (optional): Further reduces using `:sample_*_models` config.
    If not configured, falls back to one model per provider.

  **Important**:
  - Only **implemented providers** are included (registry models without implementation are skipped)
  - Config lists (`:sample_*_models`) are defaults only, not hard filters
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
      mix req_llm.model_compat "google:*" --type all        # Google models across operations
      mix req_llm.model_compat "google:*" --type embedding  # Google embedding models only
      mix req_llm.model_compat "openai:*" --type image      # OpenAI image models only
      mix req_llm.model_compat "elevenlabs:*" --type speech # ElevenLabs TTS models only
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
      --type TYPE        Operation type: text, embedding, image, speech, transcription, rerank, ocr, or all
      --record           Re-record fixtures (live API calls)
      --record-all       Force re-record all fixtures (ignores state)
      --update-state     Update generated compatibility state during replay checks
      --scenario LIST    Comma-separated scenario tags to run (e.g. basic,usage)
      --capability LIST  Comma-separated capability groups to run
      --max-concurrency N
      --debug            Enable verbose fixture debugging

  ## Notes

  - When no spec is provided (or `"*:*"` is used), only implemented providers are considered
  - If a spec refers to an unimplemented provider, it will be skipped with a warning
  - The final model list is deterministic and stable
  """

  use Mix.Task

  @preferred_cli_env :test
  @capability_scenarios %{
    "core" => ~w(basic usage token_limit),
    "conversation" => ~w(context_append),
    "streaming" => ~w(streaming),
    "tools" => ~w(tool_none tool_multi tool_round_trip),
    "objects" => ~w(object_basic object_streaming),
    "reasoning" => ~w(reasoning),
    "embedding" => ~w(embed_basic embed_usage embed_batch),
    "image" => ~w(image_basic),
    "speech" => ~w(speech_basic),
    "transcription" => ~w(transcription_basic),
    "rerank" => ~w(rerank_basic),
    "ocr" => ~w(ocr_basic),
    "grounding" => ~w(grounding_basic grounding_with_context grounding_streaming),
    "grounding_legacy" => ~w(grounding_legacy),
    "multimodal_tool_result" => ~w(multimodal_tool_result),
    "web_search" => ~w(web_search_basic web_search_streaming x_search_streaming),
    "streaming_structured_output" =>
      ~w(object_streaming_json_schema object_streaming_tool_strict object_streaming_auto streaming_error_handling)
  }

  @scenario_test_files %{
    google: %{
      "grounding_basic" => "test/coverage/google/grounding_test.exs",
      "grounding_with_context" => "test/coverage/google/grounding_test.exs",
      "grounding_streaming" => "test/coverage/google/grounding_test.exs",
      "grounding_legacy" => "test/coverage/google/grounding_test.exs",
      "multimodal_tool_result" => "test/coverage/google/multimodal_tool_result_test.exs"
    },
    xai: %{
      "web_search_basic" => "test/coverage/xai/web_search_test.exs",
      "web_search_streaming" => "test/coverage/xai/web_search_test.exs",
      "x_search_streaming" => "test/coverage/xai/web_search_test.exs",
      "object_streaming_json_schema" => "test/coverage/xai/streaming_structured_output_test.exs",
      "object_streaming_tool_strict" => "test/coverage/xai/streaming_structured_output_test.exs",
      "object_streaming_auto" => "test/coverage/xai/streaming_structured_output_test.exs",
      "streaming_error_handling" => "test/coverage/xai/streaming_structured_output_test.exs"
    }
  }

  @impl Mix.Task
  def run(args) do
    Application.ensure_all_started(:req_llm)
    # LLMDB.load(allow: :all, custom: %{})

    {opts, positional, _} =
      OptionParser.parse(args,
        switches: [
          sample: :boolean,
          available: :boolean,
          type: :string,
          record: :boolean,
          record_all: :boolean,
          update_state: :boolean,
          scenario: :string,
          capability: :string,
          max_concurrency: :integer,
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

  @doc false
  def scenarios_for_opts(opts, operation \\ :text) do
    scenarios = csv_values(opts[:scenario])

    capability_scenarios =
      opts[:capability]
      |> csv_values()
      |> Enum.flat_map(&capability_scenarios!/1)

    operation_capability = Atom.to_string(operation)

    operation_defaults =
      if opts[:capability] == operation_capability and
           Map.has_key?(@capability_scenarios, operation_capability) do
        Map.fetch!(@capability_scenarios, operation_capability)
      else
        []
      end

    (scenarios ++ capability_scenarios ++ operation_defaults)
    |> Enum.uniq()
  end

  @doc false
  def capability_scenarios!(capability) when is_binary(capability) do
    case Map.fetch(@capability_scenarios, capability) do
      {:ok, scenarios} -> scenarios
      :error -> Mix.raise("Unknown capability group: #{capability}")
    end
  end

  @doc false
  def state_update?(opts), do: opts[:record_all] || opts[:record] || opts[:update_state]

  defp list_models(opts) do
    models = load_registry()
    state = load_state()
    operation = parse_operation_type(opts[:type])
    sample_specs = if opts[:sample], do: default_specs_for_operation(operation)
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
      {provider, provider_models}
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

  defp do_run_coverage(model_spec, opts) when is_binary(model_spec) do
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
        max_concurrency: max_concurrency(opts),
        timeout: :infinity,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    elapsed = System.monotonic_time(:millisecond) - start_time

    if state_update?(opts) do
      run_ts = DateTime.utc_now() |> DateTime.truncate(:second)
      save_state(results, run_ts, opts)
    end

    print_enhanced_summary(model_spec, results, models, elapsed, opts)
  end

  defp do_run_coverage(nil, opts) do
    Mix.shell().info("\n----------------------------------------------------")
    Mix.shell().info(header(opts[:sample]))
    Mix.shell().info("----------------------------------------------------\n")

    models = load_registry()
    specs = select_models(models, nil, opts)

    if Enum.empty?(specs) do
      Mix.raise("No models match spec")
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
        max_concurrency: max_concurrency(opts),
        timeout: :infinity,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    elapsed = System.monotonic_time(:millisecond) - start_time

    if state_update?(opts) do
      run_ts = DateTime.utc_now() |> DateTime.truncate(:second)
      save_state(results, run_ts, opts)
    end

    print_summary(results, elapsed)
  end

  defp test_model(provider, model_id, opts) do
    scenarios = scenarios_for_opts(opts, parse_operation_type(opts[:type]))

    if Enum.empty?(scenarios) do
      run_test_invocation(provider, model_id, opts, nil)
    else
      scenarios
      |> Enum.map(&run_test_invocation(provider, model_id, opts, &1))
      |> aggregate_scenario_results(provider, model_id)
    end
  end

  defp run_test_invocation(provider, model_id, opts, scenario) do
    spec = "#{provider}:#{model_id}"
    mode = if opts[:record_all] || opts[:record], do: "record", else: "replay"
    operation = parse_operation_type(opts[:type])
    category = operation_to_category(operation)
    recording = opts[:record_all] || opts[:record]
    stage_dir = if recording, do: staged_fixture_dir(provider, model_id, scenario)

    cloud_env_vars =
      for key <- [
            "AWS_ACCESS_KEY_ID",
            "AWS_SECRET_ACCESS_KEY",
            "AWS_SESSION_TOKEN",
            "AWS_REGION",
            "AWS_DEFAULT_REGION",
            "AZURE_OPENAI_API_KEY",
            "AZURE_OPENAI_BASE_URL",
            "AZURE_ANTHROPIC_API_KEY",
            "AZURE_ANTHROPIC_BASE_URL",
            "AZURE_API_KEY",
            "AZURE_BASE_URL"
          ],
          value = System.get_env(key),
          not is_nil(value) do
        {key, value}
      end

    env =
      ([
         {"REQ_LLM_MODELS", spec},
         {"REQ_LLM_OPERATION", Atom.to_string(operation)},
         {"REQ_LLM_FIXTURES_MODE", mode},
         {"REQ_LLM_DEBUG", "1"},
         {"REQ_LLM_INCLUDE_RESPONSES", "1"},
         {"REQ_LLM_FIXTURE_ALLOW_CREDENTIAL_FALLBACK", "0"}
       ] ++ cloud_env_vars)
      |> maybe_put_record_root(stage_dir)

    display_spec =
      case LLMDB.model(spec) do
        {:ok, %LLMDB.Model{id: resolved_id}} when resolved_id != model_id ->
          "#{spec} " <> IO.ANSI.faint() <> "(#{resolved_id})" <> IO.ANSI.reset()

        _ ->
          spec
      end

    scenario_text = if scenario, do: ", scenario=#{scenario}", else: ""
    Mix.shell().info("  Testing #{display_spec} (#{operation}#{scenario_text})...")

    test_args =
      build_test_args(provider, category, operation, scenario)

    {output, exit_code} =
      System.cmd(
        "mix",
        test_args,
        env: env,
        stderr_to_stdout: true
      )
      |> maybe_promote_staged_fixtures(stage_dir)

    if opts[:debug] do
      Mix.shell().info("\n--- Debug Output for #{spec} ---")
      Mix.shell().info(output)
      Mix.shell().info("--- End Debug Output ---\n")
    end

    parse_test_result(provider, model_id, output, exit_code, scenario)
  end

  @doc false
  def test_args_for(provider, operation, scenario \\ nil) do
    provider = normalize_provider(provider)

    args =
      scenario_test_args(provider, scenario) || base_test_args(provider, operation)

    if scenario do
      args ++ ["--only", "scenario:#{scenario}"]
    else
      args ++ ["--only", "provider:#{provider}"]
    end
  end

  defp build_test_args(provider, _category, operation, scenario) do
    test_args_for(provider, operation, scenario)
  end

  defp scenario_test_args(_provider, nil), do: nil

  defp scenario_test_args(provider, scenario) do
    provider
    |> then(&Map.get(@scenario_test_files, &1, %{}))
    |> Map.get(to_string(scenario))
    |> case do
      nil -> nil
      path -> ["test", path]
    end
  end

  defp normalize_provider(provider) when is_atom(provider), do: provider
  defp normalize_provider(provider) when is_binary(provider), do: String.to_atom(provider)

  defp base_test_args(provider, :all) do
    ["test", "test/coverage/#{provider}"]
  end

  defp base_test_args(provider, :embedding) do
    ["test", "test/coverage/#{provider}/embedding_test.exs"]
  end

  defp base_test_args(provider, :image) do
    ["test", "test/coverage/#{provider}/image_generation_test.exs"]
  end

  defp base_test_args(provider, :speech) do
    ["test", "test/coverage/#{provider}/speech_test.exs"]
  end

  defp base_test_args(provider, :transcription) do
    ["test", "test/coverage/#{provider}/transcription_test.exs"]
  end

  defp base_test_args(provider, :rerank) do
    ["test", "test/coverage/#{provider}/rerank_test.exs"]
  end

  defp base_test_args(provider, :ocr) do
    ["test", "test/coverage/#{provider}/ocr_test.exs"]
  end

  defp base_test_args(provider, :text) do
    ["test", "test/coverage/#{provider}/comprehensive_test.exs"]
  end

  defp parse_test_result(provider, model_id, output, exit_code, scenario) do
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
      fixtures: fixtures,
      scenario: scenario
    }
  end

  defp aggregate_scenario_results(results, provider, model_id) do
    status =
      if Enum.all?(results, &(&1.status == :pass)) do
        :pass
      else
        :fail
      end

    scenarios =
      Enum.map(results, fn result ->
        %{
          "scenario" => result.scenario,
          "status" => Atom.to_string(result.status),
          "fixtures" => result.fixtures,
          "error" => result.error
        }
      end)

    errors =
      results
      |> Enum.map(& &1.error)
      |> Enum.reject(&is_nil/1)

    %{
      provider: provider,
      model_id: model_id,
      model_spec: "#{provider}:#{model_id}",
      status: status,
      passed: Enum.reduce(results, 0, &(&1.passed + &2)),
      failed: Enum.reduce(results, 0, &(&1.failed + &2)),
      total: Enum.reduce(results, 0, &(&1.total + &2)),
      error: if(errors == [], do: nil, else: Enum.join(errors, "\n")),
      fixtures:
        results
        |> Enum.flat_map(& &1.fixtures)
        |> Enum.uniq(),
      scenarios: scenarios
    }
  end

  defp csv_values(nil), do: []

  defp csv_values(value) when is_binary(value) do
    value
    |> String.split([",", " "], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp max_concurrency(opts) do
    cond do
      is_integer(opts[:max_concurrency]) and opts[:max_concurrency] > 0 ->
        opts[:max_concurrency]

      opts[:record_all] || opts[:record] ->
        1

      true ->
        System.schedulers_online() * 2
    end
  end

  defp staged_fixture_dir(provider, model_id, scenario) do
    suffix =
      [to_string(provider), model_id, scenario || "all", System.unique_integer([:positive])]
      |> Enum.map(&to_string/1)
      |> Enum.map_join("_", &fixture_path_slug/1)

    Path.join(System.tmp_dir!(), "req_llm_fixture_record_#{suffix}")
  end

  defp maybe_put_record_root(env, nil), do: env

  defp maybe_put_record_root(env, stage_dir) do
    [{"REQ_LLM_FIXTURE_RECORD_ROOT", stage_dir} | env]
  end

  defp maybe_promote_staged_fixtures({output, exit_code}, nil), do: {output, exit_code}

  defp maybe_promote_staged_fixtures({output, 0}, stage_dir) do
    files = staged_fixture_files(stage_dir)

    if files == [] do
      File.rm_rf(stage_dir)
      {output <> "\n[Fixture] ERROR no fixture files were recorded\n", 1}
    else
      Enum.each(files, &promote_staged_fixture(stage_dir, &1))
      File.rm_rf(stage_dir)
      {output <> promoted_fixture_output(files), 0}
    end
  rescue
    error ->
      File.rm_rf(stage_dir)
      {output <> "\n[Fixture] ERROR staging promotion failed: #{inspect(error)}\n", 1}
  end

  defp maybe_promote_staged_fixtures({output, exit_code}, stage_dir) do
    File.rm_rf(stage_dir)
    {output, exit_code}
  end

  defp staged_fixture_files(stage_dir) do
    if File.dir?(stage_dir) do
      stage_dir
      |> Path.join("**/*.json")
      |> Path.wildcard()
    else
      []
    end
  end

  defp promote_staged_fixture(stage_dir, staged_path) do
    relative = Path.relative_to(staged_path, stage_dir)
    target = Path.join(fixture_path_root(), relative)
    target |> Path.dirname() |> File.mkdir_p!()
    File.cp!(staged_path, target)
  end

  defp fixture_path_root do
    Path.expand("test/support/fixtures")
  end

  defp fixture_path_slug(model_name) when is_binary(model_name) do
    model_name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "_")
    |> String.trim("_")
  end

  defp promoted_fixture_output(files) do
    files
    |> Enum.map(&Path.basename(&1, ".json"))
    |> Enum.sort()
    |> Enum.map_join("", &"\n[Fixture] promoted: name=#{&1}")
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
    |> Enum.filter(&String.contains?(&1, ["[Fixture] step:", "[Fixture] promoted:"]))
    |> Enum.map(fn line ->
      case Regex.run(~r/name=(\w+)/, line) do
        [_, name] -> name
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp print_enhanced_summary(model_spec, results, registry, elapsed_ms, opts) do
    Mix.shell().info("\n" <> String.duplicate("━", 60))
    Mix.shell().info("  Enhanced Coverage Report")
    Mix.shell().info(String.duplicate("━", 60) <> "\n")

    state = load_state()
    operation = parse_operation_type(opts[:type])

    all_matching_models = collect_all_matching_models(model_spec, registry, operation)

    all_matching_models
    |> Enum.group_by(fn {provider, _model_id, _model_data} -> provider end)
    |> Enum.sort_by(fn {provider, _} -> provider end)
    |> Enum.each(fn {provider, provider_models} ->
      print_provider_enhanced_section(provider, provider_models, results, state)
    end)

    print_overall_coverage_stats(all_matching_models, results, state, elapsed_ms)
  end

  defp collect_all_matching_models(model_spec, registry, operation) do
    registry
    |> Enum.flat_map(fn {provider, models} ->
      models
      |> Enum.filter(fn model ->
        model_matches_spec?(provider, model["id"], model_spec) and
          model_supports_operation?(registry, provider, model["id"], operation)
      end)
      |> Enum.map(fn model -> {provider, model["id"], model} end)
    end)
  end

  defp model_matches_spec?(provider, model_id, spec) do
    cond do
      spec == "*:*" ->
        true

      String.contains?(spec, ":") ->
        [provider_part, model_part] = String.split(spec, ":", parts: 2)
        provider_atom = String.to_atom(provider_part)

        cond do
          provider != provider_atom ->
            false

          model_part == "*" ->
            true

          String.ends_with?(model_part, "*") ->
            prefix = String.trim_trailing(model_part, "*")
            String.starts_with?(model_id, prefix)

          true ->
            model_id == model_part
        end

      true ->
        provider == String.to_atom(spec)
    end
  end

  defp print_provider_enhanced_section(provider, provider_models, results, state) do
    Mix.shell().info(
      IO.ANSI.cyan() <>
        IO.ANSI.bright() <>
        provider_name(provider) <>
        " (#{length(provider_models)} models)" <>
        IO.ANSI.reset()
    )

    Mix.shell().info(String.duplicate("━", 60) <> "\n")

    grouped = group_models_by_status(provider_models, results, state)

    print_group("PASSING FIXTURES", grouped.passing, :pass)
    print_group("FAILING FIXTURES", grouped.failing, :fail)
    print_group("UNTESTED", grouped.untested, :untested)
    print_group("RETIRED", grouped.retired, :retired)

    print_provider_summary(grouped)
    Mix.shell().info("")
  end

  defp group_models_by_status(provider_models, results, state) do
    results_map = Map.new(results, fn r -> {{r.provider, r.model_id}, r} end)

    provider_models
    |> Enum.reduce(%{passing: [], failing: [], untested: [], retired: []}, fn {provider, model_id,
                                                                               model_data},
                                                                              acc ->
      spec = "#{provider}:#{model_id}"

      case fetch_model_metadata(spec) do
        {:ok, llmdb_model} ->
          lifecycle_status = get_lifecycle_status(llmdb_model)

          cond do
            lifecycle_status == :retired ->
              %{acc | retired: [{provider, model_id, model_data, llmdb_model} | acc.retired]}

            Map.has_key?(results_map, {provider, model_id}) ->
              result = Map.get(results_map, {provider, model_id})

              if result.status == :pass do
                %{
                  acc
                  | passing: [{provider, model_id, model_data, llmdb_model, result} | acc.passing]
                }
              else
                %{
                  acc
                  | failing: [{provider, model_id, model_data, llmdb_model, result} | acc.failing]
                }
              end

            Map.has_key?(state, spec) ->
              state_entry = Map.get(state, spec)

              if state_entry["status"] == "pass" and has_fixtures?(provider, model_id) do
                %{
                  acc
                  | passing: [{provider, model_id, model_data, llmdb_model, nil} | acc.passing]
                }
              else
                %{acc | untested: [{provider, model_id, model_data, llmdb_model} | acc.untested]}
              end

            true ->
              %{acc | untested: [{provider, model_id, model_data, llmdb_model} | acc.untested]}
          end

        {:error, _} ->
          if Map.has_key?(results_map, {provider, model_id}) do
            result = Map.get(results_map, {provider, model_id})

            if result.status == :pass do
              %{acc | passing: [{provider, model_id, model_data, nil, result} | acc.passing]}
            else
              %{acc | failing: [{provider, model_id, model_data, nil, result} | acc.failing]}
            end
          else
            %{acc | untested: [{provider, model_id, model_data, nil} | acc.untested]}
          end
      end
    end)
    |> Map.update!(:passing, &Enum.reverse/1)
    |> Map.update!(:failing, &Enum.reverse/1)
    |> Map.update!(:untested, &Enum.reverse/1)
    |> Map.update!(:retired, &Enum.reverse/1)
  end

  defp print_group(_title, [], _status), do: :ok

  defp print_group(title, models, status) do
    Mix.shell().info(IO.ANSI.bright() <> title <> " (#{length(models)}):" <> IO.ANSI.reset())

    Enum.each(models, fn item ->
      case item do
        {_provider, model_id, _model_data, llmdb_model, result} when status == :pass ->
          print_model_entry(model_id, llmdb_model, result, "✓", IO.ANSI.green())

        {_provider, model_id, _model_data, llmdb_model, result} when status == :fail ->
          print_model_entry(model_id, llmdb_model, result, "✗", IO.ANSI.red())

        {_provider, model_id, _model_data, llmdb_model} when status == :untested ->
          print_model_entry(model_id, llmdb_model, nil, "○", IO.ANSI.yellow())

        {_provider, model_id, _model_data, llmdb_model} when status == :retired ->
          print_model_entry(model_id, llmdb_model, nil, "❌", IO.ANSI.faint())
      end
    end)

    Mix.shell().info("")
  end

  defp print_model_entry(model_id, llmdb_model, result, icon, color) do
    lifecycle_info = format_lifecycle_info(llmdb_model)

    Mix.shell().info("  #{color}#{icon}#{IO.ANSI.reset()} #{model_id}#{lifecycle_info}")

    if llmdb_model do
      if llmdb_model.aliases && not Enum.empty?(llmdb_model.aliases) do
        aliases_text = Enum.join(llmdb_model.aliases, ", ")
        Mix.shell().info("      #{IO.ANSI.faint()}aliases: #{aliases_text}#{IO.ANSI.reset()}")
      end

      if llmdb_model.lifecycle do
        replacement = Map.get(llmdb_model.lifecycle, :replacement)

        if replacement do
          Mix.shell().info(
            "      #{IO.ANSI.faint()}replacement: #{replacement}#{IO.ANSI.reset()}"
          )
        end
      end
    end

    if result do
      if result.fixtures && !Enum.empty?(result.fixtures) do
        fixtures_text = Enum.join(result.fixtures, ", ")

        last_tested =
          if result[:last_checked], do: " | last tested: #{result[:last_checked]}", else: ""

        Mix.shell().info(
          "      #{IO.ANSI.faint()}fixtures: #{length(result.fixtures)} (#{fixtures_text})#{last_tested}#{IO.ANSI.reset()}"
        )
      end

      if result.error do
        Mix.shell().info("      #{IO.ANSI.faint()}#{result.error}#{IO.ANSI.reset()}")
      end
    end
  end

  defp format_lifecycle_info(nil), do: ""

  defp format_lifecycle_info(llmdb_model) do
    case llmdb_model.lifecycle do
      %{status: "deprecated", retires_at: retires_at} when not is_nil(retires_at) ->
        " #{IO.ANSI.yellow()}(deprecated, retires #{retires_at})#{IO.ANSI.reset()}"

      %{status: "deprecated"} ->
        " #{IO.ANSI.yellow()}(deprecated)#{IO.ANSI.reset()}"

      %{status: "retired", retires_at: retires_at} when not is_nil(retires_at) ->
        " #{IO.ANSI.faint()}(retired #{retires_at})#{IO.ANSI.reset()}"

      %{status: "retired"} ->
        " #{IO.ANSI.faint()}(retired)#{IO.ANSI.reset()}"

      _ ->
        ""
    end
  end

  defp print_provider_summary(grouped) do
    active_count = length(grouped.passing) + length(grouped.failing) + length(grouped.untested)

    if active_count > 0 do
      coverage_pct = Float.round(length(grouped.passing) / active_count * 100, 1)

      Mix.shell().info(
        IO.ANSI.bright() <>
          "Summary: #{length(grouped.passing)}/#{active_count} active models tested (#{coverage_pct}% coverage)" <>
          IO.ANSI.reset()
      )
    end
  end

  defp print_overall_coverage_stats(all_models, results, _state, elapsed_ms) do
    total_active =
      Enum.count(all_models, fn {provider, model_id, _} ->
        case fetch_model_metadata("#{provider}:#{model_id}") do
          {:ok, model} -> get_lifecycle_status(model) != :retired
          _ -> true
        end
      end)

    passing = Enum.count(results, &(&1.status == :pass))

    if total_active > 0 do
      pct = Float.round(passing / total_active * 100, 1)
      color = if pct == 100.0, do: IO.ANSI.green(), else: IO.ANSI.yellow()
      elapsed_sec = Float.round(elapsed_ms / 1000, 1)

      Mix.shell().info(String.duplicate("━", 60))

      Mix.shell().info(
        color <>
          "Overall Coverage: #{passing}/#{total_active} active models passing (#{pct}%)" <>
          IO.ANSI.reset() <> " in #{elapsed_sec}s\n"
      )

      if passing != length(results), do: System.halt(1)
    end
  end

  defp fetch_model_metadata(spec) do
    LLMDB.model(spec)
  end

  defp get_lifecycle_status(%LLMDB.Model{lifecycle: nil}), do: :active
  defp get_lifecycle_status(%LLMDB.Model{lifecycle: %{status: "retired"}}), do: :retired
  defp get_lifecycle_status(%LLMDB.Model{lifecycle: %{status: "deprecated"}}), do: :deprecated
  defp get_lifecycle_status(%LLMDB.Model{}), do: :active

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

    final
    |> Enum.map(&canonical_pair(registry, &1))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp default_specs_for_operation(:text) do
    Application.get_env(:req_llm, :sample_text_models, [])
  end

  defp default_specs_for_operation(:embedding) do
    Application.get_env(:req_llm, :sample_embedding_models, [])
  end

  defp default_specs_for_operation(:image) do
    Application.get_env(:req_llm, :sample_image_models, [])
  end

  defp default_specs_for_operation(:speech) do
    Application.get_env(:req_llm, :sample_speech_models, [])
  end

  defp default_specs_for_operation(:transcription) do
    Application.get_env(:req_llm, :sample_transcription_models, [])
  end

  defp default_specs_for_operation(:rerank) do
    Application.get_env(:req_llm, :sample_rerank_models, [])
  end

  defp default_specs_for_operation(:ocr) do
    Application.get_env(:req_llm, :sample_ocr_models, [])
  end

  defp default_specs_for_operation(:all) do
    Application.get_env(:req_llm, :sample_text_models, []) ++
      Application.get_env(:req_llm, :sample_embedding_models, []) ++
      Application.get_env(:req_llm, :sample_image_models, []) ++
      Application.get_env(:req_llm, :sample_speech_models, []) ++
      Application.get_env(:req_llm, :sample_transcription_models, []) ++
      Application.get_env(:req_llm, :sample_rerank_models, []) ++
      Application.get_env(:req_llm, :sample_ocr_models, [])
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

  defp model_supports_operation?(registry, provider, model_id, operation) do
    case find_model(registry, provider, model_id) do
      nil -> false
      model -> ReqLLM.ModelOperation.supported?(model, operation)
    end
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

              model ->
                [{provider_atom, model["id"]}]
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
        |> Enum.map(fn m -> {provider, m["id"]} end)
    end
  end

  defp sample_model_set(operation, _registry, current_candidates) do
    cfg =
      case operation do
        operation
        when operation in [:text, :embedding, :image, :speech, :transcription, :rerank, :ocr] ->
          Application.get_env(:req_llm, ReqLLM.ModelOperation.config_key(operation), [])

        :all ->
          default_specs_for_operation(:all)
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

  defp canonical_pair(registry, {provider, model_id}) do
    case find_model(registry, provider, model_id) do
      %{"id" => canonical_id} -> {provider, canonical_id}
      _ -> {provider, model_id}
    end
  end

  defp filter_by_specs(models, _provider, nil), do: models

  defp filter_by_specs(models, provider, specs) do
    Enum.filter(models, fn model ->
      Enum.member?(specs, "#{provider}:#{model["id"]}")
    end)
  end

  defp load_registry do
    LLMDB.providers()
    |> Enum.map(fn provider ->
      models =
        LLMDB.models(provider.id)
        |> Enum.map(fn model ->
          tier = extract_tier(model.tags)

          %{
            "id" => model.id,
            "provider" => model.provider,
            "type" => infer_type(model),
            "tier" => tier,
            "modalities" => model.modalities,
            "capabilities" => model.capabilities,
            "family" => model.family,
            "provider_model_id" => model.provider_model_id
          }
        end)

      {provider.id, models}
    end)
    |> Enum.reject(fn {_, models} -> Enum.empty?(models) end)
    |> Map.new()
  end

  defp infer_type(model) do
    ReqLLM.ModelOperation.type(model)
  end

  defp extract_tier(tags) when is_list(tags) do
    Enum.find_value(tags, fn tag ->
      case tag do
        "tier:" <> tier -> tier
        _ -> nil
      end
    end)
  end

  defp extract_tier(_), do: nil

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

  defp save_state(results, run_ts, opts) do
    if Enum.any?(results, &Map.has_key?(&1, :scenarios)) or scenarios_for_opts(opts) != [] do
      save_scenario_state(results, run_ts, opts)
    else
      save_model_state(results, run_ts)
    end
  end

  defp save_model_state(results, run_ts) do
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

  defp save_scenario_state(results, run_ts, opts) do
    priv_dir = :code.priv_dir(:req_llm)
    path = Path.join(priv_dir, "model_compat_scenarios.json")

    existing =
      case File.read(path) do
        {:ok, content} -> Jason.decode!(content)
        _ -> %{}
      end

    ts = DateTime.to_iso8601(run_ts)
    mode = if opts[:record_all] || opts[:record], do: "record", else: "replay"

    new_state =
      Enum.reduce(results, existing, fn result, acc ->
        scenarios = Map.get(result, :scenarios) || scenario_entries_for_result(result)

        Enum.reduce(scenarios, acc, fn scenario, scenario_acc ->
          put_scenario_state(scenario_acc, result.model_spec, scenario, ts, mode)
        end)
      end)

    json = Jason.encode!(new_state, pretty: true)

    case File.read(path) do
      {:ok, prev} when prev == json -> :ok
      _ -> File.write!(path, json)
    end
  end

  defp scenario_entries_for_result(%{scenario: nil}), do: []

  defp scenario_entries_for_result(result) do
    [
      %{
        "scenario" => result.scenario,
        "status" => Atom.to_string(result.status),
        "fixtures" => result.fixtures,
        "error" => result.error
      }
    ]
  end

  defp put_scenario_state(state, model_spec, scenario, ts, mode) do
    scenario_name = scenario["scenario"]

    model_state =
      state
      |> Map.get(model_spec, %{})
      |> Map.put_new("scenarios", %{})

    scenario_state = %{
      "status" => scenario["status"],
      "last_checked" => ts,
      "mode" => mode,
      "fixtures" => scenario["fixtures"] || [],
      "error" => scenario["error"]
    }

    updated_model_state =
      put_in(model_state, ["scenarios", scenario_name], scenario_state)

    Map.put(state, model_spec, updated_model_state)
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

    # Use LLMDB to resolve aliases and get canonical model ID
    normalized_model_id =
      case LLMDB.model("#{provider_atom}:#{model_id}") do
        {:ok, %LLMDB.Model{id: resolved_id}} -> resolved_id
        {:error, _} -> model_id
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
    providers = ReqLLM.Providers.list()
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

  defp parse_operation_type(type) do
    operation = ReqLLM.ModelOperation.normalize(type)

    if ReqLLM.ModelOperation.known?(operation) do
      operation
    else
      Mix.raise(
        "Unknown operation type: #{inspect(type)}. Expected one of: #{Enum.join(ReqLLM.ModelOperation.names(), ", ")}"
      )
    end
  end

  defp operation_to_category(operation), do: ReqLLM.ModelOperation.category(operation)

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
