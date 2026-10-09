defmodule ReqLLM.Test.Billing.Formatter do
  @moduledoc false
  use GenServer

  alias ReqLLM.Test.Billing.Run

  @impl true
  def init(_opts), do: {:ok, System.get_env("REQ_LLM_BILLING_RUN")}

  @impl true
  def handle_cast({:test_finished, test}, dir) when is_binary(dir) do
    if test.tags[:billing] and not match?({:excluded, _}, test.state) do
      status =
        case test.state do
          nil -> "passed"
          {:skipped, _} -> "blocked"
          _ -> "failed"
        end

      Run.result!(dir, %{
        "case_id" => to_string(test.tags[:billing_case] || "suite_contract"),
        "layer" => to_string(test.tags[:billing_layer] || "contract"),
        "test" => test.name,
        "model" => test.tags[:model],
        "status" => status,
        "reason" => if(status == "passed", do: nil, else: "ExUnit #{status}; see test output")
      })
    end

    {:noreply, dir}
  end

  def handle_cast(_event, state), do: {:noreply, state}
end
