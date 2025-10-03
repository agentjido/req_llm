defmodule ReqLLM.ProviderTest.Comprehensive do
  @moduledoc """
  Comprehensive per-model provider tests.

  Consolidates all provider capability testing into up to 8 focused tests per model:
  1. Basic generate_text (non-streaming)
  2. Streaming with system context + creative params
  3. Token limit constraints
  4. Usage metrics and cost calculations
  5. Tool calling - multi-tool selection
  6. Tool calling - no tool when inappropriate
  7. Object generation (streaming) - only for models with :tool_call capability
  8. Reasoning/thinking tokens - only for models with :reasoning capability

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

  defmacro __using__(opts) do
    provider = Keyword.fetch!(opts, :provider)

    quote bind_quoted: [provider: provider] do
      use ExUnit.Case, async: false

      import ExUnit.Case
      import ReqLLM.Context
      import ReqLLM.Test.Helpers

      alias ReqLLM.Test.ModelMatrix

      @moduletag :coverage
      @moduletag provider: to_string(provider)

      defp debug?, do: System.get_env("REQ_LLM_DEBUG") in ["1", "true"]

      @provider provider
      @models ModelMatrix.models_for_provider(provider)

      for model_spec <- @models do
        @model_spec model_spec

        describe "#{model_spec}" do
          @tag category: :core
          test "basic generate_text (non-streaming)" do
            require Logger

            if debug?() do
              IO.puts("\n[Comprehensive] model_spec=#{@model_spec}, test=basic_generate")
            end

            opts =
              reasoning_overlay(
                @model_spec,
                @provider,
                param_bundles(@provider).deterministic,
                200
              )

            ReqLLM.generate_text(
              @model_spec,
              "Hello world!",
              fixture_opts(@provider, "basic", opts)
            )
            |> assert_basic_response()
          end

          @tag category: :streaming
          test "stream_text with system context and creative params" do
            require Logger

            if debug?() do
              IO.puts("\n[Comprehensive] model_spec=#{@model_spec}, test=streaming")
            end

            context =
              ReqLLM.Context.new([
                system("You are a helpful, creative assistant."),
                user("Say hello in one short, imaginative sentence.")
              ])

            opts =
              reasoning_overlay(@model_spec, @provider, param_bundles(@provider).creative, 200)

            {:ok, stream_response} =
              ReqLLM.stream_text(
                @model_spec,
                context,
                fixture_opts(@provider, "streaming", opts)
              )

            assert %ReqLLM.StreamResponse{} = stream_response
            assert stream_response.stream
            assert stream_response.metadata_task

            {:ok, response} = ReqLLM.StreamResponse.to_response(stream_response)

            # Assert response structure without context advancement check
            # (streaming doesn't auto-append to context)
            assert %ReqLLM.Response{} = response

            text = ReqLLM.Response.text(response) || ""
            thinking = ReqLLM.Response.thinking(response) || ""
            combined = text <> thinking

            assert combined != "",
                   "Expected text or thinking content, got empty (text: #{inspect(text)}, thinking: #{inspect(thinking)})"

            assert response.message.role == :assistant
          end

          @tag category: :core
          test "token limit constraints" do
            opts =
              param_bundles(@provider).minimal
              |> Keyword.put(:max_tokens, 100)
              |> then(&reasoning_overlay(@model_spec, @provider, &1, nil))

            ReqLLM.generate_text(
              @model_spec,
              "Write a very long story about dragons and adventures",
              fixture_opts(@provider, "token_limit", opts)
            )
            |> assert_basic_response()
            |> assert_text_length(150)
          end

          @tag category: :usage
          test "usage metrics and cost calculations" do
            require Logger

            if debug?() do
              IO.puts("\n[Comprehensive] model_spec=#{@model_spec}, test=usage")
            end

            max_tokens =
              case ReqLLM.Model.from(@model_spec) do
                {:ok, %{capabilities: %{reasoning: true}}} -> 500
                _ -> 10
              end

            {:ok, response} =
              ReqLLM.generate_text(
                @model_spec,
                "Hi there!",
                fixture_opts(
                  @provider,
                  "usage",
                  Keyword.put(param_bundles(@provider).deterministic, :max_tokens, max_tokens)
                )
              )

            assert %ReqLLM.Response{} = response
            assert ReqLLM.Response.text(response) != ""
            assert is_map(response.usage)

            input_tokens = response.usage[:input_tokens] || response.usage[:input]
            output_tokens = response.usage[:output_tokens] || response.usage[:output]

            assert is_number(input_tokens) and input_tokens > 0
            assert is_number(output_tokens) and output_tokens >= 0

            case ReqLLM.Model.from(@model_spec) do
              {:ok, %ReqLLM.Model{cost: cost_map}} when is_map(cost_map) ->
                assert is_number(response.usage.input_cost) and response.usage.input_cost >= 0

                assert is_number(response.usage.output_cost) and
                         response.usage.output_cost >= 0

                assert is_number(response.usage.total_cost) and response.usage.total_cost >= 0

                expected = response.usage.input_cost + response.usage.output_cost
                assert abs(response.usage.total_cost - expected) < 0.00001

              _ ->
                refute Map.has_key?(response.usage, :input_cost)
            end

            if param_bundles(@provider).validate_cached_tokens do
              cached_tokens = response.usage[:cached_tokens] || 0
              assert is_number(cached_tokens) and cached_tokens >= 0
            end
          end

          @tag category: :tool_calling
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
              param_bundles(@provider).deterministic
              |> Keyword.put(:max_tokens, param_bundles(@provider).tool_test_tokens)
              |> then(
                &reasoning_overlay(
                  @model_spec,
                  @provider,
                  &1,
                  param_bundles(@provider).tool_test_tokens * 2
                )
              )

            result =
              ReqLLM.generate_text(
                @model_spec,
                "What's the weather like in Paris, France?",
                fixture_opts(@provider, "multi_tool", base_opts ++ [tools: tools])
              )

            case result do
              {:ok, response} ->
                assert_basic_response(result)
                assert_has_tool_call(response)

              {:error, _} ->
                flunk("Expected successful response with tool call")
            end
          end

          @tag category: :tool_calling
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
              param_bundles(@provider).deterministic
              |> Keyword.put(:max_tokens, param_bundles(@provider).tool_test_tokens)
              |> then(
                &reasoning_overlay(
                  @model_spec,
                  @provider,
                  &1,
                  param_bundles(@provider).tool_test_tokens * 2
                )
              )

            ReqLLM.generate_text(
              @model_spec,
              "Tell me a joke about cats",
              fixture_opts(@provider, "no_tool", base_opts ++ [tools: tools])
            )
            |> assert_basic_response()
          end

          if :tool_call in ReqLLM.capabilities(model_spec) do
            @tag category: :object_generation
            test "object generation (streaming)" do
              schema = [
                name: [type: :string, required: true, doc: "Person's full name"],
                age: [type: :pos_integer, required: true, doc: "Person's age in years"],
                occupation: [type: :string, doc: "Person's job or profession"]
              ]

              opts =
                param_bundles(@provider).deterministic
                |> Keyword.put(:max_tokens, 200)
                |> then(&reasoning_overlay(@model_spec, @provider, &1, 200))

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

              assert is_map(object)
              assert map_size(object) > 0
              assert Map.has_key?(object, "name")
              assert Map.has_key?(object, "age")
              assert is_binary(object["name"])
              assert object["name"] != ""
              assert is_integer(object["age"])
              assert object["age"] > 0
            end
          end

          if :reasoning in ReqLLM.capabilities(model_spec) do
            @tag category: :reasoning
            test "reasoning/thinking tokens (non-streaming + streaming)" do
              if debug?() do
                IO.puts("\n[Comprehensive] model_spec=#{@model_spec}, test=reasoning")
              end

              provider_config = param_bundles(@provider)

              base_opts =
                provider_config.deterministic
                |> Keyword.delete(:temperature)
                |> Keyword.merge(
                  max_tokens: 2048,
                  temperature: 1.0,
                  provider_options: [reasoning_effort: provider_config.reasoning_effort]
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

              assert has_thinking_part?,
                     "Expected assistant message to include :thinking content parts"

              last = List.last(response.context.messages)
              assert last == response.message
              assert Enum.any?(last.content, &(&1.type == :thinking))

              context =
                ReqLLM.Context.new([
                  system(provider_config.reasoning_prompts.streaming_system),
                  user(provider_config.reasoning_prompts.streaming_user)
                ])

              stream_opts =
                provider_config.creative
                |> Keyword.delete(:temperature)
                |> Keyword.merge(
                  max_tokens: 2048,
                  temperature: 1.0,
                  provider_options: [reasoning_effort: provider_config.reasoning_effort]
                )

              {:ok, stream_response} =
                ReqLLM.stream_text(
                  @model_spec,
                  context,
                  fixture_opts(@provider, "reasoning_streaming", stream_opts)
                )

              assert %ReqLLM.StreamResponse{} = stream_response
              assert stream_response.stream
              assert stream_response.metadata_task

              {thinking_count, _acc_text} =
                stream_response.stream
                |> Enum.reduce({0, ""}, fn chunk, {count, acc} ->
                  case chunk.type do
                    :thinking -> {count + 1, acc <> (chunk.text || "")}
                    _ -> {count, acc}
                  end
                end)

              assert thinking_count > 0, "Expected at least one :thinking stream chunk"

              {:ok, response} = ReqLLM.StreamResponse.to_response(stream_response)
              assert %ReqLLM.Response{} = response
              assert response.message.role == :assistant
            end
          end
        end
      end
    end
  end
end
