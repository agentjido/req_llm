defmodule ReqLLM.Test.ChunkCollectorTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Test.ChunkCollector

  describe "start_link/0" do
    test "starts a collector" do
      assert {:ok, pid} = ChunkCollector.start_link()
      assert Process.alive?(pid)
      ChunkCollector.stop(pid)
    end
  end

  describe "start_link/1 with name" do
    test "starts a named collector" do
      assert {:ok, _pid} = ChunkCollector.start_link(name: :test_collector)
      assert Process.whereis(:test_collector) != nil
      ChunkCollector.stop(:test_collector)
    end
  end

  describe "add_chunk/2" do
    test "adds chunk with automatic timestamp" do
      {:ok, collector} = ChunkCollector.start_link()

      ChunkCollector.add_chunk(collector, "first chunk")
      Process.sleep(5)
      ChunkCollector.add_chunk(collector, "second chunk")

      chunks = ChunkCollector.get_chunks(collector)

      assert length(chunks) == 2
      assert [first, second] = chunks
      assert first.bin == "first chunk"
      assert second.bin == "second chunk"
      assert second.t_us > first.t_us

      ChunkCollector.stop(collector)
    end

    test "handles empty binaries" do
      {:ok, collector} = ChunkCollector.start_link()

      ChunkCollector.add_chunk(collector, "")
      chunks = ChunkCollector.get_chunks(collector)

      assert [%{bin: "", t_us: _}] = chunks

      ChunkCollector.stop(collector)
    end

    test "handles large chunks" do
      {:ok, collector} = ChunkCollector.start_link()

      large_chunk = String.duplicate("x", 10_000)
      ChunkCollector.add_chunk(collector, large_chunk)

      chunks = ChunkCollector.get_chunks(collector)
      assert [%{bin: ^large_chunk}] = chunks

      ChunkCollector.stop(collector)
    end
  end

  describe "get_chunks/1" do
    test "returns chunks in chronological order" do
      {:ok, collector} = ChunkCollector.start_link()

      ChunkCollector.add_chunk(collector, "1")
      ChunkCollector.add_chunk(collector, "2")
      ChunkCollector.add_chunk(collector, "3")

      chunks = ChunkCollector.get_chunks(collector)
      binaries = Enum.map(chunks, & &1.bin)

      assert binaries == ["1", "2", "3"]

      ChunkCollector.stop(collector)
    end

    test "returns empty list when no chunks collected" do
      {:ok, collector} = ChunkCollector.start_link()

      assert [] = ChunkCollector.get_chunks(collector)

      ChunkCollector.stop(collector)
    end

    test "does not stop the collector" do
      {:ok, collector} = ChunkCollector.start_link()

      ChunkCollector.add_chunk(collector, "chunk")
      _chunks = ChunkCollector.get_chunks(collector)

      assert Process.alive?(collector)

      ChunkCollector.stop(collector)
    end
  end

  describe "count/1" do
    test "returns number of chunks" do
      {:ok, collector} = ChunkCollector.start_link()

      assert 0 = ChunkCollector.count(collector)

      ChunkCollector.add_chunk(collector, "1")
      assert 1 = ChunkCollector.count(collector)

      ChunkCollector.add_chunk(collector, "2")
      ChunkCollector.add_chunk(collector, "3")
      assert 3 = ChunkCollector.count(collector)

      ChunkCollector.stop(collector)
    end
  end

  describe "empty?/1" do
    test "returns true when no chunks" do
      {:ok, collector} = ChunkCollector.start_link()
      assert ChunkCollector.empty?(collector)
      ChunkCollector.stop(collector)
    end

    test "returns false when chunks present" do
      {:ok, collector} = ChunkCollector.start_link()
      ChunkCollector.add_chunk(collector, "chunk")
      refute ChunkCollector.empty?(collector)
      ChunkCollector.stop(collector)
    end
  end

  describe "total_bytes/1" do
    test "calculates total bytes across all chunks" do
      {:ok, collector} = ChunkCollector.start_link()

      assert 0 = ChunkCollector.total_bytes(collector)

      ChunkCollector.add_chunk(collector, "12345")
      assert 5 = ChunkCollector.total_bytes(collector)

      ChunkCollector.add_chunk(collector, "abc")
      assert 8 = ChunkCollector.total_bytes(collector)

      ChunkCollector.stop(collector)
    end

    test "handles UTF-8 multibyte characters correctly" do
      {:ok, collector} = ChunkCollector.start_link()

      ChunkCollector.add_chunk(collector, "€")
      assert 3 = ChunkCollector.total_bytes(collector)

      ChunkCollector.stop(collector)
    end
  end

  describe "clear/1" do
    test "removes all chunks" do
      {:ok, collector} = ChunkCollector.start_link()

      ChunkCollector.add_chunk(collector, "chunk1")
      ChunkCollector.add_chunk(collector, "chunk2")
      assert 2 = ChunkCollector.count(collector)

      ChunkCollector.clear(collector)

      assert 0 = ChunkCollector.count(collector)
      assert [] = ChunkCollector.get_chunks(collector)

      ChunkCollector.stop(collector)
    end

    test "resets start time for subsequent chunks" do
      {:ok, collector} = ChunkCollector.start_link()

      ChunkCollector.add_chunk(collector, "old")
      Process.sleep(10)

      ChunkCollector.clear(collector)

      ChunkCollector.add_chunk(collector, "new")
      chunks = ChunkCollector.get_chunks(collector)

      assert [%{bin: "new", t_us: t}] = chunks
      assert t < 5_000

      ChunkCollector.stop(collector)
    end

    test "does not stop the collector" do
      {:ok, collector} = ChunkCollector.start_link()

      ChunkCollector.add_chunk(collector, "chunk")
      ChunkCollector.clear(collector)

      assert Process.alive?(collector)

      ChunkCollector.stop(collector)
    end
  end

  describe "finish/1" do
    test "returns chunks and stops the collector" do
      {:ok, collector} = ChunkCollector.start_link()

      ChunkCollector.add_chunk(collector, "chunk1")
      ChunkCollector.add_chunk(collector, "chunk2")

      chunks = ChunkCollector.finish(collector)

      assert length(chunks) == 2
      refute Process.alive?(collector)
    end

    test "works with empty collector" do
      {:ok, collector} = ChunkCollector.start_link()

      chunks = ChunkCollector.finish(collector)

      assert [] = chunks
      refute Process.alive?(collector)
    end
  end

  describe "stop/1" do
    test "stops the collector" do
      {:ok, collector} = ChunkCollector.start_link()

      ChunkCollector.add_chunk(collector, "chunk")
      ChunkCollector.stop(collector)

      refute Process.alive?(collector)
    end

    test "works with named collector" do
      {:ok, _pid} = ChunkCollector.start_link(name: :stop_test)

      ChunkCollector.stop(:stop_test)

      assert Process.whereis(:stop_test) == nil
    end
  end

  describe "concurrent access" do
    test "handles concurrent chunk additions correctly" do
      {:ok, collector} = ChunkCollector.start_link()

      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            ChunkCollector.add_chunk(collector, "chunk_#{i}")
          end)
        end

      Task.await_many(tasks)

      chunks = ChunkCollector.get_chunks(collector)

      assert length(chunks) == 10

      binaries = Enum.map(chunks, & &1.bin) |> Enum.sort()
      expected = for i <- 1..10, do: "chunk_#{i}"

      assert binaries == Enum.sort(expected)

      ChunkCollector.stop(collector)
    end
  end

  describe "timestamps" do
    test "first chunk has timestamp close to 0" do
      {:ok, collector} = ChunkCollector.start_link()

      ChunkCollector.add_chunk(collector, "first")
      chunks = ChunkCollector.get_chunks(collector)

      assert [%{t_us: t}] = chunks
      assert t < 1_000

      ChunkCollector.stop(collector)
    end

    test "timestamps are monotonically increasing" do
      {:ok, collector} = ChunkCollector.start_link()

      ChunkCollector.add_chunk(collector, "1")
      Process.sleep(1)
      ChunkCollector.add_chunk(collector, "2")
      Process.sleep(1)
      ChunkCollector.add_chunk(collector, "3")

      chunks = ChunkCollector.get_chunks(collector)
      timestamps = Enum.map(chunks, & &1.t_us)

      assert timestamps == Enum.sort(timestamps)
      assert Enum.uniq(timestamps) == timestamps

      ChunkCollector.stop(collector)
    end
  end
end
