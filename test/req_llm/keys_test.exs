defmodule ReqLLM.KeysTest do
  use ExUnit.Case, async: true

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
      System.put_env("ANTHROPIC_API_KEY", "test-key")

      assert {:ok, "test-key", :system} = Keys.get(:anthropic, [])

      System.delete_env("ANTHROPIC_API_KEY")
    end

    test "returns {:error, reason} when no key found" do
      # Clear all potential sources
      System.delete_env("ANTHROPIC_API_KEY")
      Application.delete_env(:req_llm, :anthropic_api_key)
      if Code.ensure_loaded?(JidoKeys), do: JidoKeys.put("ANTHROPIC_API_KEY", "")

      assert {:error, reason} = Keys.get(:anthropic, [])
      assert reason =~ "ANTHROPIC_API_KEY"
    end

    test "works with ReqLLM.Model structs" do
      model = %ReqLLM.Model{provider: :anthropic, model: "claude-3-sonnet"}
      System.put_env("ANTHROPIC_API_KEY", "test-key")

      assert {:ok, "test-key", :system} = Keys.get(model, [])

      System.delete_env("ANTHROPIC_API_KEY")
    end
  end

  describe "get!/2" do
    test "returns api_key from options (highest priority)" do
      opts = [api_key: "option-key"]

      # Set up other potential sources
      System.put_env("ANTHROPIC_API_KEY", "env-key")
      Application.put_env(:req_llm, :anthropic_api_key, "app-key")

      assert Keys.get!(:anthropic, opts) == "option-key"

      # Cleanup
      System.delete_env("ANTHROPIC_API_KEY")
      Application.delete_env(:req_llm, :anthropic_api_key)
    end

    test "returns key from Application config when no option provided" do
      Application.put_env(:req_llm, :anthropic_api_key, "app-key")
      System.put_env("ANTHROPIC_API_KEY", "env-key")

      assert Keys.get!(:anthropic, []) == "app-key"

      # Cleanup
      Application.delete_env(:req_llm, :anthropic_api_key)
      System.delete_env("ANTHROPIC_API_KEY")
    end

    test "returns key from System env when no option or config provided" do
      System.put_env("ANTHROPIC_API_KEY", "env-key")

      assert Keys.get!(:anthropic, []) == "env-key"

      # Cleanup
      System.delete_env("ANTHROPIC_API_KEY")
    end

    test "falls back to JidoKeys when available" do
      # Mock JidoKeys being loaded and returning a value
      # This test assumes JidoKeys is available in the test environment
      if Code.ensure_loaded?(JidoKeys) do
        # Store original env value
        original_env = System.get_env("ANTHROPIC_API_KEY")
        original_app = Application.get_env(:req_llm, :anthropic_api_key)

        # Clear other sources
        System.delete_env("ANTHROPIC_API_KEY")
        Application.delete_env(:req_llm, :anthropic_api_key)

        JidoKeys.put("ANTHROPIC_API_KEY", "jido-key")

        assert Keys.get!(:anthropic, []) == "jido-key"

        # Cleanup - restore original values
        if original_env, do: System.put_env("ANTHROPIC_API_KEY", original_env)
        if original_app, do: Application.put_env(:req_llm, :anthropic_api_key, original_app)
      else
        # Skip test if JidoKeys not available
        assert true
      end
    end

    test "raises error when no key found anywhere" do
      # Use anthropic but clear all potential sources
      System.delete_env("ANTHROPIC_API_KEY")
      Application.delete_env(:req_llm, :anthropic_api_key)
      if Code.ensure_loaded?(JidoKeys), do: JidoKeys.put("ANTHROPIC_API_KEY", "")

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
      System.put_env("OPENAI_API_KEY", "openai-key")
      System.put_env("ANTHROPIC_API_KEY", "anthropic-key")

      assert Keys.get!(:openai, []) == "openai-key"
      assert Keys.get!(:anthropic, []) == "anthropic-key"

      # Cleanup
      System.delete_env("OPENAI_API_KEY")
      System.delete_env("ANTHROPIC_API_KEY")
    end

    test "works with different provider names" do
      # Test with groq provider
      System.put_env("GROQ_API_KEY", "groq-key")

      assert Keys.get!(:groq, []) == "groq-key"

      # Cleanup
      System.delete_env("GROQ_API_KEY")
    end
  end
end
