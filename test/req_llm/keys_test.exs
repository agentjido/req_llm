defmodule ReqLLM.KeysTest do
  use ExUnit.Case, async: false

  alias ReqLLM.Keys

  describe "config_key/1" do
    test "returns correct application config key format for atoms" do
      assert Keys.config_key(:anthropic) == :anthropic_api_key
      assert Keys.config_key(:openai) == :openai_api_key
      assert Keys.config_key(:google) == :google_api_key
    end
  end

  describe "env_var_name/1" do
    test "returns correct environment variable name format for atoms" do
      assert Keys.env_var_name(:anthropic) == "ANTHROPIC_API_KEY"
      assert Keys.env_var_name(:openai) == "OPENAI_API_KEY"
      assert Keys.env_var_name(:google) == "GOOGLE_API_KEY"
    end
  end

  describe "get/2" do
    test "returns {:ok, key, source} with source information" do
      on_exit(fn -> System.delete_env("ANTHROPIC_API_KEY") end)
      System.put_env("ANTHROPIC_API_KEY", "test-key")

      assert {:ok, "test-key", :system} = Keys.get(:anthropic, [])
    end

    test "returns {:error, reason} when no key found" do
      on_exit(fn ->
        System.delete_env("ANTHROPIC_API_KEY")
        Application.delete_env(:req_llm, :anthropic_api_key)
      end)

      System.delete_env("ANTHROPIC_API_KEY")
      Application.delete_env(:req_llm, :anthropic_api_key)

      assert {:error, reason} = Keys.get(:anthropic, [])
      assert reason =~ "ANTHROPIC_API_KEY"
    end

    test "works with ReqLLM.Model structs" do
      on_exit(fn -> System.delete_env("ANTHROPIC_API_KEY") end)
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")
      System.put_env("ANTHROPIC_API_KEY", "test-key")

      assert {:ok, "test-key", :system} = Keys.get(model, [])
    end
  end

  describe "get!/2" do
    test "returns api_key from options (highest priority)" do
      on_exit(fn ->
        System.delete_env("ANTHROPIC_API_KEY")
        Application.delete_env(:req_llm, :anthropic_api_key)
      end)

      opts = [api_key: "option-key"]
      System.put_env("ANTHROPIC_API_KEY", "env-key")
      Application.put_env(:req_llm, :anthropic_api_key, "app-key")

      assert Keys.get!(:anthropic, opts) == "option-key"
    end

    test "returns key from Application config when no option provided" do
      on_exit(fn ->
        System.delete_env("ANTHROPIC_API_KEY")
        Application.delete_env(:req_llm, :anthropic_api_key)
      end)

      Application.put_env(:req_llm, :anthropic_api_key, "app-key")
      System.put_env("ANTHROPIC_API_KEY", "env-key")

      assert Keys.get!(:anthropic, []) == "app-key"
    end

    test "returns key from System env when no option or config provided" do
      on_exit(fn -> System.delete_env("ANTHROPIC_API_KEY") end)
      System.put_env("ANTHROPIC_API_KEY", "env-key")

      assert Keys.get!(:anthropic, []) == "env-key"
    end

    test "raises error when no key found anywhere" do
      on_exit(fn ->
        System.delete_env("ANTHROPIC_API_KEY")
        Application.delete_env(:req_llm, :anthropic_api_key)
      end)

      System.delete_env("ANTHROPIC_API_KEY")
      Application.delete_env(:req_llm, :anthropic_api_key)

      assert_raise ReqLLM.Error.Invalid.Parameter, ~r/ANTHROPIC_API_KEY/, fn ->
        Keys.get!(:anthropic, [])
      end
    end

    test "raises error when key is empty string" do
      opts = [api_key: ""]

      assert_raise ReqLLM.Error.Invalid.Parameter, fn ->
        Keys.get!(:anthropic, opts)
      end
    end

    test "handles different provider names correctly" do
      on_exit(fn ->
        System.delete_env("OPENAI_API_KEY")
        System.delete_env("ANTHROPIC_API_KEY")
      end)

      System.put_env("OPENAI_API_KEY", "openai-key")
      System.put_env("ANTHROPIC_API_KEY", "anthropic-key")

      assert Keys.get!(:openai, []) == "openai-key"
      assert Keys.get!(:anthropic, []) == "anthropic-key"
    end

    test "works with different provider names" do
      on_exit(fn -> System.delete_env("GROQ_API_KEY") end)
      System.put_env("GROQ_API_KEY", "groq-key")

      assert Keys.get!(:groq, []) == "groq-key"
    end
  end
end
