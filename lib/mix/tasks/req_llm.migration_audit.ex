defmodule Mix.Tasks.ReqLlm.MigrationAudit do
  @shortdoc "Audit source for mechanical ReqLLM V2 migration work"
  @moduledoc """
  Scans Elixir source for precise ReqLLM V2 migration patterns without evaluating
  or rewriting application code.

      mix req_llm.migration_audit
      mix req_llm.migration_audit lib test
      mix req_llm.migration_audit --exclude test/fixtures --format json

  Actionable findings exit with status 1, audit errors with status 2, and clean
  or advisory-only reports with status 0.
  """

  use Mix.Task

  @switches [format: :string, json: :boolean, exclude: :keep]

  @impl Mix.Task
  def run(args) do
    {opts, paths, invalid} = OptionParser.parse(args, strict: @switches)

    validate_arguments!(invalid)

    format = output_format!(opts)
    audit_opts = [exclude: Keyword.get_values(opts, :exclude)]
    report = ReqLLM.Migration.audit(paths, audit_opts)

    Mix.shell().info(render(report, format))
    finish!(ReqLLM.Migration.exit_status(report))
  end

  defp validate_arguments!([]), do: :ok
  defp validate_arguments!(invalid), do: Mix.raise("Invalid arguments: #{inspect(invalid)}")

  defp output_format!(opts) do
    format = if opts[:json], do: "json", else: Keyword.get(opts, :format, "human")

    case format do
      "human" -> :human
      "json" -> :json
      _other -> Mix.raise("--format must be human or json")
    end
  end

  defp render(report, :human), do: ReqLLM.Migration.format_human(report)
  defp render(report, :json), do: Jason.encode!(report, pretty: true)

  defp finish!(0), do: :ok
  defp finish!(status) when status in [1, 2], do: exit({:shutdown, status})
end
