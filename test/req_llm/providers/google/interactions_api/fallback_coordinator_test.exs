defmodule ReqLLM.Providers.Google.InteractionsAPI.FallbackCoordinatorTest do
  use ExUnit.Case, async: true

  import ReqLLM.Test.Google.InteractionsAPIHelpers, only: [await_extra_links: 2, sse_frame: 2]

  alias ReqLLM.Context
  alias ReqLLM.Providers.Google.InteractionsAPI
  alias ReqLLM.Providers.Google.InteractionsAPI.FallbackCoordinator
  alias ReqLLM.StreamChunk
  alias ReqLLM.StreamResponse
  alias ReqLLM.StreamResponse.MetadataHandle
  alias ReqLLM.Test.Google.InteractionsAPIHelpers.SSEPlug

  @model_id "google:gemini-4-hydrogen"
  @api_key "test-stream-key"

  describe "v1 to v1beta FallbackCoordinator lifecycle" do
    test "cleans up Bandit fallback coordinator links and allows idempotent cancel" do
      ok_events = [
        sse_frame(
          %{
            "event_type" => "interaction.completed",
            "interaction" => %{
              "id" => "int_leak_200",
              "status" => "completed",
              "steps" => [
                %{
                  "type" => "model_output",
                  "content" => [%{"type" => "text", "text" => "Primary ok"}]
                }
              ]
            }
          },
          "evt_ok_1"
        ),
        "data: [DONE]\n\n"
      ]

      ok_server =
        start_supervised!(
          {Bandit,
           plug: {SSEPlug, owner: self(), resume_events: ok_events},
           port: 0,
           ip: {127, 0, 0, 1},
           startup_log: false},
          id: {:bandit_v1_ok_cleanup, make_ref()}
        )

      {:ok, {_addr, ok_port}} = ThousandIsland.listener_info(ok_server)

      beta_events = [
        sse_frame(
          %{
            "event_type" => "interaction.completed",
            "interaction" => %{
              "id" => "int_leak_404",
              "status" => "completed",
              "steps" => [
                %{
                  "type" => "model_output",
                  "content" => [%{"type" => "text", "text" => "Beta fallback ok"}]
                }
              ]
            }
          },
          "evt_beta_1"
        ),
        "data: [DONE]\n\n"
      ]

      beta_server =
        start_supervised!(
          {Bandit,
           plug: {SSEPlug, owner: self(), v1_not_found: true, v1beta_resume_events: beta_events},
           port: 0,
           ip: {127, 0, 0, 1},
           startup_log: false},
          id: {:bandit_v1beta_cleanup, make_ref()}
        )

      {:ok, {_addr, beta_port}} = ThousandIsland.listener_info(beta_server)

      {:links, links_before} = Process.info(self(), :links)

      {:ok, s1} =
        InteractionsAPI.stream("int_leak_200",
          api_key: @api_key,
          base_url: "http://127.0.0.1:#{ok_port}/v1"
        )

      {:ok, resp1} = StreamResponse.to_response(s1)
      assert ReqLLM.Response.text(resp1) == "Primary ok"
      assert await_extra_links(links_before, []) == []

      {:ok, s2} =
        InteractionsAPI.stream("int_leak_404",
          api_key: @api_key,
          base_url: "http://127.0.0.1:#{beta_port}/v1"
        )

      {:ok, resp2} = StreamResponse.to_response(s2)
      assert ReqLLM.Response.text(resp2) == "Beta fallback ok"
      assert await_extra_links(links_before, []) == []

      {:ok, s3} =
        InteractionsAPI.stream("int_leak_200",
          api_key: @api_key,
          base_url: "http://127.0.0.1:#{ok_port}/v1"
        )

      assert Enum.any?(Enum.to_list(s3.stream), &(&1.text == "Primary ok"))
      assert await_extra_links(links_before, [s3.metadata_handle]) == [s3.metadata_handle]
      assert :ok = s3.cancel.()
      assert :ok = s3.cancel.()
      assert :ok = StreamResponse.close(s3)
      assert await_extra_links(links_before, []) == []
    end

    test "starts fallback off-process and unblocks concurrent callers until cleanup" do
      {:ok, model} = ReqLLM.model(@model_id)
      context = Context.new([Context.user("Fallback test")])
      test_pid = self()
      {:ok, fallback_meta} = MetadataHandle.start_link(fn -> %{finish_reason: :stop} end)

      fallback_stream = %StreamResponse{
        stream: [StreamChunk.text("Beta")],
        metadata_handle: fallback_meta,
        cancel: fn ->
          send(test_pid, :fallback_cancelled)
          :ok
        end,
        model: model,
        context: context
      }

      {:ok, coord1} =
        FallbackCoordinator.start_link(self(), fn ->
          send(test_pid, {:starter_entered, self()})

          receive do
            {:release, reply} -> reply
          end
        end)

      w1 = Task.async(fn -> FallbackCoordinator.start_fallback(coord1) end)
      w2 = Task.async(fn -> FallbackCoordinator.start_fallback(coord1) end)

      assert_receive {:starter_entered, starter1}, 1_000
      refute_receive {:starter_entered, _}, 50

      assert :unknown == FallbackCoordinator.primary_404(coord1)
      assert :ok == FallbackCoordinator.set_primary_404(coord1, true)
      assert {:known, true} == FallbackCoordinator.primary_404(coord1)

      send(starter1, {:release, {:ok, fallback_stream}})
      assert {:ok, ^fallback_stream} = Task.await(w1, 1_000)
      assert {:ok, ^fallback_stream} = Task.await(w2, 1_000)

      assert :keep == FallbackCoordinator.finish_consumer(coord1, :stream)

      assert {:cleanup, {:started, {:ok, ^fallback_stream}} = fallback_state} =
               FallbackCoordinator.finish_consumer(coord1, :meta)

      assert :ok = FallbackCoordinator.cleanup_fallback(fallback_state)
      assert_receive :fallback_cancelled, 1_000
      refute Process.alive?(coord1)
      refute Process.alive?(fallback_meta)
    end

    test "cancels in-flight fallback starter and triggers late cleanup on arrival" do
      {:ok, model} = ReqLLM.model(@model_id)
      context = Context.new([Context.user("Fallback test")])
      test_pid = self()
      {:ok, late_meta} = MetadataHandle.start_link(fn -> %{finish_reason: :stop} end)
      late_meta_ref = Process.monitor(late_meta)

      late_stream = %StreamResponse{
        stream: [],
        metadata_handle: late_meta,
        cancel: fn ->
          send(test_pid, :late_fallback_cancelled)
          :ok
        end,
        model: model,
        context: context
      }

      {:ok, coord2} =
        FallbackCoordinator.start_link(self(), fn ->
          send(test_pid, {:late_starter_entered, self()})

          receive do
            :release_late -> {:ok, late_stream}
          end
        end)

      w3 = Task.async(fn -> FallbackCoordinator.start_fallback(coord2) end)
      assert_receive {:late_starter_entered, starter2}, 1_000

      assert :none == FallbackCoordinator.cancel(coord2)
      assert {:error, :cancelled} = Task.await(w3, 1_000)
      refute Process.alive?(coord2)

      send(starter2, :release_late)
      assert_receive :late_fallback_cancelled, 1_000
      assert_receive {:DOWN, ^late_meta_ref, :process, ^late_meta, _}, 1_000
    end

    test "propagates error when fallback starter is killed or raises" do
      test_pid = self()

      {:ok, coord3} =
        FallbackCoordinator.start_link(self(), fn ->
          send(test_pid, {:crash_starter_entered, self()})

          receive do
            :never -> :ok
          end
        end)

      w4 = Task.async(fn -> FallbackCoordinator.start_fallback(coord3) end)
      assert_receive {:crash_starter_entered, starter3}, 1_000
      Process.exit(starter3, :kill)
      assert {:error, :killed} = Task.await(w4, 1_000)
      assert :none == FallbackCoordinator.cancel(coord3)

      {:ok, coord4} =
        FallbackCoordinator.start_link(self(), fn ->
          raise "boom"
        end)

      assert {:error, %RuntimeError{message: "boom"}} = FallbackCoordinator.start_fallback(coord4)
      assert :none == FallbackCoordinator.cancel(coord4)
    end

    test "cleans up fallback resources when owner process exits abnormally" do
      {:ok, model} = ReqLLM.model(@model_id)
      context = Context.new([Context.user("Fallback test")])
      test_pid = self()
      {:links, links_before} = Process.info(self(), :links)

      {:ok, caller_meta} = MetadataHandle.start_link(fn -> %{finish_reason: :stop} end)
      caller_meta_ref = Process.monitor(caller_meta)

      caller_stream = %StreamResponse{
        stream: [],
        metadata_handle: caller_meta,
        cancel: fn ->
          send(test_pid, :caller_crash_fallback_cancelled)
          :ok
        end,
        model: model,
        context: context
      }

      caller_pid =
        spawn(fn ->
          {:ok, coord5} =
            FallbackCoordinator.start_link(self(), fn -> {:ok, caller_stream} end)

          send(test_pid, {:coord5, coord5, FallbackCoordinator.start_fallback(coord5)})

          receive do
            :stay_alive -> :ok
          end
        end)

      assert_receive {:coord5, coord5, {:ok, ^caller_stream}}, 1_000
      coord5_ref = Process.monitor(coord5)
      Process.exit(caller_pid, :kill)
      assert_receive {:DOWN, ^coord5_ref, :process, ^coord5, :killed}, 1_000
      assert_receive :caller_crash_fallback_cancelled, 1_000
      assert_receive {:DOWN, ^caller_meta_ref, :process, ^caller_meta, _}, 1_000
      assert await_extra_links(links_before, []) == []
    end

    test "cleans up v1beta fallback coordinator links on early stream halt" do
      beta_events = [
        sse_frame(
          %{
            "event_type" => "step.delta",
            "index" => 0,
            "delta" => %{"type" => "text", "text" => "Beta one"}
          },
          "evt_beta_halt_1"
        ),
        sse_frame(
          %{
            "event_type" => "interaction.completed",
            "interaction" => %{
              "id" => "int_halt_404",
              "status" => "completed",
              "steps" => [
                %{
                  "type" => "model_output",
                  "content" => [%{"type" => "text", "text" => "Beta one"}]
                }
              ]
            }
          },
          "evt_beta_halt_2"
        ),
        "data: [DONE]\n\n"
      ]

      halt_server =
        start_supervised!(
          {Bandit,
           plug: {SSEPlug, owner: self(), v1_not_found: true, v1beta_resume_events: beta_events},
           port: 0,
           ip: {127, 0, 0, 1},
           startup_log: false},
          id: {:bandit_v1beta_early_halt, make_ref()}
        )

      {:ok, {_addr, halt_port}} = ThousandIsland.listener_info(halt_server)
      {:links, links_before_bandit} = Process.info(self(), :links)

      {:ok, s_halt} =
        InteractionsAPI.stream("int_halt_404",
          api_key: @api_key,
          base_url: "http://127.0.0.1:#{halt_port}/v1"
        )

      assert [%StreamChunk{type: :content, text: "Beta one"}] = Enum.take(s_halt.stream, 1)
      assert :ok = StreamResponse.close(s_halt)
      assert await_extra_links(links_before_bandit, []) == []
    end

    test "does not double-halt inner stream after mid-stream failure" do
      {:ok, model} = ReqLLM.model(@model_id)
      context = Context.new([Context.user("Mid-stream failure")])
      {:links, links_before} = Process.info(self(), :links)

      cleanup_count = :atomics.new(1, [])

      inner_stream =
        Stream.resource(
          fn -> :first end,
          fn
            :first -> {[StreamChunk.text("chunk1")], :second}
            :second -> raise "mid-stream boom"
          end,
          fn _state ->
            if :atomics.add_get(cleanup_count, 1, 1) > 1 do
              raise "double cleanup"
            end
          end
        )

      {:ok, primary_meta} = MetadataHandle.start_link(fn -> %{finish_reason: :error} end)

      primary = %StreamResponse{
        stream: inner_stream,
        metadata_handle: primary_meta,
        cancel: fn -> :ok end,
        model: model,
        context: context
      }

      wrapped = InteractionsAPI.wrap_stream_with_v1beta_fallback(primary, model, context, [])

      assert_raise RuntimeError, "mid-stream boom", fn ->
        Enum.to_list(wrapped.stream)
      end

      assert :atomics.get(cleanup_count, 1) == 1
      assert :ok = StreamResponse.close(wrapped)
      assert await_extra_links(links_before, []) == []
    end

    test "does not double-halt inner stream on throw, exit, or Stream.zip mid-stream failure" do
      {:ok, model} = ReqLLM.model(@model_id)
      context = Context.new([Context.user("Mid-stream non-exception failure")])

      for {kind, trigger} <- [
            {:throw, fn -> throw(:mid_throw) end},
            {:exit, fn -> exit(:mid_exit) end}
          ] do
        cleanup_count = :atomics.new(1, [])

        inner_stream =
          Stream.resource(
            fn -> :first end,
            fn
              :first -> {[StreamChunk.text("chunk1")], :second}
              :second -> trigger.()
            end,
            fn _state ->
              if :atomics.add_get(cleanup_count, 1, 1) > 1 do
                raise "double cleanup"
              end
            end
          )

        {:ok, primary_meta} = MetadataHandle.start_link(fn -> %{finish_reason: :error} end)

        primary = %StreamResponse{
          stream: inner_stream,
          metadata_handle: primary_meta,
          cancel: fn -> :ok end,
          model: model,
          context: context
        }

        wrapped = InteractionsAPI.wrap_stream_with_v1beta_fallback(primary, model, context, [])

        caught =
          try do
            wrapped.stream |> Stream.zip([1, 2]) |> Enum.to_list()
          catch
            k, r -> {k, r}
          end

        expected_reason = if(kind == :throw, do: :mid_throw, else: :mid_exit)
        assert caught == {kind, expected_reason}
        assert :atomics.get(cleanup_count, 1) == 1
        assert :ok = StreamResponse.close(wrapped)
      end
    end

    test "halts inner stream exactly once on early halt and consumer error" do
      {:ok, model} = ReqLLM.model(@model_id)
      context = Context.new([Context.user("Fallback mid-stream failure")])

      early_cleanup = :atomics.new(1, [])

      early_stream =
        Stream.resource(
          fn -> :first end,
          fn
            :first -> {[StreamChunk.text("one")], :second}
            :second -> {[StreamChunk.text("two")], :done}
            :done -> {:halt, :done}
          end,
          fn _ -> :atomics.add(early_cleanup, 1, 1) end
        )

      {:ok, early_meta} = MetadataHandle.start_link(fn -> %{finish_reason: :stop} end)

      early_wrapped =
        InteractionsAPI.wrap_stream_with_v1beta_fallback(
          %StreamResponse{
            stream: early_stream,
            metadata_handle: early_meta,
            cancel: fn -> :ok end,
            model: model,
            context: context
          },
          model,
          context,
          []
        )

      assert [%StreamChunk{text: "one"}] = Enum.take(early_wrapped.stream, 1)
      assert :atomics.get(early_cleanup, 1) == 1
      assert :ok = StreamResponse.close(early_wrapped)

      consumer_cleanup = :atomics.new(1, [])

      consumer_stream =
        Stream.resource(
          fn -> :first end,
          fn
            :first -> {[StreamChunk.text("one")], :second}
            :second -> {:halt, :done}
          end,
          fn _ -> :atomics.add(consumer_cleanup, 1, 1) end
        )

      {:ok, consumer_meta} = MetadataHandle.start_link(fn -> %{finish_reason: :stop} end)

      consumer_wrapped =
        InteractionsAPI.wrap_stream_with_v1beta_fallback(
          %StreamResponse{
            stream: consumer_stream,
            metadata_handle: consumer_meta,
            cancel: fn -> :ok end,
            model: model,
            context: context
          },
          model,
          context,
          []
        )

      assert_raise RuntimeError, "consumer boom", fn ->
        Enum.each(consumer_wrapped.stream, fn _ -> raise "consumer boom" end)
      end

      assert :atomics.get(consumer_cleanup, 1) == 1
      assert :ok = StreamResponse.close(consumer_wrapped)
    end
  end
end
