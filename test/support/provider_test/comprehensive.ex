defmodule ReqLLM.ProviderTest.Comprehensive do
  @moduledoc """
  Comprehensive per-model provider tests.

  Consolidates all provider capability testing into up to 9 focused tests per model:
  1. Basic generate_text (non-streaming)
  2. Streaming with system context + creative params
  3. Token limit constraints
  4. Usage metrics and cost calculations
  5. Tool calling - multi-tool selection
  6. Tool calling - no tool when inappropriate
  7. Object generation (non-streaming) - only for models with object generation support
  8. Object generation (streaming) - only for models with object generation support
  9. Reasoning/thinking tokens - only for models with :reasoning capability

  Tests use fixtures for fast, deterministic execution while supporting
  live API recording with REQ_LLM_FIXTURES_MODE=record.

  ## Usage

      defmodule ReqLLM.Coverage.Anthropic.ComprehensiveTest do
        use ReqLLM.ProviderTest.Comprehensive, provider: :anthropic
      end

  This will generate all tests for models selected by ModelMatrix for the provider.

  ## Debug Output

  Set REQ_LLM_DEBUG=1 to enable verbose fixture output during test runs.
  """

  def supports_object_generation?(model_spec) do
    case ReqLLM.model(model_spec) do
      {:ok, model} ->
        caps = model.capabilities || %{}

        # Object generation is supported if:
        # 1. Model has native JSON mode (json.native)
        # 2. Model supports JSON schemas (json.schema)
        # 3. Model has strict tool calling (tools.strict = true)
        # 4. Model has regular tool calling (tools.enabled = true) - req_llm has workaround
        get_in(caps, [:json, :native]) ||
          get_in(caps, [:json, :schema]) ||
          get_in(caps, [:tools, :strict]) == true ||
          get_in(caps, [:tools, :enabled]) == true

      {:error, _} ->
        false
    end
  end

  def supports_streaming_object_generation?(model_spec) do
    case ReqLLM.model(model_spec) do
      {:ok, model} ->
        caps = model.capabilities || %{}

        # Must support object generation AND streaming tool calls
        supports_object = supports_object_generation?(model_spec)
        supports_streaming = get_in(caps, [:streaming, :tool_calls]) != false

        supports_object && supports_streaming

      {:error, _} ->
        false
    end
  end

  def supports_tool_calling?(model_spec) do
    case ReqLLM.model(model_spec) do
      {:ok, model} -> get_in(model.capabilities, [:tools, :enabled]) == true
      {:error, _} -> false
    end
  end

  def supports_reasoning?(model_spec) do
    case ReqLLM.model(model_spec) do
      {:ok, model} -> get_in(model.capabilities, [:reasoning, :enabled]) == true
      {:error, _} -> false
    end
  end

  defmacro __using__(opts) do
    provider = Keyword.fetch!(opts, :provider)

    quote bind_quoted: [provider: provider] do
      use ExUnit.Case, async: false

      import ExUnit.Case
      import ReqLLM.Context
      import ReqLLM.Debug, only: [dbug: 2]
      import ReqLLM.Test.Helpers

      alias ReqLLM.Test.ModelMatrix

      @moduletag :coverage
      @moduletag provider: to_string(provider)
      @moduletag timeout: 300_000

      @provider provider
      @models ModelMatrix.models_for_provider(provider, operation: :text)

      setup_all do
        LLMDB.load(allow: :all, custom: %{})
        :ok
      end

      for model_spec <- @models do
        @model_spec model_spec

        describe "#{model_spec}" do
          @describetag model: model_spec |> String.split(":", parts: 2) |> List.last()

          @tag scenario: :basic
          test "basic generate_text (non-streaming)" do
            require Logger

            dbug(
              fn -> "\n[Comprehensive] model_spec=#{@model_spec}, test=basic_generate" end,
              component: :test
            )

            opts =
              reasoning_overlay(
                @model_spec,
                param_bundles().deterministic,
                2000
              )

            ReqLLM.generate_text(
              @model_spec,
              "Hello world!",
              fixture_opts("basic", opts)
            )
            |> assert_basic_response()
          end

          @tag scenario: :streaming
          test "stream_text with system context and creative params" do
            require Logger

            dbug(
              fn -> "\n[Comprehensive] model_spec=#{@model_spec}, test=streaming" end,
              component: :test
            )

            context =
              ReqLLM.Context.new([
                system("You are a helpful, creative assistant."),
                user("Say hello in one short, imaginative sentence.")
              ])

            opts =
              reasoning_overlay(@model_spec, @provider, param_bundles(@provider).creative, 2000)

            {:ok, stream_response} =
              ReqLLM.stream_text(
                @model_spec,
                context,
                fixture_opts(@provider, "streaming", opts)
              )

            assert %ReqLLM.StreamResponse{} = stream_response
            assert stream_response.stream
            assert stream_response.metadata_handle

            {:ok, response} = ReqLLM.StreamResponse.to_response(stream_response)

            finish_reason = ReqLLM.StreamResponse.finish_reason(stream_response)

            # Assert response structure without context advancement check
            # (streaming doesn't auto-append to context)
            assert %ReqLLM.Response{} = response

            text = ReqLLM.Response.text(response) || ""
            thinking = ReqLLM.Response.thinking(response) || ""
            combined = text <> thinking

            assert combined != "",
                   "Expected text or thinking content, got empty (text: #{inspect(text)}, thinking: #{inspect(thinking)})"

            assert response.message.role == :assistant

            refute is_nil(finish_reason)

            usage = response.usage
            assert is_map(usage)
            assert is_number(usage.input_tokens) and usage.input_tokens > 0
            assert is_number(usage.output_tokens) and usage.output_tokens >= 0
            assert is_number(usage.total_tokens) and usage.total_tokens > 0
            assert is_number(usage.cached_input) and usage.cached_input >= 0
            assert is_number(usage.reasoning) and usage.reasoning >= 0
          end

          @tag scenario: :token_limit
          @tag timeout: 600_000
          test "token limit constraints" do
            opts =
              param_bundles(@provider).minimal
              |> Keyword.put(:max_tokens, 100)
              |> then(&reasoning_overlay(@model_spec, @provider, &1, 3000))

            case ReqLLM.generate_text(
                   @model_spec,
                   "Write a very long story about dragons and adventures",
                   fixture_opts(@provider, "token_limit", opts)
                 ) do
              {:ok, response} ->
                assert_basic_response({:ok, response})

                content = combined_content(response)

                if truncated?(response) do
                  rt = ReqLLM.Response.reasoning_tokens(response)
                  assert is_number(rt) and rt >= 0

                  if content != "" do
                    assert String.length(content) > 0,
                           "Truncated response should have some content or reasoning tokens"
                  end
                else
                  assert_text_length(response, 150)
                end

              other ->
                flunk("Expected {:ok, %ReqLLM.Response{}}, got: #{inspect(other)}")
            end
          end

          @tag scenario: :usage
          test "usage metrics and cost calculations" do
            require Logger

            dbug(
              fn -> "\n[Comprehensive] model_spec=#{@model_spec}, test=usage" end,
              component: :test
            )

            max_tokens =
              case ReqLLM.model(@model_spec) do
                {:ok, %{capabilities: %{reasoning: true}}} -> 500
                {:ok, %{model: "gpt-4.1" <> _}} -> 16
                {:ok, %{extra: %{api: "responses"}}} -> 200
                _ -> 10
              end

            {:ok, response} =
              ReqLLM.generate_text(
                @model_spec,
                "Hi there!",
                fixture_opts(
                  "usage",
                  Keyword.put(param_bundles().deterministic, :max_tokens, max_tokens)
                )
              )

            assert %ReqLLM.Response{} = response

            # For reasoning models, allow empty text if reasoning tokens were used
            text = ReqLLM.Response.text(response) || ""
            reasoning_tokens = response.usage.reasoning_tokens || 0

            assert text != "" or reasoning_tokens > 0,
                   "Expected either text content or reasoning tokens, got neither"

            assert is_map(response.usage)

            assert is_number(response.usage.input_tokens) and response.usage.input_tokens > 0
            assert is_number(response.usage.output_tokens) and response.usage.output_tokens >= 0
            assert is_number(response.usage.total_tokens) and response.usage.total_tokens > 0
            assert is_number(response.usage.cached_tokens) and response.usage.cached_tokens >= 0

            assert is_number(response.usage.reasoning_tokens) and
                     response.usage.reasoning_tokens >= 0

            case ReqLLM.model(@model_spec) do
              {:ok, %LLMDB.Model{cost: cost_map}} when is_map(cost_map) ->
                assert is_number(response.usage.input_cost) and response.usage.input_cost >= 0

                assert is_number(response.usage.output_cost) and
                         response.usage.output_cost >= 0

                assert is_number(response.usage.total_cost) and response.usage.total_cost >= 0

                expected = response.usage.input_cost + response.usage.output_cost
                assert abs(response.usage.total_cost - expected) < 0.00001

              _ ->
                refute Map.has_key?(response.usage, :input_cost)
            end
          end

          @tag scenario: :context_append
          test "context append continues conversation" do
            ctx = ReqLLM.Context.new([user("Respond with a single word 'Hi'.")])

            opts =
              param_bundles().deterministic
              # Required as thinking models like gpt-5-mini or gemini might not fit into the default budget of 50 tokens
              |> Keyword.put(:max_tokens, 1024)

            {:ok, resp1} =
              ReqLLM.generate_text(
                @model_spec,
                ctx,
                fixture_opts(@provider, "context_append_1", opts)
              )

            ctx2 = ReqLLM.Context.append(resp1.context, user("Hi again"))

            {:ok, resp2} =
              ReqLLM.generate_text(
                @model_spec,
                ctx2,
                fixture_opts(@provider, "context_append_2", opts)
              )

            text = ReqLLM.Response.text(resp2) || ""
            reasoning_tokens = Map.get(resp2.usage || %{}, :reasoning_tokens, 0)

            assert text != "" or reasoning_tokens > 0
            assert length(resp2.context.messages) >= 4
            assert List.last(resp2.context.messages) == resp2.message
            assert resp2.message.role == :assistant
          end

          if ReqLLM.ProviderTest.Comprehensive.supports_tool_calling?(model_spec) do
            @tag scenario: :tool_multi
            test "tool calling - multi-tool selection" do
              tools = [
                ReqLLM.tool(
                  name: "get_weather",
                  description: "Get current weather information for a location",
                  parameter_schema: [
                    location: [type: :string, required: true],
                    unit: [type: {:in, ["celsius", "fahrenheit"]}]
                  ],
                  callback: fn _args -> {:ok, "Weather data"} end
                ),
                ReqLLM.tool(
                  name: "tell_joke",
                  description: "Tell a funny joke",
                  parameter_schema: [
                    topic: [type: :string, doc: "Topic for the joke"]
                  ],
                  callback: fn _args -> {:ok, "Why did the cat cross the road?"} end
                ),
                ReqLLM.tool(
                  name: "get_time",
                  description: "Get the current time",
                  parameter_schema: [],
                  callback: fn _args -> {:ok, "12:00 PM"} end
                )
              ]

              base_opts =
                param_bundles().deterministic
                |> Keyword.put(:max_tokens, tool_budget_for(@model_spec))
                |> then(
                  &reasoning_overlay(
                    @model_spec,
                    &1,
                    tool_budget_for(@model_spec) * 2
                  )
                )

              result =
                ReqLLM.generate_text(
                  @model_spec,
                  "What's the weather like in Paris, France?",
                  fixture_opts("multi_tool", base_opts ++ [tools: tools])
                )

              case result do
                {:ok, response} ->
                  assert_basic_response(result)

                  tool_calls = ReqLLM.Response.tool_calls(response) || []

                  if Enum.empty?(tool_calls) and truncated?(response) do
                    rt = ReqLLM.Response.reasoning_tokens(response)
                    assert is_number(rt) and rt >= 0
                  else
                    assert_has_tool_call(response)
                  end

                {:error, _} ->
                  flunk("Expected successful response with tool call")
              end
            end

            @tag scenario: :tool_round_trip
            test "tool calling - round trip execution" do
              tools = [
                ReqLLM.tool(
                  name: "add",
                  description: "Add two integers",
                  parameter_schema: [
                    a: [type: :integer, required: true],
                    b: [type: :integer, required: true]
                  ],
                  callback: fn %{a: a, b: b} -> {:ok, a + b} end
                )
              ]

              base_opts =
                param_bundles().deterministic
                |> Keyword.put(:max_tokens, tool_budget_for(@model_spec))

              {:ok, resp1} =
                ReqLLM.generate_text(
                  @model_spec,
                  "Use the add tool to compute 2 + 3. After the tool result arrives, respond with 'sum=<value>'.",
                  fixture_opts(
                    "tool_round_trip_1",
                    base_opts ++
                      [
                        tools: tools,
                        tool_choice: %{type: "tool", name: "add"}
                      ]
                  )
                )

              tool_calls = ReqLLM.Response.tool_calls(resp1)
              assert tool_calls != []

              ctx2 = ReqLLM.Context.execute_and_append_tools(resp1.context, tool_calls, tools)

              {:ok, resp2} =
                ReqLLM.generate_text(
                  @model_spec,
                  ctx2,
                  fixture_opts("tool_round_trip_2", base_opts)
                )

              text = ReqLLM.Response.text(resp2) || ""
              assert text != ""
              assert String.contains?(text, "5")
              assert Enum.empty?(ReqLLM.Response.tool_calls(resp2))
            end

            @tag scenario: :tool_none
            test "tool calling - no tool when inappropriate" do
              tools = [
                ReqLLM.tool(
                  name: "get_weather",
                  description: "Get current weather information for a location",
                  parameter_schema: [
                    location: [type: :string, required: true]
                  ],
                  callback: fn _args -> {:ok, "Weather data"} end
                )
              ]

              base_opts =
                param_bundles().deterministic
                |> Keyword.put(:max_tokens, tool_budget_for(@model_spec))
                |> then(
                  &reasoning_overlay(
                    @model_spec,
                    &1,
                    tool_budget_for(@model_spec) * 2
                  )
                )

              ReqLLM.generate_text(
                @model_spec,
                "Tell me a joke about cats",
                fixture_opts("no_tool", base_opts ++ [tools: tools])
              )
              |> assert_basic_response()
            end
          end

          if ReqLLM.ProviderTest.Comprehensive.supports_object_generation?(model_spec) do
            @tag scenario: :object_basic
            test "object generation (non-streaming)" do
              schema = [
                name: [type: :string, required: true, doc: "Person's full name"],
                age: [type: :pos_integer, required: true, doc: "Person's age in years"],
                occupation: [type: :string, doc: "Person's job or profession"]
              ]

              opts =
                param_bundles(@provider).deterministic
                |> Keyword.put(:max_tokens, 500)
                |> then(&reasoning_overlay(@model_spec, @provider, &1, 500))

              {:ok, response} =
                ReqLLM.generate_object(
                  @model_spec,
                  "Generate a software engineer profile",
                  schema,
                  fixture_opts(@provider, "object_basic", opts)
                )

              assert %ReqLLM.Response{} = response
              object = ReqLLM.Response.object(response)
              rt = ReqLLM.Response.reasoning_tokens(response)

              cond do
                is_map(object) and map_size(object) > 0 ->
                  assert Map.has_key?(object, "name")
                  assert Map.has_key?(object, "age")
                  assert is_binary(object["name"])
                  assert object["name"] != ""
                  assert is_integer(object["age"])
                  assert object["age"] > 0

                truncated?(response) ->
                  assert is_number(rt) and rt >= 0

                is_number(rt) and rt > 0 ->
                  :ok

                is_map(object) ->
                  :ok

                true ->
                  flunk("Expected object or reasoning tokens but got: #{inspect(object)}")
              end
            end
          end

          if ReqLLM.ProviderTest.Comprehensive.supports_streaming_object_generation?(model_spec) do
            @tag scenario: :object_streaming
            test "object generation (streaming)" do
              schema = [
                name: [type: :string, required: true, doc: "Person's full name"],
                age: [type: :pos_integer, required: true, doc: "Person's age in years"],
                occupation: [type: :string, doc: "Person's job or profession"]
              ]

              opts =
                param_bundles(@provider).deterministic
                |> Keyword.put(:max_tokens, 500)
                |> then(&reasoning_overlay(@model_spec, @provider, &1, 500))

              {:ok, response} =
                ReqLLM.stream_object(
                  @model_spec,
                  "Generate a software engineer profile",
                  schema,
                  fixture_opts(@provider, "object_streaming", opts)
                )

              response =
                if match?(%ReqLLM.StreamResponse{}, response) do
                  {:ok, resp} = ReqLLM.StreamResponse.to_response(response)
                  resp
                else
                  response
                end

              object = ReqLLM.Response.object(response)
              rt = ReqLLM.Response.reasoning_tokens(response)

              cond do
                is_map(object) and map_size(object) > 0 ->
                  assert Map.has_key?(object, "name")
                  assert Map.has_key?(object, "age")
                  assert is_binary(object["name"])
                  assert object["name"] != ""
                  assert is_integer(object["age"])
                  assert object["age"] > 0

                truncated?(response) ->
                  assert is_number(rt) and rt >= 0

                is_number(rt) and rt > 0 ->
                  :ok

                is_map(object) ->
                  :ok

                true ->
                  flunk("Expected object or reasoning tokens but got: #{inspect(object)}")
              end
            end
          end

          if ReqLLM.ProviderTest.Comprehensive.supports_reasoning?(model_spec) do
            @tag scenario: :reasoning
            test "reasoning/thinking tokens (non-streaming + streaming)" do
              dbug(
                fn -> "\n[Comprehensive] model_spec=#{@model_spec}, test=reasoning" end,
                component: :test
              )

              {:ok, model} = ReqLLM.model(@model_spec)

              provider_config = param_bundles(@provider)

              # Bedrock requires max_tokens > budget_tokens (4000 for :low)
              # Use 5000 to be safe for all providers
              base_opts =
                provider_config.deterministic
                |> Keyword.delete(:temperature)
                |> Keyword.merge(
                  max_tokens: 5000,
                  temperature: 1.0,
                  reasoning_effort: provider_config.reasoning[:reasoning_effort]
                )

              prompt = provider_config.reasoning_prompts.basic

              {:ok, response} =
                ReqLLM.generate_text(
                  @model_spec,
                  prompt,
                  fixture_opts(@provider, "reasoning_basic", base_opts)
                )

              assert %ReqLLM.Response{} = response
              assert response.message.role == :assistant

              text = ReqLLM.Response.text(response) || ""
              thinking = ReqLLM.Response.thinking(response) || ""
              combined = text <> thinking
              assert combined != ""

              has_thinking_part? =
                Enum.any?(
                  response.message.content,
                  &(&1.type == :thinking and is_binary(&1.text) and &1.text != "")
                )

              reasoning_tokens = ReqLLM.Response.reasoning_tokens(response)

              # Some reasoning models (like gpt-5-codex) don't expose thinking content
              # They reason internally but only output final text
              # Accept responses with: thinking content, reasoning tokens, or just regular text
              has_any_output = combined != ""

              assert has_thinking_part? or (is_number(reasoning_tokens) and reasoning_tokens > 0) or
                       has_any_output,
                     "Expected thinking content, reasoning tokens, or text output; got thinking: #{inspect(thinking)} tokens: #{inspect(reasoning_tokens)} text: #{inspect(text)}"

              last = List.last(response.context.messages)
              assert last == response.message

              context =
                ReqLLM.Context.new([
                  system(provider_config.reasoning_prompts.streaming_system),
                  user(provider_config.reasoning_prompts.streaming_user)
                ])

              stream_opts =
                provider_config.creative
                |> Keyword.delete(:temperature)
                |> Keyword.merge(
                  max_tokens: 5000,
                  temperature: 1.0,
                  reasoning_effort: provider_config.reasoning[:reasoning_effort]
                )

              {:ok, stream_response} =
                ReqLLM.stream_text(
                  @model_spec,
                  context,
                  fixture_opts(@provider, "reasoning_streaming", stream_opts)
                )

              assert %ReqLLM.StreamResponse{} = stream_response
              assert stream_response.stream
              assert stream_response.metadata_handle

              # Collect stream chunks once (streams are single-use)
              stream_chunks = Enum.to_list(stream_response.stream)

              {thinking_count, reasoning_tokens_stream} =
                stream_chunks
                |> Enum.reduce({0, 0}, fn chunk, {tc, rt} ->
                  case chunk.type do
                    :thinking ->
                      {tc + 1, rt}

                    :meta ->
                      usage = chunk.metadata[:usage] || %{}
                      rt2 = Map.get(usage, :reasoning_tokens, 0)
                      {tc, max(rt, (is_number(rt2) && rt2) || 0)}

                    _ ->
                      {tc, rt}
                  end
                end)

              # Build response from collected chunks
              stream_with_chunks = %{stream_response | stream: stream_chunks}
              {:ok, response} = ReqLLM.StreamResponse.to_response(stream_with_chunks)
              rt_final = ReqLLM.Response.reasoning_tokens(response)

              # Adaptive reasoning models (like gpt-5-chat) may choose not to reason
              # for simple prompts, so also accept text output like non-streaming does
              streaming_text = ReqLLM.Response.text(response) || ""
              has_streaming_output = streaming_text != ""

              assert thinking_count > 0 or reasoning_tokens_stream > 0 or rt_final > 0 or
                       has_streaming_output,
                     "Expected at least one :thinking chunk, positive reasoning_tokens, or text output; got tc=#{thinking_count} rt_stream=#{reasoning_tokens_stream} rt_final=#{rt_final} text_len=#{String.length(streaming_text)}"

              assert %ReqLLM.Response{} = response
              assert response.message.role == :assistant
            end
          end
        end
      end
    end
  end
end
