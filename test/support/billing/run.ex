defmodule ReqLLM.Test.Billing.Run do
  @moduledoc false

  alias ReqLLM.Test.Billing.{Money, Reference}

  @files ~w(raw.jsonl stream_events.jsonl observed.jsonl billing.jsonl)
  @secret_keys ~w(authorization x-api-key api-key api_key apiKey access_token cookie set-cookie x-amz-security-token)

  def create!(dir, selection, opts \\ []) do
    dir = Path.expand(dir)

    if File.exists?(dir),
      do: raise(ArgumentError, "billing output directory already exists: #{dir}")

    File.mkdir_p!(Path.join(dir, "transcripts"))
    Enum.each(@files, &File.write!(Path.join(dir, &1), ""))

    manifest = %{
      "schema_version" => 1,
      "run_id" => Path.basename(dir),
      "created_at" => now(),
      "origin" => Keyword.get(opts, :origin, "live"),
      "selection" => stringify(selection),
      "catalog_models" =>
        selection
        |> Enum.map(&(&1[:model] || &1["model"]))
        |> Enum.uniq()
        |> Map.new(fn spec -> {spec, ReqLLM.model!(spec) |> stringify()} end),
      "rate_book" => Reference.book(),
      "attempts" => [],
      "results" => [],
      "limits" => %{
        "budget_micros" => Keyword.get(opts, :budget_micros, 0),
        "max_requests" => Keyword.get(opts, :max_requests, 0)
      },
      "reserved_micros" => 0,
      "status" => "pending",
      "elixir" => System.version(),
      "otp" => :erlang.system_info(:otp_release) |> to_string(),
      "git_revision" => git_revision(),
      "git_dirty" => git_dirty?(),
      "suite_sources_sha256" => suite_sources_hash(),
      "catalog_version" => Application.spec(:llm_db, :vsn) |> to_string()
    }

    save!(dir, manifest)
    dir
  end

  def load!(dir) do
    dir = Path.expand(dir)
    manifest = Path.join(dir, "manifest.json") |> File.read!() |> Jason.decode!()

    unless manifest["schema_version"] == 1 and is_list(manifest["attempts"]),
      do: raise(ArgumentError, "invalid billing run manifest")

    manifest
  end

  def save!(dir, manifest) do
    path = Path.join(dir, "manifest.json")
    temp = path <> ".#{System.unique_integer([:positive])}.tmp"
    File.write!(temp, Jason.encode!(manifest, pretty: true) <> "\n")
    File.rename!(temp, path)
  end

  def reserve!(dir, attrs, estimate_micros) do
    transaction(dir, fn -> reserve_locked!(dir, attrs, estimate_micros) end)
  end

  defp reserve_locked!(dir, attrs, estimate_micros) do
    manifest = load!(dir)
    limit = manifest["limits"]

    if manifest["halted"] == true,
      do: raise(ArgumentError, "billing run is halted: #{manifest["halt_reason"]}")

    if length(manifest["attempts"]) >= limit["max_requests"],
      do: raise(ArgumentError, "billing request limit exhausted")

    if manifest["reserved_micros"] + estimate_micros > limit["budget_micros"],
      do: raise(ArgumentError, "billing estimated-spend limit exhausted")

    attempt_id = "attempt_#{length(manifest["attempts"]) + 1}"

    attempt =
      stringify(attrs)
      |> Map.merge(%{
        "attempt_id" => attempt_id,
        "fixture" => "billing_#{attempt_id}",
        "estimated_micros" => estimate_micros,
        "state" => "pending",
        "started_at" => now()
      })

    manifest
    |> Map.update!("attempts", &(&1 ++ [attempt]))
    |> Map.update!("reserved_micros", &(&1 + estimate_micros))
    |> then(&save!(dir, &1))

    attempt
  end

  def attempt!(dir, id) do
    Enum.find(load!(dir)["attempts"], &(&1["attempt_id"] == id)) ||
      raise ArgumentError, "unknown billing attempt: #{id}"
  end

  def fixture_attempt(dir, path) do
    name = Path.basename(path, ".json")
    Enum.find(load!(dir)["attempts"], &(&1["fixture"] == name))
  end

  def update_attempt!(dir, id, changes) do
    transaction(dir, fn -> update_attempt_locked!(dir, id, changes) end)
  end

  def reconcile!(dir, id, micros) when is_integer(micros) and micros >= 0 do
    transaction(dir, fn ->
      manifest = load!(dir)
      attempt = attempt!(dir, id)
      reserved = Map.get(attempt, "reconciled_micros", attempt["estimated_micros"])
      total = manifest["reserved_micros"] - reserved + micros

      attempts =
        Enum.map(manifest["attempts"], fn row ->
          if row["attempt_id"] == id, do: Map.put(row, "reconciled_micros", micros), else: row
        end)

      exceeded = micros > attempt["estimated_micros"]
      changes = %{"attempts" => attempts, "reserved_micros" => total}

      changes =
        if exceeded,
          do:
            Map.merge(changes, %{"halted" => true, "halt_reason" => "request estimate exceeded"}),
          else: changes

      save!(dir, Map.merge(manifest, changes))

      if micros > attempt["estimated_micros"],
        do:
          raise(
            ArgumentError,
            "reported cost exceeded the request estimate; no further live requests"
          )
    end)
  end

  defp update_attempt_locked!(dir, id, changes) do
    manifest = load!(dir)

    attempts =
      Enum.map(manifest["attempts"], fn attempt ->
        if attempt["attempt_id"] == id, do: Map.merge(attempt, stringify(changes)), else: attempt
      end)

    save!(dir, Map.put(manifest, "attempts", attempts))
  end

  def append!(dir, file, attempt, record) when file in @files do
    transaction(dir, fn -> append_locked!(dir, file, attempt, record) end)
  end

  defp append_locked!(dir, file, attempt, record) do
    manifest = load!(dir)

    record =
      if file == "stream_events.jsonl",
        do:
          Map.put(
            record,
            "sequence",
            Enum.count(records(dir, file), &(&1["attempt_id"] == attempt["attempt_id"]))
          ),
        else: record

    entry =
      stringify(record)
      |> Map.merge(%{
        "schema_version" => 1,
        "run_id" => manifest["run_id"],
        "case_id" => attempt["case_id"],
        "attempt_id" => attempt["attempt_id"]
      })
      |> redact()

    File.open!(Path.join(dir, file), [:append], fn io ->
      IO.binwrite(io, Jason.encode!(entry) <> "\n")
      :ok = :file.sync(io)
    end)

    entry
  end

  def records(dir, file) when file in @files do
    Path.join(dir, file) |> File.stream!() |> Enum.map(&Jason.decode!/1)
  end

  def result!(dir, result) do
    transaction(dir, fn -> result_locked!(dir, result) end)
  end

  defp result_locked!(dir, result) do
    manifest = load!(dir)
    results = manifest["results"] ++ [stringify(result)]
    status = if Enum.all?(results, &(&1["status"] == "passed")), do: "passed", else: "failed"
    save!(dir, Map.merge(manifest, %{"results" => results, "status" => status}))
    summary!(dir)
  end

  def summary!(dir) do
    manifest = load!(dir)

    rows =
      Enum.map(manifest["results"], fn row ->
        "| #{row["case_id"]} | #{row["layer"]} | #{row["status"]} | #{row["reason"] || ""} |"
      end)

    text =
      "# Billing run #{manifest["run_id"]}\n\nStatus: #{manifest["status"]}\n\n" <>
        "Reserved maximum: USD #{Money.usd(manifest["reserved_micros"])}\n\n" <>
        "| Case | Layer | Result | Reason |\n|---|---|---|---|\n" <> Enum.join(rows, "\n") <> "\n"

    File.write!(Path.join(dir, "summary.md"), text)
  end

  def redact(value) when is_map(value) do
    Map.new(value, fn {key, item} ->
      if String.downcase(to_string(key)) in Enum.map(@secret_keys, &String.downcase/1),
        do: {key, "[REDACTED]"},
        else: {key, redact(item)}
    end)
  end

  def redact(value) when is_list(value), do: Enum.map(value, &redact/1)

  def redact(value) when is_binary(value) do
    secrets = ~w(OPENAI_API_KEY ANTHROPIC_API_KEY OPENROUTER_API_KEY GOOGLE_API_KEY GROQ_API_KEY)

    Enum.reduce(secrets, value, fn key, text ->
      case System.get_env(key) do
        secret when is_binary(secret) and byte_size(secret) > 6 ->
          String.replace(text, secret, "[REDACTED]")

        _ ->
          text
      end
    end)
  end

  def redact(value), do: value

  def stringify(%_{} = value), do: value |> Map.from_struct() |> stringify()

  def stringify(value) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _item} -> if is_atom(key), do: 1, else: 0 end)
    |> Map.new(fn {key, item} -> {to_string(key), stringify(item)} end)
  end

  def stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)
  def stringify(value) when is_tuple(value), do: value |> Tuple.to_list() |> stringify()

  def stringify(value) when is_atom(value) and value not in [nil, true, false],
    do: Atom.to_string(value)

  def stringify(value) when is_pid(value) or is_reference(value) or is_function(value),
    do: "[internal]"

  def stringify(value), do: value

  def hash(path),
    do: path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

  def now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  def transaction(dir, callback),
    do: :global.trans({{__MODULE__, Path.expand(dir)}, self()}, callback)

  defp git_revision do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {value, 0} -> String.trim(value)
      _ -> "unknown"
    end
  end

  defp git_dirty? do
    case System.cmd("git", ["status", "--porcelain"], stderr_to_stdout: true) do
      {"", 0} -> false
      _ -> true
    end
  end

  defp suite_sources_hash do
    Path.wildcard(Path.join(__DIR__, "**/*"))
    |> Enum.filter(&File.regular?/1)
    |> Enum.sort()
    |> Enum.map_join(fn path -> Path.relative_to(path, __DIR__) <> ":" <> hash(path) end)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
