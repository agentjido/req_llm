defmodule ReqLLM.Test.Billing.Reference do
  @moduledoc false

  alias ReqLLM.Test.Billing.Money

  @book Path.join(__DIR__, "rates/book.json")

  def book, do: @book |> File.read!() |> Jason.decode!()
  def rates!(model, book_data \\ book()), do: Map.fetch!(book_data["models"], model)

  def calculate(model, body, request \\ %{}, book_data \\ book()) do
    rates = rates!(model, book_data)
    [provider, _id] = String.split(model, ":", parts: 2)

    with true <- is_map(body),
         {:ok, counts} <- counts(provider, body, request),
         {:ok, factors} <- factors(rates, counts, body, request),
         :ok <- rates_complete?(rates, counts),
         {:ok, rows} <- rows(rates, counts, factors) do
      total = Enum.sum(Enum.map(rows, & &1["expected_micros"]))

      %{
        "status" => "priced",
        "currency" => "USD",
        "total" => Money.usd(total),
        "total_micros" => total,
        "line_items" => rows,
        "counts" => counts,
        "rate_source" => rates["source"],
        "rates_checked_at" => rates["checked_at"]
      }
    else
      reason -> %{"status" => "unknown", "reason" => inspect(reason), "line_items" => []}
    end
  rescue
    error in [KeyError, ArgumentError] ->
      %{"status" => "unknown", "reason" => Exception.message(error), "line_items" => []}
  end

  def response_body(%{"streaming" => false, "response" => %{"body" => body}}), do: body

  def response_body(%{"chunks" => chunks}) do
    chunks
    |> Enum.map(&Base.decode64!(&1["b64"]))
    |> IO.iodata_to_binary()
    |> sse_events()
    |> combine_events()
  end

  def response_body(%{"frames" => frames}) do
    frames
    |> Enum.filter(&(&1["direction"] == "server"))
    |> Enum.map(& &1["event"])
    |> combine_events()
  end

  def sse_events(raw) do
    raw
    |> String.split(~r/\r?\n\r?\n/, trim: true)
    |> Enum.flat_map(fn frame ->
      payload =
        frame
        |> String.split(~r/\r?\n/)
        |> Enum.filter(&String.starts_with?(&1, "data:"))
        |> Enum.map_join("\n", &String.trim_leading(String.replace_prefix(&1, "data:", "")))

      case Jason.decode(payload) do
        {:ok, value} when is_map(value) -> [value]
        _ -> []
      end
    end)
  end

  defp rates_complete?(rates, counts) do
    fields =
      %{
        "input" => counts["input"],
        "output" => counts["output"],
        "cache_read" => counts["cache_read"]
      }
      |> Map.merge(counts["writes"])

    if Enum.all?(fields, fn {key, quantity} -> quantity == 0 or is_binary(rates[key]) end),
      do: :ok,
      else: {:error, :missing_rate}
  end

  defp combine_events(events) do
    Enum.reduce(events, %{}, fn event, acc ->
      cond do
        is_map(event["response"]) ->
          Map.merge(acc, event["response"])

        is_map(event["message"]) ->
          Map.merge(acc, event["message"])

        is_map(event["usage"]) ->
          usage = Map.merge(Map.get(acc, "usage", %{}), event["usage"])
          acc |> Map.merge(Map.drop(event, ["usage"])) |> Map.put("usage", usage)

        Map.has_key?(event, "service_tier") ->
          Map.put(acc, "service_tier", event["service_tier"])

        true ->
          acc
      end
    end)
  end

  defp counts(provider, %{"usage" => usage} = body, request) when is_map(usage) do
    keys =
      if provider == "anthropic",
        do: {"input_tokens", "output_tokens"},
        else:
          if(Map.has_key?(usage, "prompt_tokens"),
            do: {"prompt_tokens", "completion_tokens"},
            else: {"input_tokens", "output_tokens"}
          )

    {input_key, output_key} = keys

    with {:ok, input} <- count(usage[input_key]),
         {:ok, output} <- count(usage[output_key]),
         {:ok, read} <- cache_read(provider, usage),
         {:ok, writes} <- cache_writes(provider, usage, request),
         {:ok, tools} <- tools(usage, body) do
      written = Enum.sum(Map.values(writes))
      uncached = if provider == "anthropic", do: input, else: input - read - written
      prompt = if provider == "anthropic", do: input + read + written, else: input

      if uncached < 0,
        do: {:error, :cache_exceeds_input},
        else:
          {:ok,
           %{
             "input" => uncached,
             "output" => output,
             "cache_read" => read,
             "writes" => writes,
             "prompt" => prompt,
             "tools" => tools,
             "input_source" => "/usage/#{input_key}",
             "output_source" => "/usage/#{output_key}",
             "read_source" => read_source(provider, usage),
             "write_source" => write_source(provider, usage)
           }}
    end
  end

  defp counts(_, _, _), do: {:error, :unreported_usage}
  defp count(value) when is_integer(value) and value >= 0, do: {:ok, value}

  defp count(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, ""} when number >= 0 -> {:ok, number}
      _ -> {:error, :invalid_count}
    end
  end

  defp count(_), do: {:error, :invalid_count}

  defp read_source("anthropic", _usage), do: "/usage/cache_read_input_tokens"
  defp read_source(_, usage), do: "/usage/#{details_key(usage)}/cached_tokens"
  defp write_source("anthropic", _usage), do: "/usage/cache_creation"
  defp write_source(_, usage), do: "/usage/#{details_key(usage)}/cache_write_tokens"

  defp details_key(usage),
    do:
      if(Map.has_key?(usage, "input_tokens_details"),
        do: "input_tokens_details",
        else: "prompt_tokens_details"
      )

  defp write_pointer(counts, "cache_5m"),
    do: counts["write_source"] <> "/ephemeral_5m_input_tokens"

  defp write_pointer(counts, "cache_1h"),
    do: counts["write_source"] <> "/ephemeral_1h_input_tokens"

  defp write_pointer(counts, _), do: counts["write_source"]

  defp cache_read("anthropic", usage), do: count(Map.get(usage, "cache_read_input_tokens", 0))

  defp cache_read(_, usage),
    do: detail(usage, ["input_tokens_details", "prompt_tokens_details"], "cached_tokens")

  defp detail(usage, keys, field) do
    Enum.reduce_while(keys, {:ok, 0}, fn key, acc ->
      case Map.get(usage, key) do
        nil ->
          {:cont, acc}

        value when is_map(value) ->
          if Map.has_key?(value, field), do: {:halt, count(value[field])}, else: {:cont, acc}

        _ ->
          {:halt, {:error, :invalid_details}}
      end
    end)
  end

  defp cache_writes("anthropic", usage, request) do
    with {:ok, total} <- count(Map.get(usage, "cache_creation_input_tokens", 0)) do
      case usage["cache_creation"] do
        groups when is_map(groups) ->
          with {:ok, five} <- count(Map.get(groups, "ephemeral_5m_input_tokens", 0)),
               {:ok, hour} <- count(Map.get(groups, "ephemeral_1h_input_tokens", 0)),
               true <- five + hour == total do
            {:ok, %{"cache_5m" => five, "cache_1h" => hour}}
          else
            _ -> {:error, :incomplete_cache_durations}
          end

        nil when total == 0 ->
          {:ok, %{}}

        nil ->
          case request["cache_ttl"] do
            "5m" -> {:ok, %{"cache_5m" => total}}
            "1h" -> {:ok, %{"cache_1h" => total}}
            _ -> {:error, :unconfirmed_cache_duration}
          end

        _ ->
          {:error, :invalid_cache_durations}
      end
    end
  end

  defp cache_writes(_, usage, _request) do
    with {:ok, write} <-
           detail(usage, ["input_tokens_details", "prompt_tokens_details"], "cache_write_tokens"),
         do: {:ok, %{"cache_write" => write}}
  end

  defp tools(usage, body) do
    output = Map.get(body, "output", [])
    output = if is_list(output), do: output, else: []

    calls =
      Enum.filter(
        output,
        &(is_map(&1) and is_binary(&1["type"]) and String.ends_with?(&1["type"], "_call"))
      )

    unknown = Enum.any?(calls, &(&1["type"] not in ["function_call", "web_search_call"]))
    hosted = Enum.count(calls, &(&1["type"] == "web_search_call"))
    details = usage["server_side_tool_usage_details"] || usage["server_side_tool_usage"] || %{}

    if not is_map(details) or unknown do
      {:error, :unknown_hosted_tool}
    else
      Enum.reduce_while(details, {:ok, hosted}, fn {key, value}, {:ok, known} ->
        with true <- key == "web_search_calls",
             {:ok, reported} <- count(value) do
          {:cont, {:ok, max(known, reported)}}
        else
          _ -> {:halt, {:error, :unknown_tool_counter}}
        end
      end)
    end
  end

  defp factors(rates, counts, body, request) do
    tier = Map.get(body, "service_tier")
    host = request |> Map.get("url", "") |> URI.parse() |> Map.get(:host)
    host = if is_binary(host), do: String.downcase(host), else: nil
    api = request |> Map.get("url", "") |> URI.parse() |> Map.get(:path)

    region =
      case host do
        "api.openai.com" -> "1"
        value when value in ["eu.api.openai.com", "us.api.openai.com"] -> "1.1"
        _ -> Map.get(request, "regional_multiplier")
      end

    tier_factor =
      case tier do
        "default" -> "1"
        "flex" -> "0.5"
        value when value in ["fast", "priority"] -> "2"
        _ -> nil
      end

    cond do
      rates["tier_required"] == true and api not in ["/v1/responses", "/v1/chat/completions"] ->
        {:error, :unconfirmed_api_tariff}

      rates["tier_required"] == true and is_nil(tier_factor) ->
        {:error, :unconfirmed_service_tier}

      rates["regional_required"] == true and is_nil(region) ->
        {:error, :unconfirmed_processing_region}

      true ->
        long = counts["prompt"] > Map.get(rates, "threshold", 1_000_000_000)
        {:ok, %{tier: tier_factor || "1", region: region || "1", long: long}}
    end
  end

  defp rows(rates, counts, factors) do
    base = [
      {"input", counts["input"], counts["input_source"]},
      {"output", counts["output"], counts["output_source"]},
      {"cache_read", counts["cache_read"], counts["read_source"]}
    ]

    writes =
      Enum.map(counts["writes"], fn {key, count} ->
        {key, count, write_pointer(counts, key)}
      end)

    token_rows =
      Enum.map(base ++ writes, fn {key, quantity, source} ->
        multiplier = band_multiplier(rates, key, factors.long)
        {n1, d1} = Money.fraction(multiplier)
        {n2, d2} = Money.fraction(factors.tier)
        {n3, d3} = Money.fraction(factors.region)
        scaled_rate = rates[key] || "0"
        {rn, rd} = Money.fraction(scaled_rate)
        per = 1_000_000
        numerator = rn * n1 * n2 * n3 * quantity * 1_000_000
        denominator = rd * d1 * d2 * d3 * per
        micros = div(numerator * 2 + denominator, denominator * 2)

        %{
          "meter" => key,
          "quantity" => quantity,
          "source" => source,
          "rate" => scaled_rate,
          "per" => per,
          "band_multiplier" => multiplier,
          "tier_multiplier" => factors.tier,
          "regional_multiplier" => factors.region,
          "formula" =>
            "#{quantity} * #{scaled_rate} / #{per} * #{multiplier} * #{factors.tier} * #{factors.region}",
          "expected_micros" => micros,
          "unrounded_usd" => Money.decimal(numerator, denominator * 1_000_000),
          "unrounded_fraction" => %{
            "numerator" => numerator,
            "denominator" => denominator * 1_000_000
          },
          "effective_rate_micros" => div(rn * n1 * n2 * n3 * 1_000_000, rd * d1 * d2 * d3),
          "expected_usd" => Money.usd(micros)
        }
      end)

    if counts["tools"] > 0 and is_nil(rates["web_search"]) do
      {:error, :missing_tool_rate}
    else
      tools = if counts["tools"] == 0, do: [], else: [tool_row(rates, counts["tools"])]
      {:ok, token_rows ++ tools}
    end
  end

  defp band_multiplier(_rates, _key, false), do: "1"

  defp band_multiplier(rates, "output", true),
    do: rates["long_output_multiplier"] || rates["long_multiplier"] || "1"

  defp band_multiplier(rates, _key, true),
    do: rates["long_input_multiplier"] || rates["long_multiplier"] || "1"

  defp tool_row(rates, count) do
    micros = Money.micros(rates["web_search"], count, 1000)

    %{
      "meter" => "web_search",
      "quantity" => count,
      "source" => "/output/*/web_search_call",
      "rate" => rates["web_search"],
      "per" => 1000,
      "formula" => "#{count} * #{rates["web_search"]} / 1000",
      "expected_micros" => micros,
      "unrounded_usd" =>
        Money.decimal(
          elem(Money.fraction(rates["web_search"]), 0) * count,
          elem(Money.fraction(rates["web_search"]), 1) * 1000
        ),
      "effective_rate_micros" => Money.micros(rates["web_search"], 1, 1),
      "expected_usd" => Money.usd(micros)
    }
  end
end
