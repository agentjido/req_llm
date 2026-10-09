defmodule ReqLLM.Coverage.Billing.LiveTest do
  use ExUnit.Case, async: false
  @moduletag :coverage
  @moduletag :billing
  @moduletag billing_layer: "pipeline"
  @moduletag timeout: 600_000

  if System.get_env("REQ_LLM_BILLING_MODE") == "record" do
    alias ReqLLM.Test.Billing.{Live, Run}
    run = System.fetch_env!("REQ_LLM_BILLING_RUN")

    for selection <- Run.load!(run)["selection"] do
      @tag billing_case: selection["case_id"], model: selection["model"], mode: selection["mode"]
      test "#{selection["case_id"]}: #{selection["model"]} #{selection["mode"]}" do
        Live.run!(unquote(Macro.escape(selection)), System.fetch_env!("REQ_LLM_BILLING_RUN"))
      end
    end
  else
    @tag skip: "use mix req_llm.billing record with explicit selections and limits"
    test "live billing requires its explicit run contract", do: :ok
  end
end
