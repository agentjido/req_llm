defmodule ReqLLM.KeyTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Key

  describe "fetch!/2" do
    test "returns api_key from options (highest priority)" do
      opts = [api_key: "option-key"]

      # Set up other potential sources
      System.put_env("ANTHROPIC_API_KEY", "env-key")
      Application.put_env(:req_llm, :anthropic_api_key, "app-key")

      assert Key.fetch!(:anthropic, opts) == "option-key"

      # Cleanup
      System.delete_env("ANTHROPIC_API_KEY")
      Application.delete_env(:req_llm, :anthropic_api_key)
    end

    test "returns key from Application config when no option provided" do
      Application.put_env(:req_llm, :anthropic_api_key, "app-key")
      System.put_env("ANTHROPIC_API_KEY", "env-key")

      assert Key.fetch!(:anthropic, []) == "app-key"

      # Cleanup
      Application.delete_env(:req_llm, :anthropic_api_key)
      System.delete_env("ANTHROPIC_API_KEY")
    end

    test "returns key from System env when no option or config provided" do
      System.put_env("ANTHROPIC_API_KEY", "env-key")

      assert Key.fetch!(:anthropic, []) == "env-key"

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

        assert Key.fetch!(:anthropic, []) == "jido-key"

        # Cleanup - restore original values
        if original_env, do: System.put_env("ANTHROPIC_API_KEY", original_env)
        if original_app, do: Application.put_env(:req_llm, :anthropic_api_key, original_app)
      else
        # Skip test if JidoKeys not available
        assert true
      end
    end

    test "raises error when no key found anywhere" do
      # Use a unique provider to avoid conflicts with existing keys
      provider = :nonexistent_provider
      env_key = "NONEXISTENT_PROVIDER_API_KEY"

      # Ensure no keys are set for this provider
      System.delete_env(env_key)
      Application.delete_env(:req_llm, :nonexistent_provider_api_key)

      assert_raise ReqLLM.Error.Invalid.Parameter, ~r/:api_key option or #{env_key}/, fn ->
        Key.fetch!(provider, [])
      end
    end

    test "raises error when key is empty string" do
      opts = [api_key: ""]

      assert_raise ReqLLM.Error.Invalid.Parameter, fn ->
        Key.fetch!(:anthropic, opts)
      end
    end

    test "handles different provider names correctly" do
      System.put_env("OPENAI_API_KEY", "openai-key")
      System.put_env("ANTHROPIC_API_KEY", "anthropic-key")

      assert Key.fetch!(:openai, []) == "openai-key"
      assert Key.fetch!(:anthropic, []) == "anthropic-key"

      # Cleanup
      System.delete_env("OPENAI_API_KEY")
      System.delete_env("ANTHROPIC_API_KEY")
    end

    test "converts provider atom to correct env var name" do
      # Test the internal logic by setting specific env vars
      System.put_env("CUSTOM_PROVIDER_API_KEY", "custom-key")

      assert Key.fetch!(:custom_provider, []) == "custom-key"

      # Cleanup
      System.delete_env("CUSTOM_PROVIDER_API_KEY")
    end
  end
end
