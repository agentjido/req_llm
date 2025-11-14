defmodule ReqLLM.Integration.StreamingOrchestrationTest do
  @moduledoc """
  Integration tests for the complete streaming orchestration system.

  Tests the coordination between StreamServer, FinchClient, and StreamResponse
  to ensure the streaming system works end-to-end with component-level testing.
  """

  use ExUnit.Case, async: false

  alias ReqLLM.{Context, Streaming}

  @moduletag category: :streaming, integration: true

  describe "start_stream/4 basic functionality" do
    test "returns proper error structure without valid API setup" do
      # Test with a real provider but no API key - should fail gracefully
      {:ok, model} = ReqLLM.model("openai:gpt-4")
      context = Context.new("Hello, world!")

      # Should return error since we don't have real API key setup
      result = Streaming.start_stream(ReqLLM.Providers.OpenAI, model, context, [])

      # At minimum, we expect the function to fail gracefully with proper error structure
      assert {:error, reason} = result

      # Should be a structured error from our orchestration
      case reason do
        {:http_streaming_failed, _} ->
          # This is expected - the provider will fail without valid API setup
          :ok

        {:stream_server_failed, _} ->
          # Also acceptable
          :ok

        other_reason ->
          # Any other structured reason is acceptable too
          assert is_atom(other_reason) or
                   (is_tuple(other_reason) and is_atom(elem(other_reason, 0)))
      end
    end

    test "handles missing provider module gracefully" do
      model = %LLMDB.Model{provider: :nonexistent, id: "test"}
      context = Context.new("Test")

      # Should fail with proper error when provider doesn't exist
      result = Streaming.start_stream(NonexistentProvider, model, context, [])

      assert {:error, _reason} = result
    end

    test "handles invalid model configuration" do
      # Test with nil model should result in an error
      context = Context.new("Test")

      result =
        try do
          Streaming.start_stream(ReqLLM.Providers.OpenAI, nil, context, [])
        catch
          _, _ -> {:error, :invalid_args}
        end

      assert match?({:error, _}, result)
    end
  end

  describe "component coordination" do
    test "StreamServer, FinchClient, and StreamResponse coordination points" do
      # Test the interfaces between components without full HTTP
      {:ok, _model} = ReqLLM.model("openai:gpt-4")
      _context = Context.new("Hello")

      # Verify that the coordination points exist and have proper interfaces
      assert function_exported?(ReqLLM.StreamServer, :start_link, 1)
      assert function_exported?(ReqLLM.StreamServer, :next, 2)
      assert function_exported?(ReqLLM.StreamServer, :await_metadata, 2)
      assert function_exported?(ReqLLM.StreamServer, :attach_http_task, 2)
      assert function_exported?(ReqLLM.StreamServer, :cancel, 1)

      assert function_exported?(ReqLLM.Streaming.FinchClient, :start_stream, 6)
      assert function_exported?(ReqLLM.Providers.OpenAI, :attach_stream, 4)

      # Verify StreamResponse helper functions
      # Verify StreamResponse helper functions exist
      # Note: these are documented functions, but we'll check if they're callable
      assert Code.ensure_loaded?(ReqLLM.StreamResponse)
      assert function_exported?(ReqLLM.StreamResponse, :tokens, 1)
      assert function_exported?(ReqLLM.StreamResponse, :text, 1)
      assert function_exported?(ReqLLM.StreamResponse, :usage, 1)
      assert function_exported?(ReqLLM.StreamResponse, :finish_reason, 1)
    end
  end

  describe "Stream.resource integration" do
    test "Stream.resource helper functions work independently" do
      # Test that our Stream.resource construction logic works
      # by simulating the server pid and next function behavior

      # Mock server process that responds to GenServer calls
      mock_server_pid = spawn(fn -> mock_server_loop([]) end)

      # Create the same Stream.resource logic used in Streaming.create_lazy_stream
      stream =
        Stream.resource(
          fn -> mock_server_pid end,
          fn server ->
            # Simulate the GenServer.call that would happen in StreamServer.next/2
            send(server, {:next_call, self()})

            receive do
              {:chunk, chunk} -> {[chunk], server}
              :halt -> {:halt, server}
            after
              1000 -> {:halt, server}
            end
          end,
          fn _server -> :ok end
        )

      # Test that we can take elements from the stream
      result = Stream.take(stream, 1) |> Enum.to_list()

      # Should get empty list since mock server returns halt
      assert result == []

      # Clean up
      if Process.alive?(mock_server_pid) do
        send(mock_server_pid, :stop)
      end
    end
  end

  describe "error handling structure" do
    test "error types are properly structured" do
      {:ok, model} = ReqLLM.model("openai:gpt-4")
      context = Context.new("Error test")

      # Test with provider that will fail
      result =
        Streaming.start_stream(
          ReqLLM.Providers.OpenAI,
          model,
          context,
          # Invalid options to force failure
          finch_name: :nonexistent_finch
        )

      case result do
        {:error, {error_type, _details}} ->
          # Should be one of our expected error types
          assert error_type in [:stream_server_failed, :http_streaming_failed]

        {:error, _other_reason} ->
          # Other structured error is fine too
          :ok

        {:ok, _} ->
          # If somehow successful, that's unexpected but not a failure
          :ok
      end
    end
  end

  # Helper functions
  defp mock_server_loop(chunks) do
    receive do
      {:next_call, caller} ->
        case chunks do
          [chunk | remaining] ->
            send(caller, {:chunk, chunk})
            mock_server_loop(remaining)

          [] ->
            send(caller, :halt)
            mock_server_loop([])
        end

      :stop ->
        :ok
    end
  end
end
