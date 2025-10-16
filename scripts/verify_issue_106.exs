#!/usr/bin/env elixir

Mix.install([{:req_llm, path: "."}])

schema = [
  name: [type: :string, required: true],
  age: [type: :pos_integer, required: true]
]

IO.puts("Testing Issue #106: output: :array option")
IO.puts("=" |> String.duplicate(50))

result = ReqLLM.generate_object(
  "anthropic:claude-3-sonnet",
  "Generate 3 heroes",
  schema,
  output: :array
)

case result do
  {:ok, _objects} ->
    IO.puts("✓ SUCCESS: output: :array option works")
    System.halt(0)

  {:error, %{error: %{message: msg}}} when is_binary(msg) ->
    if String.contains?(msg, "unknown options [:output]") do
      IO.puts("✗ BUG CONFIRMED: output option not in schema")
      IO.puts("Error: #{msg}")
      System.halt(1)
    else
      IO.puts("✗ OTHER ERROR: #{msg}")
      System.halt(2)
    end

  {:error, error} ->
    IO.puts("✗ UNEXPECTED ERROR: #{inspect(error)}")
    System.halt(2)
end
