defmodule ReqLLM.Providers.OpenAITest do
  use ExUnit.Case, async: true

  alias ReqLLM.{Model, Providers.OpenAI}

  describe "translate_options/3" do
    test "o1 models translate max_tokens to max_completion_tokens" do
      opts = [max_tokens: 1000, temperature: 0.7]
      model = Model.new(:openai, "o1-mini")

      {translated, warnings} = OpenAI.translate_options(:chat, model, opts)

      assert translated[:max_completion_tokens] == 1000
      refute Keyword.has_key?(translated, :max_tokens)
      refute Keyword.has_key?(translated, :temperature)
      assert length(warnings) == 1
      assert List.first(warnings) =~ "OpenAI o1 models do not support :temperature"
    end

    test "o1-preview models translate max_tokens to max_completion_tokens" do
      opts = [max_tokens: 2000, temperature: 1.0]
      model = Model.new(:openai, "o1-preview")

      {translated, warnings} = OpenAI.translate_options(:chat, model, opts)

      assert translated[:max_completion_tokens] == 2000
      refute Keyword.has_key?(translated, :max_tokens)
      refute Keyword.has_key?(translated, :temperature)
      assert length(warnings) == 1
      assert List.first(warnings) =~ "OpenAI o1 models do not support :temperature"
    end

    test "o1 models handle missing max_tokens gracefully" do
      opts = [temperature: 0.5, top_p: 0.9]
      model = Model.new(:openai, "o1-mini")

      {translated, warnings} = OpenAI.translate_options(:chat, model, opts)

      refute Keyword.has_key?(translated, :max_tokens)
      refute Keyword.has_key?(translated, :max_completion_tokens)
      refute Keyword.has_key?(translated, :temperature)
      assert translated[:top_p] == 0.9
      assert length(warnings) == 1
      assert List.first(warnings) =~ "OpenAI o1 models do not support :temperature"
    end

    test "o1 models handle missing temperature gracefully" do
      opts = [max_tokens: 500, top_p: 0.8]
      model = Model.new(:openai, "o1-mini")

      {translated, warnings} = OpenAI.translate_options(:chat, model, opts)

      assert translated[:max_completion_tokens] == 500
      refute Keyword.has_key?(translated, :max_tokens)
      assert translated[:top_p] == 0.8
      assert warnings == []
    end

    test "o1 models preserve other options" do
      opts = [max_tokens: 1500, top_p: 0.95, frequency_penalty: 0.1, presence_penalty: 0.2]
      model = Model.new(:openai, "o1-mini")

      {translated, warnings} = OpenAI.translate_options(:chat, model, opts)

      assert translated[:max_completion_tokens] == 1500
      assert translated[:top_p] == 0.95
      assert translated[:frequency_penalty] == 0.1
      assert translated[:presence_penalty] == 0.2
      # No temperature in opts, so no warnings
      assert warnings == []
    end

    test "non-o1 models are unchanged for chat operation" do
      opts = [max_tokens: 1000, temperature: 0.7, top_p: 0.9]
      model = Model.new(:openai, "gpt-4o")

      {translated, warnings} = OpenAI.translate_options(:chat, model, opts)

      assert translated == opts
      assert warnings == []
    end

    test "gpt-3.5-turbo models are unchanged" do
      opts = [max_tokens: 1000, temperature: 0.7]
      model = Model.new(:openai, "gpt-3.5-turbo")

      {translated, warnings} = OpenAI.translate_options(:chat, model, opts)

      assert translated == opts
      assert warnings == []
    end

    test "gpt-4 models are unchanged" do
      opts = [max_tokens: 2000, temperature: 1.2, top_p: 0.8]
      model = Model.new(:openai, "gpt-4")

      {translated, warnings} = OpenAI.translate_options(:chat, model, opts)

      assert translated == opts
      assert warnings == []
    end

    test "non-chat operations are unchanged for o1 models" do
      opts = [max_tokens: 1000, temperature: 0.7]
      model = Model.new(:openai, "o1-mini")

      {translated, warnings} = OpenAI.translate_options(:embedding, model, opts)

      assert translated == opts
      assert warnings == []
    end

    test "non-chat operations are unchanged for regular models" do
      opts = [max_tokens: 1000, temperature: 0.7]
      model = Model.new(:openai, "gpt-4o")

      {translated, warnings} = OpenAI.translate_options(:embedding, model, opts)

      assert translated == opts
      assert warnings == []
    end

    test "empty options are handled correctly for o1 models" do
      opts = []
      model = Model.new(:openai, "o1-preview")

      {translated, warnings} = OpenAI.translate_options(:chat, model, opts)

      assert translated == []
      # No options to translate, no warnings
      assert warnings == []
    end

    test "o1 model name matching is case sensitive and prefix-based" do
      # Should match (starts with "o1")
      o1_models = ["o1-mini", "o1-preview", "o1-anything"]

      for model_name <- o1_models do
        opts = [max_tokens: 1000, temperature: 0.7]
        model = Model.new(:openai, model_name)

        {translated, warnings} = OpenAI.translate_options(:chat, model, opts)

        assert translated[:max_completion_tokens] == 1000
        refute Keyword.has_key?(translated, :max_tokens)
        refute Keyword.has_key?(translated, :temperature)
        assert length(warnings) == 1
      end

      # Should not match (doesn't start with "o1")
      non_o1_models = ["O1-mini", "gpt-o1", "model-o1-test"]

      for model_name <- non_o1_models do
        opts = [max_tokens: 1000, temperature: 0.7]
        model = Model.new(:openai, model_name)

        {translated, warnings} = OpenAI.translate_options(:chat, model, opts)

        assert translated == opts
        assert warnings == []
      end
    end
  end

  describe "translation helper functions" do
    test "translate_rename/3 renames existing key" do
      opts = [max_tokens: 100, temperature: 0.7]

      {result, warnings} = OpenAI.translate_rename(opts, :max_tokens, :max_completion_tokens)

      assert result[:max_completion_tokens] == 100
      refute Keyword.has_key?(result, :max_tokens)
      assert result[:temperature] == 0.7
      assert warnings == []
    end

    test "translate_rename/3 handles missing key gracefully" do
      opts = [temperature: 0.7]

      {result, warnings} = OpenAI.translate_rename(opts, :max_tokens, :max_completion_tokens)

      refute Keyword.has_key?(result, :max_completion_tokens)
      refute Keyword.has_key?(result, :max_tokens)
      assert result[:temperature] == 0.7
      assert warnings == []
    end

    test "translate_drop/3 removes key and returns warning" do
      opts = [temperature: 0.7, max_tokens: 100]
      message = "temperature not supported"

      {result, warnings} = OpenAI.translate_drop(opts, :temperature, message)

      refute Keyword.has_key?(result, :temperature)
      assert result[:max_tokens] == 100
      assert warnings == [message]
    end

    test "translate_drop/3 handles missing key gracefully" do
      opts = [max_tokens: 100]
      message = "temperature not supported"

      {result, warnings} = OpenAI.translate_drop(opts, :temperature, message)

      refute Keyword.has_key?(result, :temperature)
      assert result[:max_tokens] == 100
      # No warning because key wasn't present
      assert warnings == []
    end

    test "translate_drop/2 works without warning message" do
      opts = [temperature: 0.7, max_tokens: 100]

      {result, warnings} = OpenAI.translate_drop(opts, :temperature)

      refute Keyword.has_key?(result, :temperature)
      assert result[:max_tokens] == 100
      assert warnings == []
    end

    test "translate_combine_warnings/1 combines multiple translation results" do
      results = [
        {[max_completion_tokens: 100], []},
        {[top_p: 0.9], ["temperature dropped"]},
        {[frequency_penalty: 0.1], ["another warning"]}
      ]

      {final_opts, all_warnings} = OpenAI.translate_combine_warnings(results)

      assert final_opts[:max_completion_tokens] == 100
      assert final_opts[:top_p] == 0.9
      assert final_opts[:frequency_penalty] == 0.1
      assert all_warnings == ["temperature dropped", "another warning"]
    end

    test "translate_combine_warnings/1 handles empty results" do
      results = []

      {final_opts, all_warnings} = OpenAI.translate_combine_warnings(results)

      assert final_opts == []
      assert all_warnings == []
    end

    test "translate_combine_warnings/1 merges overlapping keys correctly" do
      results = [
        {[max_tokens: 100, temperature: 0.7], []},
        # Later value should overwrite
        {[max_tokens: 200], ["warning"]}
      ]

      {final_opts, all_warnings} = OpenAI.translate_combine_warnings(results)

      assert final_opts[:max_tokens] == 200
      assert final_opts[:temperature] == 0.7
      assert all_warnings == ["warning"]
    end
  end
end
