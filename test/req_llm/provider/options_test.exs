defmodule ReqLLM.Provider.OptionsTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Provider.Options

  doctest ReqLLM.Provider.Options

  # Test helper for schema validation patterns
  defp assert_schema_has_keys(schema, expected_keys) do
    assert %NimbleOptions{} = schema

    for key <- expected_keys do
      assert Keyword.has_key?(schema.schema, key), "Expected schema to have key #{key}"
    end
  end

  # Test helper for validation success cases
  defp assert_validates_successfully(validation_fn, opts, expected_keys \\ []) do
    assert {:ok, validated} = validation_fn.(opts)

    for {key, expected_value} <- expected_keys do
      assert validated[key] == expected_value,
             "Expected #{key} to be #{inspect(expected_value)}, got #{inspect(validated[key])}"
    end

    validated
  end

  # Test helper for validation error cases
  defp assert_validation_error(validation_fn, opts) do
    assert {:error, %NimbleOptions.ValidationError{}} = validation_fn.(opts)
  end

  describe "schema accessor functions" do
    test "all schema accessors return proper NimbleOptions with expected keys" do
      schema_tests = [
        {&Options.provider_options_schema/0, [:id, :base_url]},
        {&Options.model_capabilities_schema/0, [:id, :reasoning, :tool_call]},
        {&Options.model_limits_schema/0, [:context, :output]},
        {&Options.model_cost_schema/0, [:input, :output]},
        {&Options.generation_options_schema/0, [:temperature, :max_tokens]},
        {&Options.complete_options_schema/0, [:provider, :capabilities, :generation]}
      ]

      for {schema_fn, expected_keys} <- schema_tests do
        assert_schema_has_keys(schema_fn.(), expected_keys)
      end
    end

    test "schema aliases return correct references" do
      assert Options.generation_schema() == Options.generation_options_schema()
      assert Options.provider_schema_base() == Options.provider_options_schema()
    end
  end

  describe "validation functions" do
    test "successful validations with defaults applied" do
      validation_cases = [
        {
          &Options.validate_provider_options/1,
          [id: :openai, base_url: "https://api.openai.com/v1"],
          [id: :openai, retry_attempts: 3, retry_delay: 1000]
        },
        {
          &Options.validate_generation_options/1,
          [temperature: 0.7, max_tokens: 1000],
          [temperature: 0.7, max_tokens: 1000, n: 1, stream: false]
        },
        {
          &Options.validate_capabilities/1,
          [id: "gpt-4", reasoning: true],
          [id: "gpt-4", reasoning: true, attachment: false, temperature: true]
        },
        {
          &Options.validate_limits/1,
          [context: 128_000, output: 4096],
          [context: 128_000, output: 4096]
        },
        {
          &Options.validate_cost/1,
          [input: 3.0, output: 15.0],
          [input: 3.0, output: 15.0]
        }
      ]

      for {validation_fn, valid_opts, expected_pairs} <- validation_cases do
        assert_validates_successfully(validation_fn, valid_opts, expected_pairs)
      end
    end

    test "validation failures for invalid inputs" do
      error_cases = [
        # missing required :id
        {&Options.validate_provider_options/1, [base_url: "https://api.openai.com/v1"]},
        # wrong type
        {&Options.validate_generation_options/1, [temperature: "invalid"]},
        # invalid enum
        {&Options.validate_capabilities/1, [id: "gpt-4", modalities: %{input: [:invalid]}]},
        # negative integer
        {&Options.validate_limits/1, [context: -100]},
        # wrong type
        {&Options.validate_cost/1, [input: "free"]}
      ]

      for {validation_fn, invalid_opts} <- error_cases do
        assert_validation_error(validation_fn, invalid_opts)
      end
    end
  end

  describe "key listing functions" do
    test "all key functions return lists containing expected keys" do
      key_tests = [
        {&Options.all_provider_keys/0, [:id, :base_url, :api_key, :timeout]},
        {&Options.all_generation_keys/0, [:temperature, :max_tokens, :stream, :tools]},
        {&Options.all_capability_keys/0, [:id, :reasoning, :tool_call, :modalities]},
        {&Options.all_limit_keys/0, [:context, :output, :rate_limit]},
        {&Options.all_cost_keys/0, [:input, :output, :cache_read, :training]}
      ]

      for {key_fn, expected_keys} <- key_tests do
        keys = key_fn.()
        assert is_list(keys)

        for expected_key <- expected_keys do
          assert expected_key in keys, "Expected #{expected_key} in #{inspect(keys)}"
        end
      end
    end
  end

  describe "extract_provider_options/1" do
    test "separates standard and custom options correctly" do
      opts = [
        temperature: 0.7,
        max_tokens: 100,
        custom_param: "value",
        another_custom: 42
      ]

      {standard, custom} = Options.extract_provider_options(opts)

      # Standard options should be included
      assert standard[:temperature] == 0.7
      assert standard[:max_tokens] == 100
      refute Keyword.has_key?(standard, :custom_param)

      # Custom options should be separated
      assert custom[:custom_param] == "value"
      assert custom[:another_custom] == 42
      refute Keyword.has_key?(custom, :temperature)
    end

    test "edge cases and special handling" do
      test_cases = [
        # stream? alias handling
        {
          [stream?: true, temperature: 0.5],
          fn {standard, custom} ->
            assert standard[:stream] == true
            assert standard[:temperature] == 0.5
            refute Keyword.has_key?(standard, :stream?)
            assert custom == []
          end
        },
        # provider_options exclusion
        {
          [temperature: 0.7, provider_options: %{custom: "value"}],
          fn {standard, custom} ->
            assert standard[:temperature] == 0.7
            refute Keyword.has_key?(standard, :provider_options)
            assert custom[:provider_options] == %{custom: "value"}
          end
        },
        # empty options
        {
          [],
          fn {standard, custom} ->
            assert standard == []
            assert custom == []
          end
        }
      ]

      for {input_opts, assertion_fn} <- test_cases do
        result = Options.extract_provider_options(input_opts)
        assertion_fn.(result)
      end
    end
  end

  describe "extract_generation_opts/1" do
    test "extracts only generation options from mixed input" do
      mixed_opts = [
        temperature: 0.7,
        custom_param: "value",
        max_tokens: 100,
        another_custom: 42
      ]

      generation_opts = Options.extract_generation_opts(mixed_opts)

      assert generation_opts[:temperature] == 0.7
      assert generation_opts[:max_tokens] == 100
      refute Keyword.has_key?(generation_opts, :custom_param)
      refute Keyword.has_key?(generation_opts, :another_custom)
    end
  end

  describe "utility functions" do
    test "merge_with_defaults/2 handles precedence correctly" do
      defaults = [temperature: 0.7, max_tokens: 1000, stream: false]
      user_opts = [temperature: 0.9, top_p: 0.8]

      merged = Options.merge_with_defaults(user_opts, defaults)

      # user override
      assert merged[:temperature] == 0.9
      # from defaults
      assert merged[:max_tokens] == 1000
      # from defaults  
      assert merged[:stream] == false
      # user addition
      assert merged[:top_p] == 0.8

      # Edge cases
      assert Options.merge_with_defaults([], defaults) == defaults
      assert Options.merge_with_defaults(user_opts, []) == user_opts
    end

    test "generation_subset_schema/1 creates filtered schemas" do
      keys = [:temperature, :max_tokens]
      schema = Options.generation_subset_schema(keys)

      assert %NimbleOptions{} = schema
      assert Keyword.has_key?(schema.schema, :temperature)
      assert Keyword.has_key?(schema.schema, :max_tokens)
      refute Keyword.has_key?(schema.schema, :top_p)

      # Should validate successfully
      assert {:ok, validated} = NimbleOptions.validate([temperature: 0.7], schema)
      assert validated[:temperature] == 0.7

      # Handle edge cases
      empty_schema = Options.generation_subset_schema([])
      assert %NimbleOptions{} = empty_schema
      assert empty_schema.schema == []

      # Handle unknown keys gracefully
      mixed_schema = Options.generation_subset_schema([:temperature, :unknown_key])
      assert Keyword.has_key?(mixed_schema.schema, :temperature)
      refute Keyword.has_key?(mixed_schema.schema, :unknown_key)
    end

    test "validate_generation_options/2 with only: option" do
      opts = [temperature: 0.7, max_tokens: 100]
      keys = [:temperature, :max_tokens]

      assert {:ok, validated} = Options.validate_generation_options(opts, only: keys)
      assert validated[:temperature] == 0.7
      assert validated[:max_tokens] == 100

      # Should fail for unsupported keys
      assert_validation_error(
        fn opts -> Options.validate_generation_options(opts, only: [:temperature]) end,
        temperature: 0.7,
        top_p: 0.9
      )

      # Empty options should work
      assert {:ok, []} = Options.validate_generation_options([], only: keys)
    end

    test "filter_generation_options/2 and filter_for_provider/2" do
      opts = [
        temperature: 0.7,
        unsupported_key: "value",
        max_tokens: 100,
        another_unsupported: 42
      ]

      keys = [:temperature, :max_tokens]
      filtered = Options.filter_generation_options(opts, keys)

      assert filtered[:temperature] == 0.7
      assert filtered[:max_tokens] == 100
      refute Keyword.has_key?(filtered, :unsupported_key)

      # Edge cases
      assert Options.filter_generation_options([], keys) == []
      assert Options.filter_generation_options(opts, []) == []

      # filter_for_provider should work the same for any provider
      provider_filtered = Options.filter_for_provider(opts, :openai)
      assert provider_filtered[:temperature] == 0.7
      assert provider_filtered[:max_tokens] == 100
      refute Keyword.has_key?(provider_filtered, :unsupported_key)
    end
  end

  describe "complex validation scenarios" do
    test "comprehensive generation options validation" do
      complex_opts = [
        temperature: 0.7,
        max_tokens: 1000,
        tools: [%{type: "function", function: %{name: "get_weather"}}],
        tool_choice: "auto",
        reasoning: "auto",
        thinking: true,
        stream: true,
        stream_format: :sse,
        safety_settings: [%{category: "HARM_CATEGORY_HARASSMENT"}]
      ]

      validated =
        assert_validates_successfully(
          &Options.validate_generation_options/1,
          complex_opts,
          temperature: 0.7,
          reasoning: "auto",
          stream: true
        )

      assert length(validated[:tools]) == 1
    end

    test "comprehensive provider options validation" do
      complex_provider_opts = [
        id: :custom_provider,
        name: "Custom Provider",
        base_url: "https://api.custom.com/v1",
        env: ["CUSTOM_API_KEY", "CUSTOM_ORG_KEY"],
        timeout: 45_000,
        retry_attempts: 5
      ]

      assert_validates_successfully(
        &Options.validate_provider_options/1,
        complex_provider_opts,
        id: :custom_provider,
        timeout: 45_000
      )
    end

    test "complex model capabilities with modalities" do
      complex_capabilities = [
        id: "multimodal-model",
        modalities: %{
          input: [:text, :image, :audio, :video],
          output: [:text, :image, :audio]
        },
        reasoning: true,
        tool_call: true,
        knowledge: "2024-04"
      ]

      validated =
        assert_validates_successfully(
          &Options.validate_capabilities/1,
          complex_capabilities,
          reasoning: true,
          tool_call: true
        )

      assert validated[:modalities][:input] == [:text, :image, :audio, :video]
    end
  end

  describe "edge cases and enum validations" do
    test "reasoning parameter validation in generation vs capabilities" do
      # Generation schema allows specific enum values
      valid_reasoning_values = [nil, false, true, "low", "auto", "high"]

      for value <- valid_reasoning_values do
        assert {:ok, _} = Options.validate_generation_options(reasoning: value)
      end

      assert_validation_error(&Options.validate_generation_options/1, reasoning: "invalid")

      # Capabilities schema only allows booleans
      for value <- [true, false] do
        assert {:ok, _} = Options.validate_capabilities(id: "test", reasoning: value)
      end

      assert_validation_error(&Options.validate_capabilities/1, id: "test", reasoning: "auto")
    end

    test "stop sequences multiple format support" do
      stop_test_cases = [
        {[stop: "END"], "END"},
        {[stop: ["\\n", "END", "STOP"]], ["\\n", "END", "STOP"]},
        {[stop_sequences: ["\\n", "END"]], ["\\n", "END"]}
      ]

      for {opts, expected} <- stop_test_cases do
        validated = assert_validates_successfully(&Options.validate_generation_options/1, opts)
        key = if Keyword.has_key?(opts, :stop), do: :stop, else: :stop_sequences
        assert validated[key] == expected
      end
    end

    test "enum validations for stream_format and logprobs" do
      # stream_format enum
      for format <- [:sse, :chunked, :json, :text] do
        assert {:ok, validated} = Options.validate_generation_options(stream_format: format)
        assert validated[:stream_format] == format
      end

      assert_validation_error(&Options.validate_generation_options/1, stream_format: :invalid)

      # logprobs as boolean or positive integer
      logprobs_cases = [
        {[logprobs: true], true},
        {[logprobs: false], false},
        {[logprobs: 5], 5}
      ]

      for {opts, expected} <- logprobs_cases do
        validated = assert_validates_successfully(&Options.validate_generation_options/1, opts)
        assert validated[:logprobs] == expected
      end

      # Invalid logprobs values
      for invalid_value <- [0, -1] do
        assert_validation_error(&Options.validate_generation_options/1, logprobs: invalid_value)
      end
    end

    test "empty options handling" do
      # Generation options should succeed with defaults
      assert {:ok, result} = Options.validate_generation_options([])
      # default
      assert result[:stream] == false
      # default
      assert result[:n] == 1

      # Capabilities require id
      assert_validation_error(&Options.validate_capabilities/1, [])
    end
  end
end
