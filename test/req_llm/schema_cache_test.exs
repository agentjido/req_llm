defmodule ReqLLM.SchemaCacheTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ReqLLM.Schema
  alias ReqLLM.Schema.EvictionStrategy

  @cache_table :req_llm_schema_cache
  @config_keys [:schema_cache_max_bytes, :schema_cache_eviction_strategy]

  defmodule NewestFirst do
    @behaviour ReqLLM.Schema.EvictionStrategy

    @impl true
    def select_victim(entries) do
      Enum.max_by(entries, & &1.inserted_at)
    end
  end

  defmodule InvalidEntry do
    @behaviour ReqLLM.Schema.EvictionStrategy

    @impl true
    def select_victim(entries) do
      Map.put(hd(entries), :unknown, true)
    end
  end

  defmodule FailingStrategy do
    @behaviour ReqLLM.Schema.EvictionStrategy

    @impl true
    def select_victim(_entries) do
      raise "failed to select a cache entry"
    end
  end

  setup do
    previous_config = Map.new(@config_keys, &{&1, Application.fetch_env(:req_llm, &1)})

    Application.put_env(:req_llm, :schema_cache_max_bytes, 100 * 1024 * 1024)

    Application.put_env(
      :req_llm,
      :schema_cache_eviction_strategy,
      EvictionStrategy.FIFO
    )

    :ets.delete_all_objects(@cache_table)

    on_exit(fn ->
      :ets.delete_all_objects(@cache_table)
      restore_config(previous_config)
    end)

    :ok
  end

  test "keeps schemas with the same phash2 value separate" do
    first_schema = collision_schema(6089)
    second_schema = collision_schema(22_462)

    assert :erlang.phash2(first_schema) == :erlang.phash2(second_schema)
    assert {:ok, %{"value" => 6089}} = Schema.validate(%{"value" => 6089}, first_schema)
    assert {:ok, %{"value" => 22_462}} = Schema.validate(%{"value" => 22_462}, second_schema)
    assert :ets.info(@cache_table, :size) == 2
  end

  test "updates the last-access sequence on a cache hit" do
    schema = collision_schema(1)

    assert {:ok, _data} = Schema.validate(%{"value" => 1}, schema)
    assert [{^schema, cached_root, inserted_at, first_access}] = :ets.lookup(@cache_table, schema)

    assert {:ok, _data} = Schema.validate(%{"value" => 1}, schema)

    assert [{^schema, ^cached_root, ^inserted_at, second_access}] =
             :ets.lookup(@cache_table, schema)

    assert second_access > first_access
  end

  test "uses FIFO eviction by default" do
    first_schema = collision_schema(1)
    second_schema = collision_schema(2)
    third_schema = collision_schema(3)

    cache_schema(first_schema, 1)
    cache_schema(second_schema, 2)
    cache_schema(first_schema, 1)
    limit_next_insert_to_one_eviction()
    cache_schema(third_schema, 3)

    refute :ets.member(@cache_table, first_schema)
    assert :ets.member(@cache_table, second_schema)
    assert :ets.member(@cache_table, third_schema)
  end

  test "supports least-recently-used eviction" do
    Application.put_env(
      :req_llm,
      :schema_cache_eviction_strategy,
      EvictionStrategy.LRU
    )

    first_schema = collision_schema(1)
    second_schema = collision_schema(2)
    third_schema = collision_schema(3)

    cache_schema(first_schema, 1)
    cache_schema(second_schema, 2)
    cache_schema(first_schema, 1)
    limit_next_insert_to_one_eviction()
    cache_schema(third_schema, 3)

    assert :ets.member(@cache_table, first_schema)
    refute :ets.member(@cache_table, second_schema)
    assert :ets.member(@cache_table, third_schema)
  end

  test "supports a custom eviction strategy" do
    Application.put_env(:req_llm, :schema_cache_eviction_strategy, NewestFirst)

    first_schema = collision_schema(1)
    second_schema = collision_schema(2)
    third_schema = collision_schema(3)

    cache_schema(first_schema, 1)
    cache_schema(second_schema, 2)
    limit_next_insert_to_one_eviction()
    cache_schema(third_schema, 3)

    assert :ets.member(@cache_table, first_schema)
    assert :ets.member(@cache_table, second_schema)
    refute :ets.member(@cache_table, third_schema)
  end

  test "falls back to FIFO when a custom strategy cannot select an entry" do
    Enum.each([InvalidEntry, FailingStrategy], fn strategy ->
      :ets.delete_all_objects(@cache_table)
      Application.put_env(:req_llm, :schema_cache_eviction_strategy, strategy)

      first_schema = collision_schema(1)
      second_schema = collision_schema(2)
      third_schema = collision_schema(3)

      cache_schema(first_schema, 1)
      cache_schema(second_schema, 2)
      limit_next_insert_to_one_eviction()

      log = capture_log(fn -> cache_schema(third_schema, 3) end)

      assert log =~ "using FIFO"
      refute :ets.member(@cache_table, first_schema)
      assert :ets.member(@cache_table, second_schema)
      assert :ets.member(@cache_table, third_schema)
    end)
  end

  test "does not retain an entry that exceeds the memory limit" do
    Application.put_env(
      :req_llm,
      :schema_cache_max_bytes,
      schema_cache_bytes() + 1_024
    )

    schema = large_schema(100)

    assert {:ok, %{}} = Schema.validate(%{}, schema)
    assert :ets.info(@cache_table, :size) == 0
  end

  test "restores the memory limit after concurrent cache misses" do
    Application.put_env(
      :req_llm,
      :schema_cache_max_bytes,
      schema_cache_bytes() + 256 * 1024
    )

    results =
      1..50
      |> Task.async_stream(
        fn value -> Schema.validate(%{}, large_schema(10, value)) end,
        max_concurrency: 10,
        ordered: false,
        timeout: 10_000
      )
      |> Enum.to_list()

    assert Enum.all?(results, &match?({:ok, {:ok, %{}}}, &1))
    assert schema_cache_bytes() <= Application.fetch_env!(:req_llm, :schema_cache_max_bytes)
  end

  defp cache_schema(schema, value) do
    assert {:ok, %{"value" => ^value}} = Schema.validate(%{"value" => value}, schema)
  end

  defp collision_schema(value) do
    %{
      "type" => "object",
      "properties" => %{"value" => %{"const" => value}},
      "required" => ["value"]
    }
  end

  defp large_schema(property_count, suffix \\ nil) do
    properties =
      Map.new(1..property_count, fn property ->
        {"property_#{suffix}_#{property}", %{"type" => "string"}}
      end)

    %{
      "type" => "object",
      "properties" => properties,
      "additionalProperties" => false
    }
  end

  defp limit_next_insert_to_one_eviction do
    Application.put_env(:req_llm, :schema_cache_max_bytes, schema_cache_bytes() + 1)
  end

  defp schema_cache_bytes do
    :ets.info(@cache_table, :memory) * :erlang.system_info(:wordsize)
  end

  defp restore_config(config) do
    Enum.each(config, fn
      {key, {:ok, value}} -> Application.put_env(:req_llm, key, value)
      {key, :error} -> Application.delete_env(:req_llm, key)
    end)
  end
end
