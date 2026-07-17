defmodule ReqLLM.Migration.Audit do
  @moduledoc false

  @schema_version 1
  @ignored_directories ~w(.git .elixir_ls _build cover deps doc node_modules)
  @operation_modules [
    "ReqLLM",
    "ReqLLM.Embedding",
    "ReqLLM.Generation",
    "ReqLLM.Images",
    "ReqLLM.OCR",
    "ReqLLM.Rerank",
    "ReqLLM.Speech",
    "ReqLLM.Transcription"
  ]
  @structured_functions ~w(generate_text stream_text)
  @object_functions ~w(generate_object stream_object)
  @structured_constructors ~w(array choice json object)

  @spec run(Path.t() | [Path.t()], keyword()) :: ReqLLM.Migration.report()
  def run(paths, opts) do
    with :ok <- ReqLLM.Migration.validate_ledger(),
         {:ok, normalized_paths, excluded_paths} <- validate_input(paths, opts) do
      {files, path_errors} = collect_files(normalized_paths, excluded_paths)
      {findings, source_errors} = scan_files(files)
      report(files, findings, sort_errors(path_errors ++ source_errors))
    else
      {:error, errors} when is_list(errors) -> report([], [], input_errors(errors))
      {:error, message} -> report([], [], input_errors([message]))
    end
  end

  @spec format_human(ReqLLM.Migration.report()) :: String.t()
  def format_human(report) do
    heading = "ReqLLM V2 migration audit: #{String.upcase(report["status"])}"
    finding_lines = Enum.flat_map(report["findings"], &format_finding/1)
    error_lines = Enum.map(report["errors"], &format_error/1)
    summary = report["summary"]

    footer =
      "#{summary["files_scanned"]} files, #{summary["actionable"]} actionable, " <>
        "#{summary["advisory"]} advisory, #{summary["errors"]} errors"

    Enum.join([heading] ++ finding_lines ++ error_lines ++ [footer], "\n")
  end

  defp validate_input(paths, opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      unknown = Keyword.keys(opts) -- [:exclude]

      if unknown == [] do
        with {:ok, normalized_paths} <- normalize_paths(paths),
             {:ok, excluded_paths} <- normalize_excludes(Keyword.get(opts, :exclude, [])) do
          {:ok, normalized_paths, excluded_paths}
        end
      else
        {:error, "Unknown audit options: #{Enum.map_join(unknown, ", ", &inspect/1)}."}
      end
    else
      {:error, "Audit options must be a keyword list."}
    end
  end

  defp validate_input(_paths, _opts), do: {:error, "Audit options must be a keyword list."}

  defp normalize_paths(path) when is_binary(path), do: {:ok, [Path.expand(path)]}

  defp normalize_paths(paths) when is_list(paths) do
    cond do
      paths == [] -> {:ok, [Path.expand(".")]}
      Enum.all?(paths, &is_binary/1) -> {:ok, paths |> Enum.map(&Path.expand/1) |> Enum.uniq()}
      true -> {:error, "Audit paths must be strings."}
    end
  end

  defp normalize_paths(_paths), do: {:error, "Audit paths must be a string or list of strings."}

  defp normalize_excludes(path) when is_binary(path), do: {:ok, [Path.expand(path)]}

  defp normalize_excludes(paths) when is_list(paths) do
    if Enum.all?(paths, &is_binary/1) do
      {:ok, paths |> Enum.map(&Path.expand/1) |> Enum.uniq()}
    else
      {:error, "Excluded paths must be strings."}
    end
  end

  defp normalize_excludes(_paths),
    do: {:error, "Excluded paths must be a string or list of strings."}

  defp collect_files(paths, excluded_paths) do
    paths
    |> Enum.reduce({[], []}, fn path, {files, errors} ->
      {path_files, path_errors} = collect_path(path, excluded_paths)
      {path_files ++ files, path_errors ++ errors}
    end)
    |> then(fn {files, errors} -> {files |> Enum.uniq() |> Enum.sort(), Enum.reverse(errors)} end)
  end

  defp collect_path(path, excluded_paths) do
    cond do
      excluded?(path, excluded_paths) ->
        {[], []}

      ignored_directory?(path) ->
        {[], []}

      true ->
        collect_path_info(path, excluded_paths)
    end
  end

  defp collect_path_info(path, excluded_paths) do
    case File.lstat(path) do
      {:ok, %{type: :regular}} ->
        if source_file?(path), do: {[path], []}, else: {[], []}

      {:ok, %{type: :directory}} ->
        collect_directory(path, excluded_paths)

      {:ok, _stat} ->
        {[], []}

      {:error, reason} ->
        {[], [source_error(path, "Path could not be read: #{:file.format_error(reason)}")]}
    end
  end

  defp collect_directory(path, excluded_paths) do
    case File.ls(path) do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.reduce({[], []}, fn entry, {files, errors} ->
          {entry_files, entry_errors} = collect_path(Path.join(path, entry), excluded_paths)
          {entry_files ++ files, entry_errors ++ errors}
        end)

      {:error, reason} ->
        {[], [source_error(path, "Directory could not be read: #{:file.format_error(reason)}")]}
    end
  end

  defp ignored_directory?(path), do: Path.basename(path) in @ignored_directories

  defp excluded?(path, excluded_paths) do
    Enum.any?(excluded_paths, fn excluded ->
      path == excluded or String.starts_with?(path, excluded <> "/")
    end)
  end

  defp source_file?(path), do: Path.extname(path) in [".ex", ".exs"]

  defp scan_files(files) do
    index = deprecation_index()
    checks = migration_check_index()

    files
    |> Enum.reduce({[], []}, fn file, {findings, errors} ->
      case scan_file(file, index, checks) do
        {:ok, file_findings} -> {file_findings ++ findings, errors}
        {:error, error} -> {findings, [error | errors]}
      end
    end)
    |> then(fn {findings, errors} -> {sort_findings(findings), Enum.reverse(errors)} end)
  end

  defp scan_file(file, deprecations, checks) do
    with {:ok, source} <- File.read(file),
         {:ok, ast} <- Code.string_to_quoted(source, columns: true, token_metadata: true) do
      findings =
        ast
        |> Macro.prewalk([], fn node, findings ->
          {node, node_findings(node, file, deprecations, checks) ++ findings}
        end)
        |> elem(1)

      {:ok, findings}
    else
      {:error, {line, error, _token}} ->
        message = "Source could not be parsed at line #{line}: #{parse_error_message(error)}"
        {:error, source_error(file, message)}

      {:error, reason} ->
        {:error, source_error(file, "Source could not be read: #{:file.format_error(reason)}")}
    end
  rescue
    error ->
      {:error, source_error(file, "Source could not be audited: #{Exception.message(error)}")}
  end

  defp node_findings(node, file, deprecations, checks) do
    deprecated_call_findings(node, file, deprecations) ++
      provider_options_findings(node, file, checks) ++
      raw_stream_findings(node, file, checks) ++
      provider_behavior_findings(node, file, checks) ++
      output_policy_findings(node, file, checks)
  end

  defp deprecated_call_findings(node, file, deprecations) do
    case remote_call(node) do
      {:ok, module, function, args, metadata} ->
        case Map.get(deprecations, {module, function}) do
          nil -> []
          entry -> [deprecated_finding(entry, module, function, length(args), file, metadata)]
        end

      :error ->
        []
    end
  end

  defp provider_options_findings(node, file, checks) do
    with {:ok, module, _function, args, metadata} <- remote_call(node),
         true <- module in @operation_modules,
         [model | _rest] <- args,
         provider when is_binary(provider) <- model_provider(model),
         true <- legacy_provider_options?(args, provider) do
      [check_finding(checks["v2.legacy_provider_options"], file, metadata)]
    else
      _other -> []
    end
  end

  defp raw_stream_findings({:%, metadata, [module_ast, map_ast]}, file, checks) do
    if module_name(module_ast) == "ReqLLM.StreamResponse" and stream_field?(map_ast) do
      [check_finding(checks["v2.raw_stream_field"], file, metadata)]
    else
      []
    end
  end

  defp raw_stream_findings(_node, _file, _checks), do: []

  defp provider_behavior_findings({:@, metadata, [{:behaviour, _, [module_ast]}]}, file, checks) do
    if module_name(module_ast) == "ReqLLM.Provider" do
      [check_finding(checks["v2.provider_behaviour"], file, metadata)]
    else
      []
    end
  end

  defp provider_behavior_findings({:use, metadata, [module_ast | _arguments]}, file, checks) do
    if module_name(module_ast) == "ReqLLM.Provider" do
      [check_finding(checks["v2.provider_behaviour"], file, metadata)]
    else
      []
    end
  end

  defp provider_behavior_findings(_node, _file, _checks), do: []

  defp output_policy_findings(node, file, checks) do
    with {:ok, module, function, args, metadata} <- remote_call(node),
         true <- module in ["ReqLLM", "ReqLLM.Generation"],
         true <- function in (@structured_functions ++ @object_functions),
         true <- statically_known_model?(List.first(args)),
         true <- implicit_output_policy?(function, args) do
      [check_finding(checks["v2.implicit_output_validation"], file, metadata)]
    else
      _other -> []
    end
  end

  defp remote_call({{:., _, [module_ast, function]}, metadata, args})
       when is_atom(function) and is_list(args) do
    case module_name(module_ast) do
      nil -> :error
      module -> {:ok, module, Atom.to_string(function), args, metadata}
    end
  end

  defp remote_call(_node), do: :error

  defp module_name({:__aliases__, _, parts}) when is_list(parts) do
    if Enum.all?(parts, &is_atom/1) do
      Enum.map_join(parts, ".", &Atom.to_string/1)
    end
  end

  defp module_name(module) when is_atom(module) do
    module
    |> Atom.to_string()
    |> String.trim_leading("Elixir.")
  end

  defp module_name(_module), do: nil

  defp model_provider({model, opts}) when is_list(opts), do: model_provider(model)
  defp model_provider({:{}, _, [model, opts]}) when is_list(opts), do: model_provider(model)

  defp model_provider(model) when is_binary(model) do
    case String.split(model, ":", parts: 2) do
      [provider, model_id] when provider != "" and model_id != "" -> provider
      _other -> nil
    end
  end

  defp model_provider({provider, model_id})
       when (is_atom(provider) or is_binary(provider)) and is_binary(model_id),
       do: to_string(provider)

  defp model_provider({:%{}, _, fields}), do: provider_from_fields(fields)
  defp model_provider({:%, _, [_module, {:%{}, _, fields}]}), do: provider_from_fields(fields)
  defp model_provider(_model), do: nil

  defp provider_from_fields(fields) when is_list(fields) do
    case Enum.find(fields, fn {key, _value} -> key in [:provider, "provider"] end) do
      {_key, provider} when is_atom(provider) or is_binary(provider) -> to_string(provider)
      _other -> nil
    end
  end

  defp provider_from_fields(_fields), do: nil

  defp legacy_provider_options?(args, provider) do
    args
    |> literal_option_sources()
    |> Enum.any?(fn opts ->
      case Keyword.fetch(opts, :provider_options) do
        {:ok, provider_options} -> flat_provider_options?(provider_options, provider)
        :error -> false
      end
    end)
  end

  defp flat_provider_options?(provider_options, provider) do
    case container_entries(provider_options) do
      :dynamic ->
        false

      [] ->
        false

      entries ->
        literal_container_entries?(entries) and
          not namespaced_provider_options?(entries, provider)
    end
  end

  defp literal_container_entries?(entries) do
    Enum.all?(entries, fn
      {key, _value} when is_atom(key) or is_binary(key) -> true
      _entry -> false
    end)
  end

  defp namespaced_provider_options?([{key, value}], provider) do
    to_string(key) == provider and literal_container?(value)
  rescue
    Protocol.UndefinedError -> false
  end

  defp namespaced_provider_options?(_entries, _provider), do: false

  defp literal_container?(value), do: container_entries(value) != :dynamic

  defp container_entries(value) when is_list(value) do
    if Keyword.keyword?(value), do: value, else: :dynamic
  end

  defp container_entries({:%{}, _, fields}) when is_list(fields), do: fields
  defp container_entries(_value), do: :dynamic

  defp stream_field?({:%{}, _, fields}), do: fields_contain_stream?(fields)
  defp stream_field?(_map_ast), do: false

  defp fields_contain_stream?(fields) when is_list(fields) do
    Enum.any?(fields, fn
      {:stream, _value} -> true
      {:|, _, [_base, updates]} -> fields_contain_stream?(updates)
      _field -> false
    end)
  end

  defp fields_contain_stream?(_fields), do: false

  defp statically_known_model?(model), do: is_binary(model_provider(model))

  defp implicit_output_policy?(function, args) when function in @object_functions do
    case object_call_options(args) do
      :default -> not option_present?(args, :output_validation)
      {:literal, _opts} -> not option_present?(args, :output_validation)
      :dynamic -> false
    end
  end

  defp implicit_output_policy?(_function, args) do
    structured_output_present?(args) and not option_present?(args, :output_validation)
  end

  defp object_call_options(args) do
    case length(args) do
      3 -> :default
      4 -> if literal_keyword?(List.last(args)), do: {:literal, List.last(args)}, else: :dynamic
      _arity -> :dynamic
    end
  end

  defp structured_output_present?(args) do
    args
    |> literal_option_sources()
    |> Enum.any?(fn opts ->
      case Keyword.fetch(opts, :output) do
        {:ok, output} -> structured_output_constructor?(output)
        :error -> false
      end
    end)
  end

  defp structured_output_constructor?(node) do
    case remote_call(node) do
      {:ok, "ReqLLM.Output", function, _args, _metadata} -> function in @structured_constructors
      _other -> false
    end
  end

  defp option_present?(args, key) do
    args
    |> literal_option_sources()
    |> Enum.any?(&Keyword.has_key?(&1, key))
  end

  defp literal_option_sources(args) do
    direct = Enum.filter(args, &literal_keyword?/1)

    tuple_options =
      case List.first(args) do
        {_model, opts} when is_list(opts) ->
          if literal_keyword?(opts), do: [opts], else: []

        {:{}, _, [_model, opts]} when is_list(opts) ->
          if literal_keyword?(opts), do: [opts], else: []

        _model ->
          []
      end

    direct ++ tuple_options
  end

  defp literal_keyword?(value), do: is_list(value) and Keyword.keyword?(value)

  defp deprecation_index do
    Map.new(ReqLLM.Migration.deprecations(), fn entry ->
      detector = entry["detector"]
      {{detector["module"], detector["function"]}, entry}
    end)
  end

  defp migration_check_index do
    Map.new(ReqLLM.Migration.migration_checks(), &{&1["id"], &1})
  end

  defp deprecated_finding(entry, module, function, arity, file, metadata) do
    actionable = entry["v2_scope"] == "approved"

    finding(entry, file, metadata, %{
      "actionable" => actionable,
      "category" => "deprecated_api",
      "contract" => "#{module}.#{function}/#{arity}",
      "message" => deprecated_message(entry, actionable)
    })
  end

  defp deprecated_message(entry, true), do: "#{entry["contract"]} is deprecated."

  defp deprecated_message(entry, false),
    do: "#{entry["contract"]} is deprecated but is not approved for removal in V2."

  defp check_finding(entry, file, metadata) do
    category = if entry["actionable"], do: "migration", else: "advisory"

    finding(entry, file, metadata, %{
      "actionable" => entry["actionable"],
      "category" => category,
      "contract" => entry["contract"],
      "message" => entry["contract"] <> "."
    })
  end

  defp finding(entry, file, metadata, fields) do
    Map.merge(
      %{
        "id" => entry["id"],
        "file" => display_path(file),
        "line" => Keyword.get(metadata, :line, 1),
        "column" => Keyword.get(metadata, :column, 1),
        "owner" => entry["owner"],
        "replacement" => entry["replacement"],
        "guide" => entry["guide"]
      },
      fields
    )
  end

  defp sort_findings(findings) do
    findings
    |> Enum.uniq_by(&{&1["id"], &1["file"], &1["line"], &1["column"], &1["contract"]})
    |> Enum.sort_by(&{&1["file"], &1["line"], &1["column"], &1["id"]})
  end

  defp sort_errors(errors), do: Enum.sort_by(errors, &{&1["file"] || "", &1["message"]})

  defp parse_error_message(error) when is_binary(error), do: error
  defp parse_error_message(error), do: inspect(error)

  defp report(files, findings, errors) do
    actionable = Enum.count(findings, & &1["actionable"])
    advisory = length(findings) - actionable

    status =
      cond do
        errors != [] -> "error"
        actionable > 0 -> "findings"
        advisory > 0 -> "advisory"
        true -> "clean"
      end

    %{
      "schema_version" => @schema_version,
      "status" => status,
      "summary" => %{
        "files_scanned" => length(files),
        "actionable" => actionable,
        "advisory" => advisory,
        "errors" => length(errors)
      },
      "findings" => findings,
      "errors" => errors
    }
  end

  defp input_errors(messages) do
    Enum.map(messages, &source_error(nil, &1))
  end

  defp source_error(file, message) do
    %{"file" => optional_display_path(file), "message" => message}
  end

  defp optional_display_path(nil), do: nil
  defp optional_display_path(file), do: display_path(file)

  defp display_path(file), do: Path.relative_to_cwd(file)

  defp format_finding(finding) do
    marker = if finding["actionable"], do: "!", else: "i"

    [
      "#{marker} #{finding["file"]}:#{finding["line"]}:#{finding["column"]} #{finding["id"]}",
      "  #{finding["message"]}",
      "  Replace: #{finding["replacement"]}",
      "  Guide: #{finding["guide"]}"
    ]
  end

  defp format_error(error) do
    case error["file"] do
      nil -> "x #{error["message"]}"
      file -> "x #{file}: #{error["message"]}"
    end
  end
end
