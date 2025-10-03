defmodule ReqLLM.ParamTransform do
  @moduledoc """
  Composable parameter transformation engine for applying model-specific rules to options.

  Supports operations like drop, rename, set_default, enforce_constant, validate, and transform
  to handle model-specific parameter requirements in a declarative way.
  """

  @type key :: atom
  @type value :: term

  @type step ::
          {:drop, key, message :: String.t() | nil}
          | {:rename, from :: key, to :: key, message :: String.t() | nil}
          | {:set_default, key, value, message :: String.t() | nil}
          | {:enforce_constant, key, value, on_mismatch :: :drop | :fix | :error,
             message :: String.t()}
          | {:validate, key, (value -> boolean), message :: String.t()}
          | {:transform, key, (value -> value), message :: String.t() | nil}

  @doc """
  Apply a sequence of transformation steps to a keyword list of options.

  Returns `{transformed_opts, warnings}` where warnings is a list of messages
  generated during transformations.

  ## Examples

      iex> opts = [temperature: 0.5, max_tokens: 100]
      iex> steps = [
      ...>   {:drop, :temperature, "Temperature not supported"},
      ...>   {:rename, :max_tokens, :max_completion_tokens, "Renamed for reasoning model"}
      ...> ]
      iex> {result, warnings} = ReqLLM.ParamTransform.apply(opts, steps)
      iex> result
      [max_completion_tokens: 100]
      iex> warnings
      ["Renamed for reasoning model", "Temperature not supported"]
  """
  @spec apply(Keyword.t(), [step]) :: {Keyword.t(), [String.t()]}
  def apply(opts, steps) do
    Enum.reduce(steps, {opts, []}, fn step, acc -> apply_step(acc, step) end)
  end

  defp apply_step({opts, warns}, {:drop, k, msg}) do
    if Keyword.has_key?(opts, k) do
      {Keyword.delete(opts, k), maybe_warn(warns, msg)}
    else
      {opts, warns}
    end
  end

  defp apply_step({opts, warns}, {:rename, from, to, msg}) do
    case Keyword.pop(opts, from) do
      {nil, _opts} -> {opts, warns}
      {val, opts_rest} -> {Keyword.put_new(opts_rest, to, val), maybe_warn(warns, msg)}
    end
  end

  defp apply_step({opts, warns}, {:set_default, k, v, msg}) do
    if Keyword.has_key?(opts, k) do
      {opts, warns}
    else
      {Keyword.put(opts, k, v), maybe_warn(warns, msg)}
    end
  end

  defp apply_step({opts, warns}, {:enforce_constant, k, v, on_mismatch, msg}) do
    case Keyword.fetch(opts, k) do
      :error ->
        {opts, warns}

      {:ok, ^v} ->
        {opts, warns}

      {:ok, _other} ->
        case on_mismatch do
          :drop -> {Keyword.delete(opts, k), maybe_warn(warns, msg)}
          :fix -> {Keyword.put(opts, k, v), maybe_warn(warns, msg)}
          :error -> {opts, [msg | warns]}
        end
    end
  end

  defp apply_step({opts, warns}, {:validate, k, fun, msg}) do
    case Keyword.fetch(opts, k) do
      :error ->
        {opts, warns}

      {:ok, val} ->
        if fun.(val), do: {opts, warns}, else: {opts, [msg | warns]}
    end
  end

  defp apply_step({opts, warns}, {:transform, k, fun, msg}) do
    case Keyword.fetch(opts, k) do
      :error ->
        {opts, warns}

      {:ok, val} ->
        {Keyword.put(opts, k, fun.(val)), maybe_warn(warns, msg)}
    end
  end

  defp maybe_warn(warns, nil), do: warns
  defp maybe_warn(warns, msg), do: [msg | warns]
end
