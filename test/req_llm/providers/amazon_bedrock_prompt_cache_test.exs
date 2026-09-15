defmodule ReqLLM.Providers.AmazonBedrockPromptCacheTest do
  @moduledoc """
  Bedrock prompt caching options and their effect on Converse/native routing.
  """

  use ExUnit.Case, async: false

  alias ReqLLM.Context
  alias ReqLLM.Providers.AmazonBedrock
  alias ReqLLM.Tool

  setup do
    # Mock AWS credentials for testing
    System.put_env("AWS_ACCESS_KEY_ID", "test_key")
    System.put_env("AWS_SECRET_ACCESS_KEY", "test_secret")
    System.put_env("AWS_REGION", "us-east-1")

    context = Context.new([Context.user("test message")])

    {:ok, model} =
      ReqLLM.model(%{provider: :amazon_bedrock, id: "anthropic.claude-3-5-sonnet-20241022-v2:0"})

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

  defp request_body(request) do
    prepared = Req.Request.prepare(request)
    Jason.decode!(prepared.body)
  end

  defp test_tool do
    Tool.new!(
      name: "test_tool",
      description: "Test",
      parameter_schema: [],
      callback: fn _ -> {:ok, "test"} end
    )
  end

  describe "routing is independent of caching" do
    test "caching with tools stays on Converse and emits cachePoint", %{
      context: context,
      model: model
    } do
      {:ok, request} =
        AmazonBedrock.prepare_request(:chat, model, context,
          tools: [test_tool()],
          provider_options: [prompt_cache: true, cache_messages: true]
        )

      assert get_api_type(request) == :converse

      body = request_body(request)

      assert List.last(body["toolConfig"]["tools"]) == %{"cachePoint" => %{"type" => "default"}}

      assert List.last(List.last(body["messages"])["content"]) == %{
               "cachePoint" => %{"type" => "default"}
             }
    end

    test "legacy alias with tools also stays on Converse", %{context: context, model: model} do
      {:ok, request} =
        AmazonBedrock.prepare_request(:chat, model, context,
          tools: [test_tool()],
          anthropic_prompt_cache: true
        )

      assert get_api_type(request) == :converse

      assert List.last(request_body(request)["toolConfig"]["tools"]) == %{
               "cachePoint" => %{"type" => "default"}
             }
    end

    test "caching without tools stays native and emits cache_control", %{model: model} do
      context = Context.new([Context.system("Stable"), Context.user("test message")])

      {:ok, request} =
        AmazonBedrock.prepare_request(:chat, model, context,
          provider_options: [prompt_cache: true, prompt_cache_ttl: "1h"]
        )

      assert get_api_type(request) == :native

      assert [%{"cache_control" => %{"type" => "ephemeral", "ttl" => "1h"}}] =
               request_body(request)["system"]
    end

    test "explicit use_converse: false with tools goes native", %{context: context, model: model} do
      {:ok, request} =
        AmazonBedrock.prepare_request(:chat, model, context,
          tools: [test_tool()],
          provider_options: [prompt_cache: true, use_converse: false]
        )

      assert get_api_type(request) == :native
      assert %{"cache_control" => _} = List.last(request_body(request)["tools"])
    end

    test "explicit use_converse: true without tools goes Converse", %{
      context: context,
      model: model
    } do
      {:ok, request} =
        AmazonBedrock.prepare_request(:chat, model, context,
          provider_options: [prompt_cache: true, use_converse: true]
        )

      assert get_api_type(request) == :converse

      assert List.last(request_body(request)["messages"]) |> Map.fetch!("content") |> List.last() ==
               %{"text" => "test message"}
    end

    test "handles empty tools list same as no tools", %{context: context, model: model} do
      {:ok, request} =
        AmazonBedrock.prepare_request(:chat, model, context,
          tools: [],
          provider_options: [prompt_cache: true]
        )

      assert get_api_type(request) == :native
    end
  end

  describe "tool search routing" do
    defp deferred_tool do
      Tool.new!(
        name: "get_weather",
        description: "Weather for a city",
        parameter_schema: [city: [type: :string, required: true]],
        callback: fn _ -> {:ok, "sunny"} end,
        provider_options: [anthropic: [defer_loading: true]]
      )
    end

    defp tool_search_bodies(context, opts) do
      model =
        ReqLLM.model!(%{provider: :amazon_bedrock, id: "us.anthropic.claude-sonnet-4-6"})

      opts = [api_key: "test_key", tools: [deferred_tool()]] ++ opts
      {:ok, request} = AmazonBedrock.prepare_request(:chat, model, context, opts)
      {:ok, stream} = AmazonBedrock.attach_stream(model, context, opts, ReqLLM.Finch)

      assert get_api_type(request) == :native
      assert stream.path =~ "/invoke-with-response-stream"

      [request_body(request), Jason.decode!(stream.body)]
    end

    test "uses InvokeModel when tool search is enabled", %{context: context} do
      for opts <- [[tool_search: %{}], [provider_options: [tool_search: %{}]]],
          body <- tool_search_bodies(context, opts) do
        assert [search, deferred] = body["tools"]
        assert search["type"] == "tool_search_tool_bm25_20251119"
        assert deferred["defer_loading"] == true
      end
    end

    test "keeps caching on non-deferred tools through InvokeModel", %{context: context} do
      for opts <- [
            [provider_options: [tool_search: %{variant: :regex}, prompt_cache: true]],
            [tool_search: %{variant: :regex}, anthropic_prompt_cache: true]
          ],
          body <- tool_search_bodies(context, opts) do
        assert [search, deferred] = body["tools"]
        assert search["type"] == "tool_search_tool_regex_20251119"
        assert search["cache_control"] == %{"type" => "ephemeral"}
        assert deferred["defer_loading"] == true
        refute Map.has_key?(deferred, "cache_control")
      end
    end
  end

  describe "Converse keeps what the InvokeModel request carried" do
    defp lookup_tool do
      Tool.new!(
        name: "lookup",
        description: "Lookup",
        parameter_schema: [],
        callback: fn _ -> {:ok, "x"} end
      )
    end

    defp claude_37 do
      ReqLLM.model!(%{provider: :amazon_bedrock, id: "anthropic.claude-3-7-sonnet-20250219-v1:0"})
    end

    defp cached_tool_opts(opts),
      do: [tools: [lookup_tool()], anthropic_prompt_cache: true] ++ opts

    defp bodies(context, opts) do
      model = claude_37()
      opts = cached_tool_opts(opts)

      {:ok, request} = AmazonBedrock.prepare_request(:chat, model, context, opts)
      {:ok, stream} = AmazonBedrock.attach_stream(model, context, opts, ReqLLM.Finch)

      [request_body(request), Jason.decode!(stream.body)]
    end

    defp both_routes(context, opts) do
      native_opts =
        Keyword.update(
          opts,
          :provider_options,
          [use_converse: false],
          &[{:use_converse, false} | &1]
        )

      %{converse: bodies(context, opts), native: bodies(context, native_opts)}
    end

    test "keeps a required tool choice", %{context: context} do
      %{converse: converse, native: native} = both_routes(context, tool_choice: :required)

      for body <- converse, do: assert(body["toolConfig"]["toolChoice"] == %{"any" => %{}})
      for body <- native, do: assert(body["tool_choice"] == %{"type" => "any"})
    end

    test "keeps a named tool choice", %{context: context} do
      %{converse: converse, native: native} =
        both_routes(context, tool_choice: %{type: "tool", name: "lookup"})

      for body <- converse,
          do: assert(body["toolConfig"]["toolChoice"] == %{"tool" => %{"name" => "lookup"}})

      for body <- native,
          do: assert(body["tool_choice"] == %{"type" => "tool", "name" => "lookup"})
    end

    test "rejects tool_choice none on Converse and keeps it on InvokeModel", %{context: context} do
      opts = cached_tool_opts(tool_choice: :none)

      assert_raise ReqLLM.Error.Invalid.Parameter, fn ->
        AmazonBedrock.prepare_request(:chat, claude_37(), context, opts)
      end

      assert {:error, {:bedrock_stream_build_failed, %ReqLLM.Error.Invalid.Parameter{}}} =
               AmazonBedrock.attach_stream(claude_37(), context, opts, ReqLLM.Finch)

      for body <- bodies(context, tool_choice: :none, provider_options: [use_converse: false]),
          do: assert(body["tool_choice"] == %{"type" => "none"})
    end

    test "keeps top_k", %{context: context} do
      %{converse: converse, native: native} = both_routes(context, top_k: 5)

      for body <- converse, do: assert(body["additionalModelRequestFields"]["top_k"] == 5)
      for body <- native, do: assert(body["top_k"] == 5)
    end

    test "keeps anthropic_beta", %{context: context} do
      betas = ["token-efficient-tools-2025-02-19"]

      %{converse: converse, native: native} =
        both_routes(context, provider_options: [anthropic_beta: betas])

      for body <- converse,
          do: assert(body["additionalModelRequestFields"]["anthropic_beta"] == betas)

      for body <- native, do: assert(body["anthropic_beta"] == betas)
    end

    test "drops thinking when a tool is forced" do
      context = Context.new([Context.user("Look up the weather")])

      %{converse: converse, native: native} =
        both_routes(context,
          tool_choice: %{type: "tool", name: "lookup"},
          provider_options: [
            additional_model_request_fields: %{thinking: %{type: "enabled", budget_tokens: 1024}}
          ]
        )

      for body <- converse, do: refute(get_in(body, ["additionalModelRequestFields", "thinking"]))
      for body <- native, do: refute(body["thinking"])
    end

    test "keeps the tool result error status" do
      context =
        Context.new([
          Context.user("Look up the weather"),
          Context.assistant("", tool_calls: [ReqLLM.ToolCall.new("call_1", "lookup", "{}")]),
          %{Context.tool_result("call_1", "boom") | metadata: %{is_error: true}}
        ])

      %{converse: converse, native: native} = both_routes(context, [])

      for body <- converse do
        assert [%{"toolResult" => %{"toolUseId" => "call_1", "status" => "error"}}] =
                 List.last(body["messages"])["content"]
      end

      for body <- native do
        assert [%{"type" => "tool_result", "tool_use_id" => "call_1", "is_error" => true}] =
                 List.last(body["messages"])["content"]
      end
    end
  end

  describe "structured output (:object) with caching" do
    @compiled_schema %{schema: %{type: "object", properties: %{}}}

    test "caches the synthetic tool on the native path", %{context: context, model: model} do
      {:ok, request} =
        AmazonBedrock.prepare_request(:object, model, context,
          compiled_schema: @compiled_schema,
          provider_options: [prompt_cache: true]
        )

      assert get_api_type(request) == :native

      assert [%{"name" => "structured_output", "cache_control" => _}] =
               request_body(request)["tools"]
    end

    test "caches the synthetic tool on Converse", %{context: context, model: model} do
      opts = [
        compiled_schema: @compiled_schema,
        provider_options: [prompt_cache: true, use_converse: true]
      ]

      {:ok, request} = AmazonBedrock.prepare_request(:object, model, context, opts)

      {:ok, stream} =
        AmazonBedrock.attach_stream(
          model,
          context,
          [operation: :object] ++ opts,
          ReqLLM.Finch
        )

      assert get_api_type(request) == :converse

      for body <- [request_body(request), Jason.decode!(stream.body)] do
        assert [%{"toolSpec" => %{"name" => "structured_output"}}, %{"cachePoint" => _}] =
                 body["toolConfig"]["tools"]

        assert body["toolConfig"]["toolChoice"] == %{"tool" => %{"name" => "structured_output"}}
      end
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

  describe "option aliases" do
    test "accepts generic options", %{model: model} do
      {:ok, opts} =
        ReqLLM.Provider.Options.process(AmazonBedrock, :chat, model,
          provider_options: [prompt_cache: true, prompt_cache_ttl: "1h", cache_messages: -2]
        )

      assert get_in(opts, [:provider_options, :prompt_cache]) == true
      assert get_in(opts, [:provider_options, :prompt_cache_ttl]) == "1h"
      assert get_in(opts, [:provider_options, :cache_messages]) == -2
    end

    test "aliases do not raise under on_unsupported: :error", %{model: model} do
      assert {:ok, _opts} =
               ReqLLM.Provider.Options.process(AmazonBedrock, :chat, model,
                 on_unsupported: :error,
                 provider_options: [anthropic_prompt_cache: true]
               )
    end

    test "rejects an unsupported ttl", %{model: model} do
      assert {:error, _} =
               ReqLLM.Provider.Options.process(AmazonBedrock, :chat, model,
                 provider_options: [prompt_cache: true, prompt_cache_ttl: "30m"]
               )
    end
  end
end
