defmodule ReqLLM.Billing.BaselinesTest do
  use ExUnit.Case, async: true
  alias ReqLLM.Test.Billing.Samples
  @moduletag :billing

  files =
    Path.wildcard(Path.join(ReqLLM.Test.FixturePath.root(), "**/billing_*.json"))
    |> Enum.reject(&String.ends_with?(&1, ".billing.json"))
    |> Enum.filter(&File.exists?(&1 <> ".billing.json"))

  for path <- files do
    metadata = (path <> ".billing.json") |> File.read!() |> Jason.decode!()
    attempt = metadata["attempt"]

    if Samples.selected?(%{case_id: attempt["case_id"], model: attempt["model"]}) do
      alias ReqLLM.Test.Billing.{Audit, Reference, Run}
      @tag billing_case: attempt["case_id"], billing_layer: "pricing", model: attempt["model"]
      test "accepted #{attempt["case_id"]}: #{attempt["model"]} #{attempt["mode"]} #{attempt["phase"]}" do
        path = unquote(path)
        metadata = (path <> ".billing.json") |> File.read!() |> Jason.decode!()
        raw = File.read!(path) |> Jason.decode!()
        attempt = metadata["attempt"]
        assert Run.hash(path) == attempt["transcript_sha256"]
        body = Reference.response_body(raw)
        request = %{"url" => raw["request"]["url"], "cache_ttl" => attempt["cache_ttl"]}
        reference = Reference.calculate(attempt["model"], body, request, metadata["rate_book"])
        assert reference == metadata["calculation"]

        sample = %{
          Samples.sample(attempt["case_id"], attempt["model"])
          | body: body,
            request: request
        }

        current = Samples.buffered(sample).usage |> Run.stringify()
        assert Audit.compare(reference, current)["status"] == "passed"
      end
    end
  end
end
