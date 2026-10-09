defmodule ReqLLM.Test.Billing.CLI do
  @moduledoc false

  alias ReqLLM.Test.Billing.{Audit, Cases, Money, Reference, Run}

  @switches [
    case: :string,
    model: :string,
    provider: :string,
    layer: :string,
    mode: :string,
    budget_usd: :string,
    max_requests: :integer,
    output: :string,
    run: :string
  ]
  @command_options %{
    "list" => [],
    "check" => [:case, :model, :provider, :layer, :output],
    "record" => [:case, :model, :provider, :mode, :budget_usd, :max_requests, :output],
    "audit" => [:run, :case, :model, :provider, :layer, :mode],
    "promote" => [:run, :case]
  }

  def parse!(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)
    unless invalid == [], do: raise(ArgumentError, "unknown billing options: #{inspect(invalid)}")

    command =
      case positional do
        [] -> "check"
        [value] when value in ~w(list check record audit promote) -> value
        _ -> raise ArgumentError, "billing command must be list, check, record, audit, or promote"
      end

    unless Enum.all?(Keyword.keys(opts), &(&1 in @command_options[command])),
      do: raise(ArgumentError, "unsupported options for billing #{command}")

    ids = csv(opts[:case])
    Enum.each(ids, &Cases.fetch!/1)

    if opts[:provider] && opts[:provider] not in ~w(openai anthropic openrouter),
      do: raise(ArgumentError, "unsupported billing provider")

    if opts[:layer] && opts[:layer] not in Cases.layers(),
      do: raise(ArgumentError, "unknown billing layer")

    if opts[:mode] && opts[:mode] not in ~w(buffered streamed both),
      do: raise(ArgumentError, "invalid billing mode")

    if opts[:provider] &&
         Enum.any?(csv(opts[:model]), &(not String.starts_with?(&1, opts[:provider] <> ":"))),
       do: raise(ArgumentError, "model selection conflicts with --provider")

    if command in ~w(audit promote) and is_nil(opts[:run]),
      do: raise(ArgumentError, "#{command} requires --run")

    if command == "promote" and ids == [], do: raise(ArgumentError, "promotion requires --case")
    if command == "record", do: validate_record!(opts, ids)
    %{command: command, opts: opts, cases: ids, models: csv(opts[:model])}
  end

  def run(args) do
    Application.ensure_all_started(:req_llm)
    config = parse!(args)
    dispatch(config)
  rescue
    error in [ArgumentError, KeyError, File.Error] -> Mix.raise(Exception.message(error))
  end

  def command(config, run_dir) do
    recording = config.command == "record"

    path =
      case config.command do
        "record" -> "test/coverage/billing"
        "audit" -> "test/req_llm/billing/run_audit_test.exs"
        _ -> "test/req_llm/billing"
      end

    args = [
      "test",
      path,
      "--only",
      if(config.opts[:layer], do: "billing_layer:#{config.opts[:layer]}", else: "billing"),
      "--max-cases",
      "1",
      "--seed",
      "0",
      "--formatter",
      "ExUnit.CLIFormatter",
      "--formatter",
      "ReqLLM.Test.Billing.Formatter"
    ]

    args = if recording, do: args ++ ["--include", "coverage"], else: args

    env = [
      {"MIX_ENV", "test"},
      {"REQ_LLM_FIXTURES_MODE", if(recording, do: "record", else: "replay")},
      {"REQ_LLM_FIXTURE_ALLOW_CREDENTIAL_FALLBACK", "0"},
      {"REQ_LLM_BILLING_MODE",
       if(config.command == "audit",
         do: "audit",
         else: if(recording, do: "record", else: "check")
       )},
      {"REQ_LLM_BILLING_RUN", Path.expand(run_dir)},
      {"REQ_LLM_BILLING_CASES", Enum.join(config.cases, ",")},
      {"REQ_LLM_BILLING_PROVIDER", config.opts[:provider] || ""},
      {"REQ_LLM_BILLING_MODELS", Enum.join(config.models, ",")},
      {"REQ_LLM_BILLING_STREAM_MODE", config.opts[:mode] || "both"},
      {"REQ_LLM_FIXTURE_RECORD_ROOT", Path.join(Path.expand(run_dir), "transcripts")}
    ]

    {args, env}
  end

  def require_case_rates!(id, pricing) when id in ~w(cache_1h mixed_cache_ttl) do
    unless Enum.any?(pricing[:components] || [], fn component ->
             String.starts_with?(component[:id] || "", "token.cache_write") and
               get_in(component, [:applies_when, "cache_ttl"]) == "1h"
           end),
           do: raise(ArgumentError, "#{id} requires duration-specific one-hour catalog rates")

    :ok
  end

  def require_case_rates!(_id, _pricing), do: :ok

  defp dispatch(%{command: "list"}) do
    Enum.each(Cases.all(), fn item ->
      Mix.shell().info(
        "#{item.id}: #{Enum.join(item.providers, ", ")} / #{Enum.join(item.phases, ", ")}"
      )
    end)
  end

  defp dispatch(%{command: "audit", opts: opts} = config) do
    dir = Path.expand(opts[:run])
    manifest = Run.load!(dir)
    if manifest["attempts"] == [], do: raise(ArgumentError, "no billing attempts were recorded")

    validate_audit!(config, manifest)
    {args, env} = command(config, dir)
    Mix.shell().info("Billing evidence: #{dir}")
    {_, code} = System.cmd("mix", args, env: env, stderr_to_stdout: true, into: IO.stream())
    results = Run.load!(dir)["results"] |> Enum.drop(length(manifest["results"]))

    if code != 0 or results == [] or not Enum.all?(results, &(&1["status"] == "passed")),
      do: Mix.raise("billing audit failed or matched no tests; evidence retained at #{dir}")
  end

  defp dispatch(%{command: "promote", opts: opts, cases: cases}) do
    Enum.each(Audit.promote!(Path.expand(opts[:run]), cases), &Mix.shell().info("Promoted #{&1}"))
  end

  defp dispatch(config) do
    dir = config.opts[:output] || default_output()

    selection =
      if config.command == "record",
        do: Cases.select(config.cases, config.models, config.opts[:mode] || "both"),
        else: []

    limits =
      if config.command == "record",
        do: [
          origin: "live",
          budget_micros: decimal_micros(config.opts[:budget_usd]),
          max_requests: config.opts[:max_requests]
        ],
        else: [origin: "replay"]

    dir = Run.create!(dir, selection, limits)
    Mix.shell().info("Billing evidence: #{dir}")
    if config.command == "record", do: Mix.shell().info("Live selection: #{inspect(selection)}")
    {args, env} = command(config, dir)
    {_, code} = System.cmd("mix", args, env: env, stderr_to_stdout: true, into: IO.stream())
    manifest = Run.load!(dir)

    if manifest["results"] == [],
      do: Mix.raise("no billing tests matched; evidence retained at #{dir}")

    if config.cases != [] and
         not Enum.all?(config.cases, fn id ->
           Enum.any?(manifest["results"], &(&1["case_id"] == id))
         end),
       do: Mix.raise("some selected billing cases had no tests; evidence retained at #{dir}")

    if config.models != [] and
         not Enum.all?(config.models, fn model ->
           Enum.any?(manifest["results"], &(&1["model"] == model))
         end),
       do: Mix.raise("some selected models had no tests; evidence retained at #{dir}")

    if config.command == "record" and manifest["attempts"] != [] do
      if code == 0,
        do: dispatch(%{config | command: "audit", opts: Keyword.put(config.opts, :run, dir)}),
        else: Audit.check!(dir)
    end

    Run.summary!(dir)

    if code != 0 or Run.load!(dir)["status"] != "passed",
      do: Mix.raise("billing checks failed or were blocked; evidence retained at #{dir}")
  end

  defp validate_audit!(config, manifest) do
    selected =
      Enum.filter(manifest["attempts"], fn attempt ->
        (config.cases == [] or attempt["case_id"] in config.cases) and
          (config.models == [] or attempt["model"] in config.models) and
          (config.opts[:provider] == nil or
             String.starts_with?(attempt["model"], config.opts[:provider] <> ":")) and
          config.opts[:mode] in [nil, "both", attempt["mode"]]
      end)

    if selected == [] or
         not Enum.all?(config.cases, fn id -> Enum.any?(selected, &(&1["case_id"] == id)) end) or
         not Enum.all?(config.models, fn model -> Enum.any?(selected, &(&1["model"] == model)) end),
       do: raise(ArgumentError, "selected billing audit cases or models have no captures")
  end

  defp validate_record!(opts, ids) do
    models = csv(opts[:model])

    if ids == [] or models == [],
      do: raise(ArgumentError, "record requires exact --case and --model selections")

    if Enum.any?(models, &String.contains?(&1, ["*", "?"])),
      do: raise(ArgumentError, "record does not accept model wildcards")

    if is_nil(opts[:budget_usd]) or decimal_micros(opts[:budget_usd]) <= 0,
      do: raise(ArgumentError, "record requires a positive --budget-usd")

    if not is_integer(opts[:max_requests]) or opts[:max_requests] <= 0,
      do: raise(ArgumentError, "record requires a positive --max-requests")

    Cases.select(ids, models, opts[:mode] || "both")

    Enum.each(models, fn spec ->
      Reference.rates!(spec)

      case ReqLLM.model(spec) do
        {:ok, %LLMDB.Model{pricing: pricing}} when is_map(pricing) ->
          Enum.each(ids, &require_case_rates!(&1, pricing))

        _ ->
          raise ArgumentError, "model requires confirmed catalog metadata: #{spec}"
      end

      [provider, _] = String.split(spec, ":", parts: 2)
      env_key = String.upcase(provider) <> "_API_KEY"
      key = System.get_env(env_key)

      if key in [nil, ""] or String.starts_with?(key, "test-key-"),
        do: raise(ArgumentError, "record requires real #{env_key} credentials")
    end)
  end

  defp decimal_micros(value) do
    {n, d} = Money.fraction(value)

    if rem(n * 1_000_000, d) != 0,
      do: raise(ArgumentError, "budget supports at most six decimal places")

    div(n * 1_000_000, d)
  end

  defp csv(nil), do: []

  defp csv(value),
    do: value |> String.split(",", trim: true) |> Enum.map(&String.trim/1) |> Enum.uniq()

  defp default_output, do: Path.join("tmp/billing", "run_#{System.os_time(:microsecond)}")
end
