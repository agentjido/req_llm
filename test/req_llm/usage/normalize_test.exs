defmodule ReqLLM.Usage.NormalizeTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Usage.Normalize

  describe "input_includes_cached" do
    test "honors an explicit false flag and does not clamp cached tokens" do
      usage = %{
        input_tokens: 12,
        output_tokens: 5,
        cached_tokens: 4000,
        cache_creation_tokens: 900,
        input_includes_cached: false
      }

      normalized = Normalize.normalize(usage)

      assert normalized.input_includes_cached == false
      assert normalized.cache_read_tokens == 4000
      assert normalized.cache_write_tokens == 900
      assert normalized.cached_tokens == 4000
      assert normalized.cache_creation_tokens == 900
    end

    test "survives a second normalization" do
      usage = %{
        input_tokens: 12,
        output_tokens: 5,
        cached_tokens: 4000,
        input_includes_cached: false
      }

      twice = usage |> Normalize.normalize() |> Normalize.normalize()

      assert twice.cache_read_tokens == 4000
      assert twice.cached_tokens == 4000
    end

    test "normalizes explicit cache read and write counters" do
      normalized =
        Normalize.normalize(%{
          input_tokens: 12,
          output_tokens: 5,
          cache_read_tokens: 4000,
          cache_write_tokens: 900,
          input_includes_cached: false
        })

      assert normalized.cache_read_tokens == 4000
      assert normalized.cache_write_tokens == 900
      assert normalized.cached_tokens == 4000
      assert normalized.cache_creation_tokens == 900
    end

    test "honors an explicit true flag" do
      usage = %{
        input_tokens: 5000,
        output_tokens: 5,
        cached_tokens: 4000,
        input_includes_cached: true
      }

      assert Normalize.normalize(usage).input_includes_cached == true
    end

    test "keeps the format heuristic when the flag is absent" do
      canonical_only = %{input_tokens: 12, output_tokens: 5, cached_tokens: 4000}
      assert Normalize.normalize(canonical_only).input_includes_cached == true

      anthropic = %{"input_tokens" => 12, "output_tokens" => 5, "cache_read_input_tokens" => 4000}
      assert Normalize.normalize(anthropic).input_includes_cached == false
    end
  end
end
