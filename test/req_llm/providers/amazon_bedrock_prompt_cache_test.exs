defmodule ReqLLM.Providers.AmazonBedrockPromptCacheTest do
  @moduledoc """
  Tests for Bedrock prompt caching auto-switching behavior.

  Verifies that when prompt caching is enabled with tools, Bedrock automatically
  switches to native API (use_converse: false) for full cache control.
  """

  # Logger capture needs async: false
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ReqLLM.Context
  alias ReqLLM.Providers.AmazonBedrock
  alias ReqLLM.Tool

  setup do
    # Mock AWS credentials for testing
    System.put_env("AWS_ACCESS_KEY_ID", "test_key")
    System.put_env("AWS_SECRET_ACCESS_KEY", "test_secret")
    System.put_env("AWS_REGION", "us-east-1")

    context = Context.new([Context.user("test message")])

    # Use a known Bedrock Claude model
    {:ok, model} = ReqLLM.model("amazon_bedrock:anthropic.claude-3-5-sonnet-20241022-v2:0")

    {:ok, context: context, model: model}
  end

  # Helper: Determine which API was chosen based on URL
  defp get_api_type(request) do
    url_str = to_string(request.url)

    cond do
      String.contains?(url_str, "converse") -> :converse
      String.contains?(url_str, "invoke") -> :native
      true -> :unknown
    end
  end

  describe "auto-switching to native API for caching" do
    test "uses Converse API by default when tools are present", %{context: context, model: model} do
      tools = [
        Tool.new!(
          name: "test_tool",
          description: "Test",
          parameter_schema: [],
          callback: fn _ -> {:ok, "test"} end
        )
      ]

      {:ok, request} = AmazonBedrock.prepare_request(:chat, model, context, tools: tools)
      assert get_api_type(request) == :converse
    end

    test "auto-switches to native API when caching + tools (with warning)", %{
      context: context,
      model: model
    } do
      tools = [
        Tool.new!(
          name: "test_tool",
          description: "Test",
          parameter_schema: [],
          callback: fn _ -> {:ok, "test"} end
        )
      ]

      log =
        capture_log(fn ->
          {:ok, request} =
            AmazonBedrock.prepare_request(:chat, model, context,
              tools: tools,
              anthropic_prompt_cache: true
            )

          assert get_api_type(request) == :native
        end)

      assert log =~ "Bedrock prompt caching enabled with tools present"
      assert log =~ "Auto-switching to native API"
    end

    test "respects explicit use_converse: true (no warning)", %{context: context, model: model} do
      tools = [
        Tool.new!(
          name: "test_tool",
          description: "Test",
          parameter_schema: [],
          callback: fn _ -> {:ok, "test"} end
        )
      ]

      log =
        capture_log(fn ->
          {:ok, request} =
            AmazonBedrock.prepare_request(:chat, model, context,
              tools: tools,
              anthropic_prompt_cache: true,
              use_converse: true
            )

          assert get_api_type(request) == :converse
        end)

      refute log =~ "Auto-switching"
    end

    test "respects explicit use_converse: false (no warning)", %{context: context, model: model} do
      tools = [
        Tool.new!(
          name: "test_tool",
          description: "Test",
          parameter_schema: [],
          callback: fn _ -> {:ok, "test"} end
        )
      ]

      log =
        capture_log(fn ->
          {:ok, request} =
            AmazonBedrock.prepare_request(:chat, model, context,
              tools: tools,
              anthropic_prompt_cache: true,
              use_converse: false
            )

          assert get_api_type(request) == :native
        end)

      refute log =~ "Auto-switching"
    end

    test "allows caching without tools (no auto-switch, no warning)", %{
      context: context,
      model: model
    } do
      log =
        capture_log(fn ->
          {:ok, request} =
            AmazonBedrock.prepare_request(:chat, model, context, anthropic_prompt_cache: true)

          assert get_api_type(request) == :native
        end)

      refute log =~ "Auto-switching"
    end

    test "handles empty tools list same as no tools", %{context: context, model: model} do
      log =
        capture_log(fn ->
          {:ok, request} =
            AmazonBedrock.prepare_request(:chat, model, context,
              tools: [],
              anthropic_prompt_cache: true
            )

          assert get_api_type(request) == :native
        end)

      refute log =~ "Auto-switching"
    end
  end

  describe "structured output (:object) with caching" do
    test "works with :object operation and caching", %{context: context, model: model} do
      compiled_schema = %{schema: %{type: "object", properties: %{}}}

      # :object operation creates synthetic tool, should support caching
      {:ok, request} =
        AmazonBedrock.prepare_request(:object, model, context,
          compiled_schema: compiled_schema,
          anthropic_prompt_cache: true
        )

      assert request != nil
      # Note: :object uses different flow so we can't easily verify endpoint type in tests
    end

    test "works with explicit use_converse option", %{context: context, model: model} do
      compiled_schema = %{schema: %{type: "object", properties: %{}}}

      {:ok, request} =
        AmazonBedrock.prepare_request(:object, model, context,
          compiled_schema: compiled_schema,
          anthropic_prompt_cache: true,
          use_converse: true
        )

      assert request != nil
    end
  end

  describe "default behavior without caching" do
    test "uses native API when no tools", %{context: context, model: model} do
      {:ok, request} = AmazonBedrock.prepare_request(:chat, model, context, [])
      assert get_api_type(request) == :native
    end

    test "uses Converse API when tools present", %{context: context, model: model} do
      tools = [
        Tool.new!(
          name: "test",
          description: "Test",
          parameter_schema: [],
          callback: fn _ -> {:ok, "test"} end
        )
      ]

      {:ok, request} = AmazonBedrock.prepare_request(:chat, model, context, tools: tools)
      assert get_api_type(request) == :converse
    end
  end
end
