defmodule ReqLLM.Generation.TranslationTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Generation

  describe "provider translation integration through public API" do
    test "provider with default translate_options/3 callback works normally" do
      # All providers have translate_options/3 now (either custom or default)
      # We can't easily test this without mocking HTTP, so we'll just verify
      # it doesn't crash during the translation phase
      schema =
        ReqLLM.Provider.Options.compose_schema(Generation.schema(), ReqLLM.Providers.Anthropic)

      opts = [max_tokens: 1000, temperature: 0.7]

      # This should validate successfully
      {:ok, validated_opts} = NimbleOptions.validate(opts, schema)
      assert validated_opts[:max_tokens] == 1000
      assert validated_opts[:temperature] == 0.7
    end

    test "provider with translate_options/3 callback has translation available" do
      # OpenAI has translate_options/3, verify the function exists
      provider_mod = ReqLLM.Providers.OpenAI
      assert function_exported?(provider_mod, :translate_options, 3)

      # Test the translation directly
      {:ok, model} = ReqLLM.model("openai:o1-mini")
      opts = [max_tokens: 1000, temperature: 0.7]

      {translated, warnings} = provider_mod.translate_options(:chat, model, opts)

      assert translated[:max_completion_tokens] == 1000
      refute Keyword.has_key?(translated, :max_tokens)
      refute Keyword.has_key?(translated, :temperature)
      assert length(warnings) == 2
      assert Enum.any?(warnings, &(&1 =~ ":temperature"))
      assert Enum.any?(warnings, &(&1 =~ "max_tokens"))
    end
  end

  describe "generation pipeline integration (without HTTP mocking)" do
    test "generation.ex recognizes translate_options/3 callback presence" do
      # All providers now have translate_options/3 (either custom or default implementation)
      openai_provider = ReqLLM.Providers.OpenAI
      groq_provider = ReqLLM.Providers.Groq
      anthropic_provider = ReqLLM.Providers.Anthropic

      assert function_exported?(openai_provider, :translate_options, 3)
      assert function_exported?(groq_provider, :translate_options, 3)
      assert function_exported?(anthropic_provider, :translate_options, 3)
    end
  end

  describe "dynamic_schema/1 includes on_unsupported option" do
    test "base schema includes on_unsupported option" do
      schema = Generation.schema()
      on_unsupported_spec = Keyword.get(schema.schema, :on_unsupported)

      assert on_unsupported_spec != nil
      assert on_unsupported_spec[:type] == {:in, [:warn, :error, :ignore]}
      assert on_unsupported_spec[:default] == :warn
    end

    test "dynamic schema includes on_unsupported option" do
      provider_mod = ReqLLM.Providers.OpenAI
      schema = ReqLLM.Provider.Options.compose_schema(Generation.schema(), provider_mod)
      on_unsupported_spec = Keyword.get(schema.schema, :on_unsupported)

      assert on_unsupported_spec != nil
      assert on_unsupported_spec[:type] == {:in, [:warn, :error, :ignore]}
      assert on_unsupported_spec[:default] == :warn
    end

    test "on_unsupported option validates correctly" do
      provider_mod = ReqLLM.Providers.OpenAI
      schema = ReqLLM.Provider.Options.compose_schema(Generation.schema(), provider_mod)

      # Valid values
      assert {:ok, validated} = NimbleOptions.validate([on_unsupported: :warn], schema)
      assert validated[:on_unsupported] == :warn

      assert {:ok, validated} = NimbleOptions.validate([on_unsupported: :error], schema)
      assert validated[:on_unsupported] == :error

      assert {:ok, validated} = NimbleOptions.validate([on_unsupported: :ignore], schema)
      assert validated[:on_unsupported] == :ignore

      # Invalid value
      assert {:error, _} = NimbleOptions.validate([on_unsupported: :invalid], schema)

      # Default value
      assert {:ok, validated} = NimbleOptions.validate([], schema)
      assert validated[:on_unsupported] == :warn
    end
  end
end
