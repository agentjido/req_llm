#!/usr/bin/env elixir

Mix.install([
  {:req_llm, path: Path.expand("..", __DIR__)}
])

IO.puts("=== Verifying Issue #65: StreamServer HTTP Error Detection ===\n")

IO.puts("Testing with invalid API key to trigger HTTP 401 error...")
IO.puts("Expected: {:error, %{status: 401, ...}}")
IO.puts("Bug behavior: {:ok, %StreamResponse{stream: empty}}\n")

# Save original key and set invalid one
original_key = System.get_env("ANTHROPIC_API_KEY")
System.put_env("ANTHROPIC_API_KEY", "invalid-key-12345")

messages = [
  %{role: "user", content: "test"}
]

result = case ReqLLM.stream_text("anthropic:claude-sonnet-4-20250514", messages) do
  {:ok, response} ->
    IO.puts("Result: {:ok, stream_response}")
    IO.puts("Consuming stream...\n")
    
    stream_list = Enum.to_list(response.stream)
    
    IO.puts("Waiting for metadata...")
    metadata_result = Task.await(response.metadata_task, 10_000)
    
    IO.puts("Stream content: #{if stream_list == [], do: "EMPTY", else: inspect(stream_list)}")
    IO.puts("Metadata result: #{inspect(metadata_result)}")
    
    cond do
      is_struct(metadata_result, ReqLLM.Error.API.Request) ->
        IO.puts("\n✅ BUG FIXED: Error properly captured in metadata")
        IO.puts("Status: #{metadata_result.status}")
        IO.puts("Reason: #{metadata_result.reason}")
        {:fixed, metadata_result}
        
      stream_list == [] && is_map(metadata_result) && metadata_result[:status] >= 400 ->
        IO.puts("\n✅ BUG FIXED: Error status in metadata (#{metadata_result[:status]})")
        {:fixed, metadata_result}
        
      stream_list == [] ->
        IO.puts("\n❌ BUG CONFIRMED: Empty stream with no error information")
        System.halt(1)
        
      true ->
        IO.puts("\n✅ Stream worked normally")
        {:ok, response}
    end
    
  {:error, error} ->
    IO.puts("Result: {:error, ...}")
    IO.puts("Error: #{inspect(error)}")
    IO.puts("\n✅ BUG FIXED: Properly returns error for invalid request")
    {:fixed, error}
end

# Restore original key
if original_key do
  System.put_env("ANTHROPIC_API_KEY", original_key)
else
  System.delete_env("ANTHROPIC_API_KEY")
end

case result do
  {:fixed, _} -> System.halt(0)
  _ -> :ok
end
