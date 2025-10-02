defmodule ReqLLM.Test.EnvTest do
  use ExUnit.Case, async: false

  alias ReqLLM.Test.Env

  setup do
    original = %{
      fixtures_mode: System.get_env("REQ_LLM_FIXTURES_MODE"),
      timeout: System.get_env("REQ_LLM_TIMEOUT"),
      models: System.get_env("REQ_LLM_MODELS"),
      sample: System.get_env("REQ_LLM_SAMPLE"),
      exclude: System.get_env("REQ_LLM_EXCLUDE")
    }

    on_exit(fn ->
      set_or_delete("REQ_LLM_FIXTURES_MODE", original.fixtures_mode)
      set_or_delete("REQ_LLM_TIMEOUT", original.timeout)
      set_or_delete("REQ_LLM_MODELS", original.models)
      set_or_delete("REQ_LLM_SAMPLE", original.sample)
      set_or_delete("REQ_LLM_EXCLUDE", original.exclude)
    end)

    {:ok, original: original}
  end

  describe "fixtures_mode/0" do
    test "returns :record when REQ_LLM_FIXTURES_MODE=record" do
      System.put_env("REQ_LLM_FIXTURES_MODE", "record")
      assert :record = Env.fixtures_mode()
    end

    test "returns :replay when REQ_LLM_FIXTURES_MODE=replay" do
      System.put_env("REQ_LLM_FIXTURES_MODE", "replay")
      assert :replay = Env.fixtures_mode()
    end

    test "defaults to :replay when no env var set" do
      System.delete_env("REQ_LLM_FIXTURES_MODE")
      assert :replay = Env.fixtures_mode()
    end

    test "raises on invalid value" do
      System.put_env("REQ_LLM_FIXTURES_MODE", "invalid")

      assert_raise ArgumentError, ~r/Invalid REQ_LLM_FIXTURES_MODE/, fn ->
        Env.fixtures_mode()
      end

      System.delete_env("REQ_LLM_FIXTURES_MODE")
    end
  end

  describe "timeout/0" do
    test "returns default timeout when not set" do
      System.delete_env("REQ_LLM_TIMEOUT")
      assert 30_000 = Env.timeout()
    end

    test "returns custom timeout when set" do
      System.put_env("REQ_LLM_TIMEOUT", "60000")
      assert 60_000 = Env.timeout()
    end

    test "raises on invalid timeout" do
      System.put_env("REQ_LLM_TIMEOUT", "not_a_number")

      assert_raise ArgumentError, ~r/Invalid REQ_LLM_TIMEOUT/, fn ->
        Env.timeout()
      end

      System.delete_env("REQ_LLM_TIMEOUT")
    end

    test "raises on negative timeout" do
      System.put_env("REQ_LLM_TIMEOUT", "-1000")

      assert_raise ArgumentError, ~r/Invalid REQ_LLM_TIMEOUT/, fn ->
        Env.timeout()
      end

      System.delete_env("REQ_LLM_TIMEOUT")
    end

    test "raises on zero timeout" do
      System.put_env("REQ_LLM_TIMEOUT", "0")

      assert_raise ArgumentError, ~r/Invalid REQ_LLM_TIMEOUT/, fn ->
        Env.timeout()
      end

      System.delete_env("REQ_LLM_TIMEOUT")
    end
  end

  describe "config/0" do
    test "returns complete configuration map" do
      System.put_env("REQ_LLM_FIXTURES_MODE", "record")
      System.put_env("REQ_LLM_TIMEOUT", "45000")
      System.put_env("REQ_LLM_MODELS", "anthropic:*")
      System.put_env("REQ_LLM_SAMPLE", "5")
      System.put_env("REQ_LLM_EXCLUDE", "openai:gpt-3.5-turbo")

      config = Env.config()

      assert config.fixtures_mode == :record
      assert config.timeout == 45_000
      assert config.models == "anthropic:*"
      assert config.sample == "5"
      assert config.exclude == "openai:gpt-3.5-turbo"
    end

    test "handles missing optional variables" do
      System.delete_env("REQ_LLM_FIXTURES_MODE")
      System.delete_env("REQ_LLM_TIMEOUT")
      System.delete_env("REQ_LLM_MODELS")
      System.delete_env("REQ_LLM_SAMPLE")
      System.delete_env("REQ_LLM_EXCLUDE")

      config = Env.config()

      assert config.fixtures_mode == :replay
      assert config.timeout == 30_000
      assert config.models == nil
      assert config.sample == nil
      assert config.exclude == nil
    end
  end

  defp set_or_delete(_var, nil), do: :ok

  defp set_or_delete(var, value) do
    System.put_env(var, value)
  end
end
