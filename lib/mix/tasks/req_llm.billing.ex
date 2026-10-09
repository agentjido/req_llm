defmodule Mix.Tasks.ReqLlm.Billing do
  @shortdoc "Check billing layers, record provider evidence, and audit JSONL worksheets"
  @moduledoc """
  Run the ExUnit billing suite or inspect its saved provider evidence.

      mix req_llm.billing list
      mix req_llm.billing check
      mix req_llm.billing check --case mixed_cache_ttl --layer pricing
      mix req_llm.billing record --model anthropic:claude-haiku-5-5 --case mixed_cache_ttl --budget-usd 5.00 --max-requests 12
      mix req_llm.billing audit --run tmp/billing/RUN
      mix req_llm.billing promote --run tmp/billing/RUN --case mixed_cache_ttl

  Check and audit are offline. Record requires exact selections and explicit
  request limits. Record retains failed evidence; promote is a separate action.
  See the usage and billing guide for artifact and reference-rate contracts.
  """
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("compile")
    module = ReqLLM.Test.Billing.CLI

    case Code.ensure_loaded(module) do
      {:module, ^module} -> Function.capture(module, :run, 1).(args)
      _ -> Mix.raise("billing test support is unavailable; run with MIX_ENV=test")
    end
  end
end
