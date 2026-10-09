defmodule ReqLLM.Test.Billing.Audit do
  @moduledoc false

  alias ReqLLM.Test.Billing.{Money, Reference, Run}

  def check_attempt!(dir, attempt) do
    with true <- attempt["capture_complete"] == true,
         path <- safe_path!(dir, attempt["transcript"]),
         true <- Run.hash(path) == attempt["transcript_sha256"],
         raw <- path |> File.read!() |> Jason.decode!(),
         observed when is_map(observed) <- observation(dir, attempt["attempt_id"]) do
      reference =
        Reference.calculate(
          attempt["model"],
          Reference.response_body(raw),
          context(attempt, raw),
          Run.load!(dir)["rate_book"]
        )

      Run.append!(
        dir,
        "billing.jsonl",
        attempt,
        Map.merge(reference, %{
          "kind" => "calculation",
          "source_transcript" => attempt["transcript"],
          "source_sha256" => attempt["transcript_sha256"],
          "observed_usage" => observed["usage"]
        })
      )

      result = compare(reference, observed["usage"])

      Run.result!(
        dir,
        Map.merge(result, %{
          "case_id" => attempt["case_id"],
          "attempt_id" => attempt["attempt_id"],
          "layer" => "pricing"
        })
      )

      result
    else
      reason ->
        result = %{
          "status" => "blocked",
          "reason" => "incomplete capture or observation: #{inspect(reason)}"
        }

        Run.result!(
          dir,
          Map.merge(result, %{
            "case_id" => attempt["case_id"],
            "attempt_id" => attempt["attempt_id"],
            "layer" => "capture"
          })
        )

        result
    end
  end

  def check!(dir) do
    manifest = Run.load!(dir)
    if manifest["attempts"] == [], do: raise(ArgumentError, "no billing attempts were recorded")
    Enum.map(manifest["attempts"], &check_attempt!(dir, &1))
  end

  def compare(%{"status" => "priced", "total_micros" => expected} = reference, usage)
      when is_map(usage) do
    actual = Money.observed(usage["total_cost"])

    tolerance = Enum.count(reference["line_items"], &(&1["quantity"] > 0))

    if get_in(usage, ["pricing", "status"]) == "priced" and is_integer(actual) and
         abs(actual - expected) <= tolerance and
         line_items_match?(reference, usage),
       do: %{"status" => "passed", "rounding_difference_micros" => actual - expected},
       else: %{
         "status" => "failed",
         "reason" =>
           "expected #{Money.usd(expected)} USD; observed #{inspect(usage["total_cost"])}"
       }
  end

  def compare(%{"status" => "unknown"}, usage) when is_map(usage) do
    costs = ~w(total_cost input_cost output_cost reasoning_cost cost)

    if get_in(usage, ["pricing", "status"]) == "unknown" and
         not Enum.any?(costs, &Map.has_key?(usage, &1)),
       do: %{"status" => "passed"},
       else: %{"status" => "failed", "reason" => "unconfirmed facts must remain unpriced"}
  end

  def compare(_, _), do: %{"status" => "failed", "reason" => "missing library usage"}

  defp line_items_match?(reference, usage) do
    actual = get_in(usage, ["cost", "line_items"]) || []
    expected = Enum.filter(reference["line_items"], &(&1["quantity"] > 0))

    Enum.all?(expected, fn row ->
      Enum.any?(actual, fn item ->
        item["count"] == row["quantity"] and is_number(item["per"]) and item["per"] > 0 and
          is_number(item["cost"]) and is_number(item["rate"]) and
          abs(Money.observed(item["cost"]) - row["expected_micros"]) <= 1 and
          Money.observed(item["rate"]) * row["per"] == row["effective_rate_micros"] * item["per"] and
          meter_matches?(row["meter"], item["id"])
      end)
    end)
  end

  defp meter_matches?("cache_5m", id),
    do: is_binary(id) and String.starts_with?(id, "token.cache_write")

  defp meter_matches?("cache_1h", id),
    do: is_binary(id) and String.starts_with?(id, "token.cache_write")

  defp meter_matches?("cache_write", id),
    do: is_binary(id) and String.starts_with?(id, "token.cache_write")

  defp meter_matches?("web_search", id),
    do: is_binary(id) and String.starts_with?(id, "tool.web_search")

  defp meter_matches?(meter, id), do: is_binary(id) and String.starts_with?(id, "token." <> meter)

  def promote!(dir, ids, destination \\ ReqLLM.Test.FixturePath.root()) do
    manifest = Run.load!(dir)

    unless manifest["origin"] == "live",
      do: raise(ArgumentError, "only live captures can be promoted")

    if ids == [], do: raise(ArgumentError, "promotion requires exact case IDs")
    attempts = Enum.filter(manifest["attempts"], &(&1["case_id"] in ids))

    unless Enum.sort(Enum.uniq(Enum.map(attempts, & &1["case_id"]))) == Enum.sort(Enum.uniq(ids)),
      do: raise(ArgumentError, "selected promotion cases are missing")

    Enum.each(attempts, fn attempt ->
      unless attempt["capture_origin"] == "live" and attempt["state"] == "complete" and
               check_attempt!(dir, attempt)["status"] == "passed",
             do: raise(ArgumentError, "attempt has no reviewed complete billing evidence")

      path = safe_path!(dir, attempt["transcript"])

      unless Run.hash(path) == attempt["transcript_sha256"],
        do: raise(ArgumentError, "capture hash changed")

      [provider, model] = String.split(attempt["model"], ":", parts: 2)
      name = "billing_#{attempt["case_id"]}_#{attempt["mode"]}_#{attempt["phase"]}"

      target =
        ReqLLM.Test.FixturePath.file_under(
          destination,
          String.to_existing_atom(provider),
          model,
          name
        )

      if File.exists?(target),
        do: raise(ArgumentError, "baseline already exists; review and remove it explicitly")
    end)

    Enum.map(attempts, fn attempt ->
      [provider, model] = String.split(attempt["model"], ":", parts: 2)
      name = "billing_#{attempt["case_id"]}_#{attempt["mode"]}_#{attempt["phase"]}"

      target =
        ReqLLM.Test.FixturePath.file_under(
          destination,
          String.to_existing_atom(provider),
          model,
          name
        )

      File.mkdir_p!(Path.dirname(target))
      File.cp!(safe_path!(dir, attempt["transcript"]), target)

      File.write!(
        target <> ".billing.json",
        Jason.encode!(
          %{
            "schema_version" => 1,
            "source" =>
              Map.take(
                manifest,
                ~w(run_id origin created_at git_revision git_dirty suite_sources_sha256 catalog_version)
              ),
            "rate_book" =>
              Map.put(
                manifest["rate_book"],
                "models",
                Map.take(manifest["rate_book"]["models"], [attempt["model"]])
              ),
            "attempt" => Map.drop(attempt, ~w(request phases)),
            "calculation" => reference(dir, attempt, manifest["rate_book"])
          },
          pretty: true
        ) <> "\n"
      )

      target
    end)
  end

  def safe_path!(dir, relative) when is_binary(relative) do
    base = Path.expand(dir)
    path = Path.expand(relative, base)

    unless String.starts_with?(path, base <> "/") and File.regular?(path),
      do: raise(ArgumentError, "invalid transcript path")

    path
  end

  def safe_path!(_, _), do: raise(ArgumentError, "missing transcript path")

  defp context(attempt, raw) do
    %{"url" => raw["request"]["url"], "cache_ttl" => attempt["cache_ttl"]}
  end

  defp observation(dir, id),
    do: Run.records(dir, "observed.jsonl") |> Enum.find(&(&1["attempt_id"] == id))

  defp reference(dir, attempt, book) do
    raw = safe_path!(dir, attempt["transcript"]) |> File.read!() |> Jason.decode!()

    Reference.calculate(
      attempt["model"],
      Reference.response_body(raw),
      context(attempt, raw),
      book
    )
  end
end
