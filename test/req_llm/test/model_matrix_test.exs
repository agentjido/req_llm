defmodule ReqLLM.Test.ModelMatrixTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Test.{FakeRegistry, ModelMatrix}

  @opts [registry: FakeRegistry]

  describe "selected_specs/0 with defaults" do
    test "returns default models when no env vars set" do
      specs = ModelMatrix.selected_specs(@opts)

      assert "openai:gpt-4o-mini" in specs
      assert "anthropic:claude-3-5-haiku-20241022" in specs
      assert "google:gemini-2.0-flash" in specs

      assert specs == Enum.sort(specs)
    end

    test "returns default models in sorted order" do
      specs = ModelMatrix.selected_specs(@opts)
      assert specs == Enum.sort(specs)
    end
  end

  describe "selected_specs/0 with REQ_LLM_MODELS=all" do
    test "returns all available models" do
      specs = ModelMatrix.selected_specs([env: %{"REQ_LLM_MODELS" => "all"}] ++ @opts)

      assert length(specs) == 10
      assert Enum.any?(specs, &String.starts_with?(&1, "openai:"))
      assert Enum.any?(specs, &String.starts_with?(&1, "anthropic:"))
      assert Enum.any?(specs, &String.starts_with?(&1, "google:"))
      assert Enum.any?(specs, &String.starts_with?(&1, "groq:"))
      assert Enum.any?(specs, &String.starts_with?(&1, "xai:"))
    end

    test "includes models from all providers" do
      specs = ModelMatrix.selected_specs([env: %{"REQ_LLM_MODELS" => "all"}] ++ @opts)

      assert Enum.count(specs, &String.starts_with?(&1, "anthropic:")) == 2
      assert Enum.count(specs, &String.starts_with?(&1, "openai:")) == 2
      assert Enum.count(specs, &String.starts_with?(&1, "google:")) == 2
      assert Enum.count(specs, &String.starts_with?(&1, "groq:")) == 2
      assert Enum.count(specs, &String.starts_with?(&1, "xai:")) == 2
    end
  end

  describe "selected_specs/0 with pattern matching" do
    test "selects all models from specific provider" do
      specs = ModelMatrix.selected_specs([env: %{"REQ_LLM_MODELS" => "anthropic:*"}] ++ @opts)

      refute Enum.empty?(specs)
      assert Enum.all?(specs, &String.starts_with?(&1, "anthropic:"))
      assert length(specs) == 2
      assert "anthropic:claude-sonnet-4-5-20250929" in specs
      assert "anthropic:claude-3-5-haiku-20241022" in specs
    end

    test "handles multiple specific models" do
      pattern = "openai:gpt-4o,anthropic:claude-3-5-haiku-20241022"
      specs = ModelMatrix.selected_specs([env: %{"REQ_LLM_MODELS" => pattern}] ++ @opts)

      assert length(specs) == 2
      assert "openai:gpt-4o" in specs
      assert "anthropic:claude-3-5-haiku-20241022" in specs
    end

    test "handles wildcard patterns mixed with specific" do
      pattern = "anthropic:*,openai:gpt-4o"
      specs = ModelMatrix.selected_specs([env: %{"REQ_LLM_MODELS" => pattern}] ++ @opts)

      assert Enum.any?(specs, &String.starts_with?(&1, "anthropic:"))
      assert "openai:gpt-4o" in specs
      refute "openai:gpt-4o-mini" in specs
    end

    test "handles *:* wildcard for all models" do
      specs = ModelMatrix.selected_specs([env: %{"REQ_LLM_MODELS" => "*:*"}] ++ @opts)

      assert length(specs) == 10
      assert Enum.any?(specs, &String.starts_with?(&1, "anthropic:"))
      assert Enum.any?(specs, &String.starts_with?(&1, "openai:"))
    end

    test "handles 'all' keyword" do
      specs = ModelMatrix.selected_specs([env: %{"REQ_LLM_MODELS" => "all"}] ++ @opts)

      assert length(specs) == 10
    end
  end

  describe "selected_specs/0 with sampling" do
    test "samples specified number per provider" do
      specs =
        ModelMatrix.selected_specs(
          [
            env: %{"REQ_LLM_MODELS" => "all", "REQ_LLM_SAMPLE" => "1"}
          ] ++ @opts
        )

      assert length(specs) == 5

      providers = specs |> Enum.map(&(String.split(&1, ":") |> hd())) |> Enum.uniq()
      assert length(providers) == 5
    end

    test "sampling preserves provider diversity" do
      specs =
        ModelMatrix.selected_specs(
          [
            env: %{"REQ_LLM_MODELS" => "all", "REQ_LLM_SAMPLE" => "1"}
          ] ++ @opts
        )

      assert Enum.any?(specs, &String.starts_with?(&1, "anthropic:"))
      assert Enum.any?(specs, &String.starts_with?(&1, "openai:"))
      assert Enum.any?(specs, &String.starts_with?(&1, "google:"))
    end

    test "ignores invalid sample values" do
      specs =
        ModelMatrix.selected_specs(
          [
            env: %{"REQ_LLM_MODELS" => "all", "REQ_LLM_SAMPLE" => "invalid"}
          ] ++ @opts
        )

      assert length(specs) == 10
    end

    test "ignores negative sample values" do
      specs =
        ModelMatrix.selected_specs(
          [
            env: %{"REQ_LLM_MODELS" => "all", "REQ_LLM_SAMPLE" => "-1"}
          ] ++ @opts
        )

      assert length(specs) == 10
    end
  end

  describe "selected_specs/0 with exclusions" do
    test "excludes specified models" do
      specs =
        ModelMatrix.selected_specs(
          [
            env: %{"REQ_LLM_MODELS" => "all", "REQ_LLM_EXCLUDE" => "openai:gpt-4o"}
          ] ++ @opts
        )

      refute "openai:gpt-4o" in specs
      assert "openai:gpt-4o-mini" in specs
    end

    test "handles multiple exclusions with comma" do
      specs =
        ModelMatrix.selected_specs(
          [
            env: %{
              "REQ_LLM_MODELS" => "all",
              "REQ_LLM_EXCLUDE" => "openai:gpt-4o,anthropic:claude-3-5-haiku-20241022"
            }
          ] ++ @opts
        )

      refute "openai:gpt-4o" in specs
      refute "anthropic:claude-3-5-haiku-20241022" in specs
      assert length(specs) == 8
    end

    test "handles multiple exclusions with space" do
      specs =
        ModelMatrix.selected_specs(
          [
            env: %{
              "REQ_LLM_MODELS" => "all",
              "REQ_LLM_EXCLUDE" => "openai:gpt-4o anthropic:claude-3-5-haiku-20241022"
            }
          ] ++ @opts
        )

      refute "openai:gpt-4o" in specs
      refute "anthropic:claude-3-5-haiku-20241022" in specs
    end
  end

  describe "edge cases" do
    test "handles empty pattern list" do
      specs = ModelMatrix.selected_specs([env: %{"REQ_LLM_MODELS" => ""}] ++ @opts)

      assert specs == []
    end

    test "handles invalid provider in pattern" do
      specs =
        ModelMatrix.selected_specs([env: %{"REQ_LLM_MODELS" => "nonexistent:*"}] ++ @opts)

      assert specs == []
    end

    test "handles malformed patterns gracefully" do
      specs = ModelMatrix.selected_specs([env: %{"REQ_LLM_MODELS" => "invalid"}] ++ @opts)

      assert specs == []
    end
  end

  describe "models_for_provider/1" do
    test "filters to specific provider" do
      specs = ModelMatrix.models_for_provider(:anthropic, @opts)

      refute Enum.empty?(specs)
      assert Enum.all?(specs, &String.starts_with?(&1, "anthropic:"))
    end

    test "works with wildcard selection" do
      opts = [env: %{"REQ_LLM_MODELS" => "all"}] ++ @opts
      specs = ModelMatrix.models_for_provider(:openai, opts)

      assert length(specs) == 2
      assert "openai:gpt-4o" in specs
      assert "openai:gpt-4o-mini" in specs
    end

    test "returns empty list for provider not in selection" do
      opts = [env: %{"REQ_LLM_MODELS" => "anthropic:*"}] ++ @opts
      specs = ModelMatrix.models_for_provider(:openai, opts)

      assert specs == []
    end

    test "works with sampling" do
      opts = [env: %{"REQ_LLM_MODELS" => "all", "REQ_LLM_SAMPLE" => "1"}] ++ @opts
      specs = ModelMatrix.models_for_provider(:anthropic, opts)

      assert length(specs) == 1
      assert Enum.all?(specs, &String.starts_with?(&1, "anthropic:"))
    end
  end
end
