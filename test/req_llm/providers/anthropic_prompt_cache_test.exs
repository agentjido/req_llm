defmodule ReqLLM.Providers.AnthropicPromptCacheTest do
  @moduledoc """
  Unit tests for Anthropic prompt caching functionality.

  Tests cache_control header injection and body transformations for:
  - Beta header inclusion
  - Tool cache_control injection
  - System message cache_control handling
  """

  use ReqLLM.ProviderCase, provider: ReqLLM.Providers.Anthropic

  alias ReqLLM.Providers.Anthropic

  describe "prompt caching beta header" do
    test "adds prompt caching beta header when enabled" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")
      context = context_fixture()

      {:ok, request} =
        Anthropic.prepare_request(:chat, model, context, anthropic_prompt_cache: true)

      beta_header =
        Enum.find_value(request.headers, fn
          {"anthropic-beta", value} -> value
          _ -> nil
        end)

      assert beta_header != nil
      beta_string = if is_list(beta_header), do: hd(beta_header), else: beta_header
      assert String.contains?(beta_string, "prompt-caching-2024-07-31")
    end

    test "does not add prompt caching beta header when disabled" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")
      context = context_fixture()

      {:ok, request} = Anthropic.prepare_request(:chat, model, context, [])

      beta_header =
        Enum.find_value(request.headers, fn
          {"anthropic-beta", value} -> value
          _ -> nil
        end)

      refute beta_header && String.contains?(beta_header, "prompt-caching-2024-07-31")
    end
  end

  describe "tool cache_control injection" do
    test "injects cache_control into tools with default TTL" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")
      context = context_fixture()

      tool =
        ReqLLM.Tool.new!(
          name: "test_tool",
          description: "A test tool",
          parameter_schema: [
            param: [type: :string, required: true, doc: "Test parameter"]
          ],
          callback: fn _ -> {:ok, "result"} end
        )

      {:ok, request} =
        Anthropic.prepare_request(:chat, model, context,
          tools: [tool],
          anthropic_prompt_cache: true
        )

      updated_request = Anthropic.encode_body(request)
      decoded = Jason.decode!(updated_request.body)

      assert is_list(decoded["tools"])
      assert length(decoded["tools"]) == 1

      [encoded_tool] = decoded["tools"]
      assert encoded_tool["cache_control"] == %{"type" => "ephemeral"}
    end

    test "injects cache_control into tools with 1h TTL" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")
      context = context_fixture()

      tool =
        ReqLLM.Tool.new!(
          name: "test_tool",
          description: "A test tool",
          parameter_schema: [
            param: [type: :string, required: true, doc: "Test parameter"]
          ],
          callback: fn _ -> {:ok, "result"} end
        )

      {:ok, request} =
        Anthropic.prepare_request(:chat, model, context,
          tools: [tool],
          anthropic_prompt_cache: true,
          anthropic_prompt_cache_ttl: "1h"
        )

      updated_request = Anthropic.encode_body(request)
      decoded = Jason.decode!(updated_request.body)

      assert is_list(decoded["tools"])
      [encoded_tool] = decoded["tools"]
      assert encoded_tool["cache_control"] == %{"type" => "ephemeral", "ttl" => "1h"}
    end

    test "does not inject cache_control when prompt caching disabled" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")
      context = context_fixture()

      tool =
        ReqLLM.Tool.new!(
          name: "test_tool",
          description: "A test tool",
          parameter_schema: [
            param: [type: :string, required: true, doc: "Test parameter"]
          ],
          callback: fn _ -> {:ok, "result"} end
        )

      {:ok, request} = Anthropic.prepare_request(:chat, model, context, tools: [tool])

      updated_request = Anthropic.encode_body(request)
      decoded = Jason.decode!(updated_request.body)

      assert is_list(decoded["tools"])
      [encoded_tool] = decoded["tools"]
      refute Map.has_key?(encoded_tool, "cache_control")
    end
  end

  describe "system message cache_control injection" do
    test "converts system string to content block with cache_control" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")
      context = context_fixture()

      {:ok, request} =
        Anthropic.prepare_request(:chat, model, context, anthropic_prompt_cache: true)

      updated_request = Anthropic.encode_body(request)
      decoded = Jason.decode!(updated_request.body)

      assert is_list(decoded["system"])
      [system_block] = decoded["system"]

      assert system_block["type"] == "text"
      assert system_block["text"] == "You are a helpful assistant."
      assert system_block["cache_control"] == %{"type" => "ephemeral"}
    end

    test "adds cache_control to last system block when already array" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      system_content = [
        ReqLLM.Message.ContentPart.text("First instruction."),
        ReqLLM.Message.ContentPart.text("Second instruction.")
      ]

      context =
        ReqLLM.Context.new([
          %ReqLLM.Message{role: :system, content: system_content},
          ReqLLM.Context.user("Hello!")
        ])

      {:ok, request} =
        Anthropic.prepare_request(:chat, model, context, anthropic_prompt_cache: true)

      updated_request = Anthropic.encode_body(request)
      decoded = Jason.decode!(updated_request.body)

      assert is_list(decoded["system"])
      assert length(decoded["system"]) == 2

      last_block = List.last(decoded["system"])
      assert last_block["cache_control"] == %{"type" => "ephemeral"}

      first_block = List.first(decoded["system"])
      refute Map.has_key?(first_block, "cache_control")
    end

    test "does not modify system when prompt caching disabled" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")
      context = context_fixture()

      {:ok, request} = Anthropic.prepare_request(:chat, model, context, [])

      updated_request = Anthropic.encode_body(request)
      decoded = Jason.decode!(updated_request.body)

      assert decoded["system"] == "You are a helpful assistant."
    end
  end

  describe "combined prompt caching scenarios" do
    test "applies cache_control to both tools and system" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")
      context = context_fixture()

      tool =
        ReqLLM.Tool.new!(
          name: "test_tool",
          description: "A test tool",
          parameter_schema: [
            param: [type: :string, required: true, doc: "Test parameter"]
          ],
          callback: fn _ -> {:ok, "result"} end
        )

      {:ok, request} =
        Anthropic.prepare_request(:chat, model, context,
          tools: [tool],
          anthropic_prompt_cache: true,
          anthropic_prompt_cache_ttl: "2h"
        )

      updated_request = Anthropic.encode_body(request)
      decoded = Jason.decode!(updated_request.body)

      [system_block] = decoded["system"]
      assert system_block["cache_control"] == %{"type" => "ephemeral", "ttl" => "2h"}

      [encoded_tool] = decoded["tools"]
      assert encoded_tool["cache_control"] == %{"type" => "ephemeral", "ttl" => "2h"}
    end

    test "respects existing cache_control on tools" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      context = context_fixture()

      tool =
        ReqLLM.Tool.new!(
          name: "test_tool",
          description: "A test tool",
          parameter_schema: [
            param: [type: :string, required: true, doc: "Test parameter"]
          ],
          callback: fn _ -> {:ok, "result"} end
        )

      {:ok, request} =
        Anthropic.prepare_request(:chat, model, context,
          tools: [tool],
          anthropic_prompt_cache: true
        )

      updated_request = Anthropic.encode_body(request)
      decoded = Jason.decode!(updated_request.body)

      assert is_list(decoded["tools"])
      [encoded_tool] = decoded["tools"]
      assert encoded_tool["cache_control"] == %{"type" => "ephemeral"}
    end
  end
end
