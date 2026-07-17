defmodule ReqLLM.Migration do
  @moduledoc """
  Read-only V2 migration inventory for ReqLLM applications.

  `ledger/0` exposes the versioned, JSON-compatible deprecation ledger shipped
  with ReqLLM. `audit/2` scans Elixir source without evaluating it and reports
  only the precise patterns represented in that ledger.

  The audit never rewrites source, starts ReqLLM, resolves credentials, or makes
  provider requests. Its result is safe to encode directly as JSON.
  """

  @ledger_path Path.expand("../../priv/deprecations.json", __DIR__)
  @external_resource @ledger_path
  @ledger @ledger_path |> File.read!() |> Jason.decode!()

  @deprecation_keys ~w(id owner contract replacement introduced_version target_major v2_scope minimum_window guide detector)
  @migration_check_keys ~w(id owner contract replacement target_major v2_scope actionable guide detector)
  @migration_detector_types ~w(implicit_output_validation legacy_provider_options provider_behavior stream_response_field)

  @type report :: %{required(String.t()) => term()}

  @doc "Returns the complete machine-readable deprecation and migration ledger."
  @spec ledger() :: map()
  def ledger, do: @ledger

  @doc "Returns the active deprecation records in ledger order."
  @spec deprecations() :: [map()]
  def deprecations, do: @ledger["deprecations"]

  @doc "Returns the precise V2-readiness checks in ledger order."
  @spec migration_checks() :: [map()]
  def migration_checks, do: @ledger["migration_checks"]

  @doc """
  Audits Elixir source paths for mechanical V2 migration work.

  A path may be a file or directory. Directories are scanned recursively for
  `.ex` and `.exs` files. Dependency, build, VCS, coverage, and generated-doc
  directories are ignored by default.

  ## Options

    * `:exclude` - a path or list of paths to omit
  """
  @spec audit(Path.t() | [Path.t()], keyword()) :: report()
  def audit(paths \\ ["."], opts \\ []) do
    ReqLLM.Migration.Audit.run(paths, opts)
  end

  @doc "Returns `0` for clean or advisory-only reports, `1` for migration work, and `2` for errors."
  @spec exit_status(report()) :: 0 | 1 | 2
  def exit_status(%{"status" => "error"}), do: 2
  def exit_status(%{"status" => "findings"}), do: 1
  def exit_status(_report), do: 0

  @doc "Formats an audit report for terminal output."
  @spec format_human(report()) :: String.t()
  def format_human(report), do: ReqLLM.Migration.Audit.format_human(report)

  @doc false
  @spec validate_ledger() :: :ok | {:error, [String.t()]}
  def validate_ledger do
    errors =
      schema_errors(@ledger) ++
        record_errors(@ledger["deprecations"], @deprecation_keys, "deprecation") ++
        record_errors(@ledger["migration_checks"], @migration_check_keys, "migration check") ++
        identity_errors(@ledger)

    case errors do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  defp schema_errors(%{
         "schema_version" => 1,
         "deprecations" => deprecations,
         "migration_checks" => checks
       })
       when is_list(deprecations) and is_list(checks),
       do: []

  defp schema_errors(_ledger),
    do: ["The ledger must use schema version 1 and contain both record lists."]

  defp record_errors(records, keys, kind) when is_list(records) do
    records
    |> Enum.with_index()
    |> Enum.flat_map(fn {record, index} -> record_errors(record, keys, kind, index) end)
  end

  defp record_errors(_records, _keys, kind), do: ["The #{kind} records must be a list."]

  defp record_errors(record, keys, kind, index) when is_map(record) do
    missing = keys -- Map.keys(record)

    value_errors =
      if valid_common_record?(record) do
        []
      else
        ["#{kind} #{index} contains invalid common field values."]
      end

    detector_errors =
      if valid_detector?(record["detector"]) do
        []
      else
        ["#{kind} #{index} has an invalid detector."]
      end

    kind_errors = kind_errors(record, kind, index)

    missing_errors =
      if missing == [],
        do: [],
        else: ["#{kind} #{index} is missing: #{Enum.join(missing, ", ")}."]

    missing_errors ++ value_errors ++ detector_errors ++ kind_errors
  end

  defp record_errors(_record, _keys, kind, index),
    do: ["#{kind} #{index} must be a JSON object."]

  defp valid_common_record?(record) when is_map(record) do
    Enum.all?(
      ~w(id owner contract replacement guide),
      &(is_binary(record[&1]) and record[&1] != "")
    ) and record["target_major"] == 2 and record["v2_scope"] in ~w(approved unapproved)
  end

  defp valid_detector?(%{"type" => type}) when is_binary(type), do: type != ""
  defp valid_detector?(_detector), do: false

  defp kind_errors(record, "deprecation", index) do
    errors =
      []
      |> require_introduction(record, index)
      |> require_window(record, index)
      |> require_remote_call_detector(record, index)

    Enum.reverse(errors)
  end

  defp kind_errors(record, "migration check", index) do
    detector_type = get_in(record, ["detector", "type"])

    cond do
      not is_boolean(record["actionable"]) ->
        ["migration check #{index} must declare whether it is actionable."]

      detector_type not in @migration_detector_types ->
        ["migration check #{index} has an unsupported detector type."]

      true ->
        []
    end
  end

  defp kind_errors(_record, _kind, _index), do: []

  defp require_introduction(errors, record, index) do
    introduced_version = record["introduced_version"]

    if introduced_version == "unreleased" or valid_version?(introduced_version) do
      errors
    else
      ["deprecation #{index} has an invalid introduced version." | errors]
    end
  end

  defp require_window(errors, record, index) do
    case record["minimum_window"] do
      %{"minor_releases" => releases} when is_integer(releases) and releases >= 2 ->
        errors

      _window ->
        ["deprecation #{index} must retain at least two minor releases of overlap." | errors]
    end
  end

  defp require_remote_call_detector(errors, record, index) do
    case record["detector"] do
      %{"type" => "remote_call", "module" => module, "function" => function}
      when is_binary(module) and module != "" and is_binary(function) and function != "" ->
        errors

      _detector ->
        ["deprecation #{index} must use a complete remote-call detector." | errors]
    end
  end

  defp valid_version?(version) when is_binary(version),
    do: match?({:ok, _version}, Version.parse(version))

  defp valid_version?(_version), do: false

  defp identity_errors(%{"deprecations" => deprecations, "migration_checks" => checks}) do
    ids =
      Enum.map(deprecations ++ checks, fn
        record when is_map(record) -> record["id"]
        _record -> nil
      end)

    cond do
      Enum.any?(ids, &is_nil/1) -> ["Every ledger record must have an id."]
      length(ids) != length(Enum.uniq(ids)) -> ["Ledger ids must be unique."]
      true -> []
    end
  end

  defp identity_errors(_ledger), do: []
end
