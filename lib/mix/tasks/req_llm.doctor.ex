defmodule Mix.Tasks.ReqLlm.Doctor do
  @shortdoc "Diagnose ReqLLM installation and runtime configuration"
  @moduledoc """
  Runs read-only ReqLLM installation and runtime diagnostics.

      mix req_llm.doctor
      mix req_llm.doctor --model openai:gpt-4o-mini
      mix req_llm.doctor --provider anthropic
      mix req_llm.doctor --format json

  The default command performs no provider requests or network probes. Warning-only
  results exit successfully; diagnostic errors produce a non-zero exit status.
  """

  use Mix.Task

  @switches [
    model: :string,
    provider: :string,
    operation: :string,
    format: :string,
    json: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)

    validate_arguments!(positional, invalid)

    format = output_format!(opts)
    doctor_opts = doctor_options!(opts)
    result = ReqLLM.Doctor.run(doctor_opts)

    Mix.shell().info(render(result, format))

    if ReqLLM.Doctor.exit_status(result) != 0 do
      Mix.raise("ReqLLM diagnostics failed")
    end
  end

  defp validate_arguments!([], []), do: :ok

  defp validate_arguments!(positional, invalid) do
    Mix.raise("Invalid arguments: #{inspect(positional ++ invalid)}")
  end

  defp output_format!(opts) do
    format = if opts[:json], do: "json", else: Keyword.get(opts, :format, "human")

    case format do
      "human" -> :human
      "json" -> :json
      _other -> Mix.raise("--format must be human or json")
    end
  end

  defp doctor_options!(opts) do
    operation = operation!(opts[:operation])

    []
    |> put_if_present(:model, opts[:model])
    |> put_if_present(:provider, opts[:provider])
    |> put_if_present(:operation, operation)
    |> Keyword.put(:start_application?, true)
  end

  defp operation!(nil), do: nil
  defp operation!("chat"), do: :chat
  defp operation!("object"), do: :object
  defp operation!(_operation), do: Mix.raise("--operation must be chat or object")

  defp put_if_present(opts, _key, nil), do: opts
  defp put_if_present(opts, key, value), do: Keyword.put(opts, key, value)

  defp render(result, :human), do: ReqLLM.Doctor.format_human(result)
  defp render(result, :json), do: Jason.encode!(result, pretty: true)
end
