defmodule ReqLLM.JSON.OrderedObject do
  @moduledoc """
  A JSON object whose properties keep the order they were declared in.

  JSON object order is not semantic, but structured-output schemas use it: OpenAI
  reads the position of each property in `properties` as the field order. A map
  cannot express that, so `ReqLLM.Schema.apply_property_ordering/1` returns this
  struct, and the JSON codec is asked to encode `values` as an object in order.

  Jason and the Elixir `JSON` module are covered out of the box. Codecs that use
  another representation, such as Torque's jiffy-style `{[{key, value}]}` proplist,
  implement `c:ReqLLM.JSON.Codec.encode_ordered_to_iodata!/1` and convert with
  `ReqLLM.JSON.to_jiffy_ordered/1`.
  """

  @type t :: %__MODULE__{values: [{term(), term()}]}

  defstruct values: []

  @behaviour Access

  def fetch(%{values: values}, key) do
    case :lists.keyfind(key, 1, values) do
      {_, value} -> {:ok, value}
      false -> :error
    end
  end

  def get_and_update(%{values: values} = object, key, fun) do
    {result, new_values} = get_and_update(values, [], key, fun)
    {result, %{object | values: new_values}}
  end

  def pop(%{values: values} = object, key, default \\ nil) do
    case :lists.keytake(key, 1, values) do
      {_, value, rest} -> {value, %{object | values: rest}}
      false -> {default, object}
    end
  end

  defp get_and_update([{key, current} | tail], acc, key, fun) do
    case fun.(current) do
      {get, update} -> {get, :lists.reverse(acc, [{key, update} | tail])}
      :pop -> {current, :lists.reverse(acc, tail)}
      other -> raise get_and_update_error(other)
    end
  end

  defp get_and_update([head | tail], acc, key, fun),
    do: get_and_update(tail, [head | acc], key, fun)

  defp get_and_update([], acc, key, fun) do
    case fun.(nil) do
      {get, update} -> {get, [{key, update} | :lists.reverse(acc)]}
      :pop -> {nil, :lists.reverse(acc)}
      other -> raise get_and_update_error(other)
    end
  end

  defp get_and_update_error(other),
    do: "the given function must return a two-element tuple or :pop, got: #{inspect(other)}"

  @doc """
  Builds an ordered object from a list of key-value pairs.

  ## Examples

      iex> object = ReqLLM.JSON.OrderedObject.new([{"b", 2}, {"a", 1}])
      iex> Jason.encode!(object)
      ~s({"b":2,"a":1})

  """
  @spec new([{term(), term()}]) :: t()
  def new(values) when is_list(values), do: %__MODULE__{values: values}
end

defimpl Enumerable, for: ReqLLM.JSON.OrderedObject do
  def reduce(%{values: values}, acc, fun), do: Enumerable.List.reduce(values, acc, fun)
  def member?(%{values: values}, value), do: {:ok, Enum.member?(values, value)}
  def count(%{values: values}), do: {:ok, length(values)}
  def slice(_object), do: {:error, __MODULE__}
end

defimpl Jason.Encoder, for: ReqLLM.JSON.OrderedObject do
  def encode(%{values: values}, opts), do: Jason.Encode.keyword(values, opts)
end

if Code.ensure_loaded?(JSON.Encoder) do
  defimpl JSON.Encoder, for: ReqLLM.JSON.OrderedObject do
    def encode(%{values: values}, encoder) do
      pairs =
        Enum.map(values, fn {key, value} ->
          [JSON.protocol_encode(key, encoder), ?:, JSON.protocol_encode(value, encoder)]
        end)

      [?{, Enum.intersperse(pairs, ?,), ?}]
    end
  end
end
