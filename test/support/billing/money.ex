defmodule ReqLLM.Test.Billing.Money do
  @moduledoc false

  def fraction(value) when is_binary(value) do
    case Regex.run(~r/\A(\d+)(?:\.(\d+))?\z/, value) do
      [_, whole] ->
        {String.to_integer(whole), 1}

      [_, whole, decimals] ->
        scale = Integer.pow(10, byte_size(decimals))
        {String.to_integer(whole) * scale + String.to_integer(decimals), scale}

      _ ->
        raise ArgumentError, "invalid non-negative decimal: #{inspect(value)}"
    end
  end

  def micros(rate, quantity, per, multiplier \\ "1")
      when is_integer(quantity) and quantity >= 0 and is_integer(per) and per > 0 do
    {rate_n, rate_d} = fraction(rate)
    {factor_n, factor_d} = fraction(multiplier)
    numerator = rate_n * factor_n * quantity * 1_000_000
    denominator = rate_d * factor_d * per
    div(numerator * 2 + denominator, denominator * 2)
  end

  def usd(micros) when is_integer(micros) do
    sign = if micros < 0, do: "-", else: ""
    value = abs(micros)

    sign <>
      Integer.to_string(div(value, 1_000_000)) <>
      "." <>
      String.pad_leading(Integer.to_string(rem(value, 1_000_000)), 6, "0")
  end

  def observed(value) when is_number(value), do: round(value * 1_000_000)
  def observed(_), do: nil

  def decimal(numerator, denominator, places \\ 12) do
    scale = Integer.pow(10, places)
    value = div(numerator * scale, denominator)

    Integer.to_string(div(value, scale)) <>
      "." <>
      String.pad_leading(Integer.to_string(rem(value, scale)), places, "0")
  end
end
