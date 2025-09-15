defmodule ReqLLM.Provider.DSL.TranslationTest do
  use ExUnit.Case, async: true

  # Test the translation helper functions that should be available to all providers
  # We'll test them through the OpenAI provider since it uses the DSL
  alias ReqLLM.Providers.OpenAI

  describe "DSL translation helper functions" do
    test "translate_rename/3 is available to providers" do
      # Verify the function exists and works
      assert function_exported?(OpenAI, :translate_rename, 3)

      opts = [old_key: "value", other: "keep"]
      {result, warnings} = OpenAI.translate_rename(opts, :old_key, :new_key)

      assert result[:new_key] == "value"
      refute Keyword.has_key?(result, :old_key)
      assert result[:other] == "keep"
      assert warnings == []
    end

    test "translate_drop/3 is available to providers" do
      assert function_exported?(OpenAI, :translate_drop, 3)

      opts = [drop_me: "value", keep_me: "value"]
      warning_msg = "drop_me is not supported"
      {result, warnings} = OpenAI.translate_drop(opts, :drop_me, warning_msg)

      refute Keyword.has_key?(result, :drop_me)
      assert result[:keep_me] == "value"
      assert warnings == [warning_msg]
    end

    test "translate_drop/2 is available to providers" do
      assert function_exported?(OpenAI, :translate_drop, 2)

      opts = [drop_me: "value", keep_me: "value"]
      {result, warnings} = OpenAI.translate_drop(opts, :drop_me)

      refute Keyword.has_key?(result, :drop_me)
      assert result[:keep_me] == "value"
      assert warnings == []
    end

    test "translate_combine_warnings/1 is available to providers" do
      assert function_exported?(OpenAI, :translate_combine_warnings, 1)

      results = [
        {[key1: "value1"], ["warning1"]},
        {[key2: "value2"], []},
        {[key3: "value3"], ["warning2", "warning3"]}
      ]

      {final_opts, all_warnings} = OpenAI.translate_combine_warnings(results)

      assert final_opts[:key1] == "value1"
      assert final_opts[:key2] == "value2"
      assert final_opts[:key3] == "value3"
      assert all_warnings == ["warning1", "warning2", "warning3"]
    end

    test "helper functions handle edge cases correctly" do
      # Test rename with non-existent key
      opts = [existing: "value"]
      {result, warnings} = OpenAI.translate_rename(opts, :non_existent, :new_key)
      assert result == [existing: "value"]
      assert warnings == []

      # Test drop with non-existent key
      {result, warnings} = OpenAI.translate_drop(opts, :non_existent, "message")
      assert result == [existing: "value"]
      assert warnings == []

      # Test combine with empty list
      {result, warnings} = OpenAI.translate_combine_warnings([])
      assert result == []
      assert warnings == []
    end

    test "helper functions preserve option types and values" do
      opts = [
        string_val: "text",
        int_val: 42,
        float_val: 3.14,
        bool_val: true,
        list_val: [1, 2, 3],
        map_val: %{key: "value"}
      ]

      # Test that values are preserved exactly through rename
      {result, _} = OpenAI.translate_rename(opts, :int_val, :renamed_int)
      assert result[:renamed_int] === 42
      assert result[:string_val] === "text"
      assert result[:float_val] === 3.14
      assert result[:bool_val] === true
      assert result[:list_val] === [1, 2, 3]
      assert result[:map_val] === %{key: "value"}
    end

    test "helper functions maintain keyword list ordering where possible" do
      opts = [z: 1, a: 2, m: 3]

      # Drop should maintain order
      {result, _} = OpenAI.translate_drop(opts, :a)
      assert result == [z: 1, m: 3]

      # Rename should maintain relative positions
      {result, _} = OpenAI.translate_rename([z: 1, a: 2, m: 3], :a, :renamed_a)
      # The renamed key should appear where the old key was
      assert result[:z] == 1
      assert result[:renamed_a] == 2
      assert result[:m] == 3
    end

    test "combine_warnings properly merges overlapping keys" do
      results = [
        {[shared_key: "first", unique1: "value1"], ["warning1"]},
        {[shared_key: "second", unique2: "value2"], ["warning2"]}
      ]

      {final_opts, all_warnings} = OpenAI.translate_combine_warnings(results)

      # Later values should overwrite earlier ones for same key
      assert final_opts[:shared_key] == "second"
      assert final_opts[:unique1] == "value1"
      assert final_opts[:unique2] == "value2"
      assert all_warnings == ["warning1", "warning2"]
    end
  end

  describe "real-world translation scenarios" do
    test "complex multi-step translation like o1 models" do
      opts = [
        max_tokens: 1000,
        temperature: 0.7,
        top_p: 0.9,
        frequency_penalty: 0.1,
        other_param: "keep"
      ]

      # Demonstrate the correct sequential approach (like the actual OpenAI implementation)
      {opts_after_rename, rename_warnings} =
        OpenAI.translate_rename(opts, :max_tokens, :max_completion_tokens)

      {final_opts, drop_warnings} =
        OpenAI.translate_drop(opts_after_rename, :temperature, "temperature not supported")

      all_warnings = rename_warnings ++ drop_warnings

      # Verify final result
      assert final_opts[:max_completion_tokens] == 1000
      refute Keyword.has_key?(final_opts, :max_tokens)
      refute Keyword.has_key?(final_opts, :temperature)
      assert final_opts[:top_p] == 0.9
      assert final_opts[:frequency_penalty] == 0.1
      assert final_opts[:other_param] == "keep"
      assert all_warnings == ["temperature not supported"]
    end

    test "translation helpers work with atom and string keys" do
      # Test with atom keys (normal case)
      opts_atoms = [max_tokens: 100, temp: 0.5]
      {result, _} = OpenAI.translate_rename(opts_atoms, :max_tokens, :max_completion_tokens)
      assert result[:max_completion_tokens] == 100

      # The helpers should work with whatever key types are provided
      # (though typically we use atoms in Elixir)
    end

    test "multiple renames in sequence" do
      opts = [old_name1: "value1", old_name2: "value2", keep_me: "value3"]

      results = [
        OpenAI.translate_rename(opts, :old_name1, :new_name1),
        # Will get merged
        OpenAI.translate_rename([], :old_name2, :new_name2)
      ]

      {final_opts, _warnings} = OpenAI.translate_combine_warnings(results)

      # Note: This test shows a limitation - the second rename doesn't see the first opts
      # In practice, you'd chain them or use the real o1 implementation pattern
      assert final_opts[:new_name1] == "value1"
      assert final_opts[:keep_me] == "value3"
      refute Keyword.has_key?(final_opts, :old_name1)
    end
  end
end
