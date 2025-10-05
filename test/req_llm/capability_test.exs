defmodule ReqLLM.CapabilityTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ReqLLM.Capability

  setup_all do
    Application.ensure_all_started(:req_llm)
    :ok
  end

  describe "capabilities/1" do
    test "returns capabilities for valid model spec" do
      capabilities = Capability.capabilities("anthropic:claude-3-haiku-20240307")

      assert is_list(capabilities)
      # Basic capabilities should always be present
      assert :max_tokens in capabilities
      assert :system_prompt in capabilities
      assert :metadata in capabilities
    end

    test "works with Model struct" do
      model = %ReqLLM.Model{provider: :anthropic, model: "claude-3-haiku-20240307"}
      capabilities = Capability.capabilities(model)

      assert is_list(capabilities)
      assert :max_tokens in capabilities
    end

    test "returns empty list for invalid model spec" do
      assert Capability.capabilities("invalidprovider:model") == []
      assert Capability.capabilities("not-a-spec") == []
      assert Capability.capabilities("unknownprovider:model") == []
    end
  end

  describe "supports?/2" do
    test "checks if model supports a capability" do
      assert Capability.supports?("anthropic:claude-3-haiku-20240307", :max_tokens)
      assert Capability.supports?("anthropic:claude-3-haiku-20240307", :system_prompt)
      assert Capability.supports?("anthropic:claude-3-haiku-20240307", :metadata)

      refute Capability.supports?("anthropic:claude-3-haiku-20240307", :unknown_capability)
    end

    test "works with Model struct" do
      model = %ReqLLM.Model{provider: :anthropic, model: "claude-3-haiku-20240307"}
      assert Capability.supports?(model, :max_tokens)
    end

    test "returns false for invalid models" do
      refute Capability.supports?("invalid:model", :tools)
    end
  end

  describe "models_for/2" do
    test "finds models supporting basic capabilities" do
      models = Capability.models_for(:anthropic, :max_tokens)
      assert is_list(models)

      if not Enum.empty?(models) do
        for model <- models do
          assert String.contains?(model, "anthropic:")
          assert Capability.supports?(model, :max_tokens)
        end
      end
    end

    test "handles unknown capabilities" do
      models = Capability.models_for(:anthropic, :unknown_capability)
      assert models == []
    end

    test "handles unknown providers" do
      models = Capability.models_for(:unknown_provider, :tools)
      assert models == []
    end
  end

  describe "provider_models/1" do
    test "returns model specs for valid provider" do
      models = Capability.provider_models(:anthropic)
      assert is_list(models)

      if not Enum.empty?(models) do
        first_model = hd(models)
        assert String.contains?(first_model, "anthropic:")
        assert String.split(first_model, ":", parts: 2) |> length() == 2
      end
    end

    test "returns empty list for unknown provider" do
      assert Capability.provider_models(:unknown_provider) == []
    end
  end

  describe "providers_for/1" do
    test "finds providers supporting basic capabilities" do
      providers = Capability.providers_for(:max_tokens)
      assert is_list(providers)

      for provider <- providers do
        provider_models = Capability.models_for(provider, :max_tokens)
        refute Enum.empty?(provider_models)
      end
    end

    test "handles unknown capabilities" do
      providers = Capability.providers_for(:unknown_capability)
      assert providers == []
    end
  end

  describe "validate!/2" do
    test "passes validation when model supports all required capabilities" do
      model = "anthropic:claude-3-haiku-20240307"

      assert :ok = Capability.validate!(model, temperature: 0.7, max_tokens: 100)
      assert :ok = Capability.validate!(model, [])
    end

    test "ignores unsupported capabilities by default" do
      model = "anthropic:claude-3-haiku-20240307"

      # Assuming the model doesn't support reasoning
      assert :ok = Capability.validate!(model, reasoning: true)
    end

    test "logs warning for unsupported capabilities when configured" do
      model = "anthropic:claude-3-haiku-20240307"

      log =
        capture_log(fn ->
          assert :ok = Capability.validate!(model, reasoning: true, on_unsupported: :warn)
        end)

      assert log =~ "does not support"
    end

    test "raises error for unsupported capabilities when configured" do
      model = "anthropic:claude-3-haiku-20240307"

      assert_raise ReqLLM.Error.Invalid.Capability, fn ->
        Capability.validate!(model, reasoning: true, on_unsupported: :error)
      end
    end

    test "works with Model struct" do
      model = %ReqLLM.Model{provider: :anthropic, model: "claude-3-haiku-20240307"}

      assert :ok = Capability.validate!(model, temperature: 0.7)
    end

    test "handles multiple unsupported capabilities" do
      model = "anthropic:claude-3-haiku-20240307"

      assert_raise ReqLLM.Error.Invalid.Capability, ~r/reasoning/, fn ->
        Capability.validate!(model,
          reasoning: true,
          # Another capability that might not be supported
          top_k: 0.5,
          on_unsupported: :error
        )
      end
    end

    test "extracts capabilities from various option types" do
      model = "anthropic:claude-3-haiku-20240307"

      # These should all pass since they're basic capabilities
      assert :ok =
               Capability.validate!(model,
                 temperature: 0.7,
                 top_p: 0.9,
                 tools: [],
                 stop_sequences: ["END"]
               )
    end

    test "handles streaming flag correctly" do
      model = "anthropic:claude-3-haiku-20240307"

      # Stream flag should map to streaming capability
      assert :ok = Capability.validate!(model, stream: true)
      # Should not require capability
      assert :ok = Capability.validate!(model, stream: false)
    end
  end
end
