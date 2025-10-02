defmodule ReqLLM.ProviderTest.ToolCalling do
  @moduledoc """
  Tool/function calling tests.

  Tests tool calling capabilities:
  - Tool definition and registration
  - Parameter schema validation
  - Tool execution and result handling

  Tests use fixtures for fast, deterministic execution while supporting
  live API recording with REQ_LLM_FIXTURES_MODE=record.

  ## Usage

      defmodule ReqLLM.Coverage.Anthropic.ToolCallingTest do
        use ReqLLM.ProviderTest.ToolCalling, provider: :anthropic
      end

  This will generate tests for all models selected by ModelMatrix for the provider.
  """

  defmacro __using__(opts) do
    provider = Keyword.fetch!(opts, :provider)

    quote bind_quoted: [provider: provider] do
      use ExUnit.Case, async: false

      import ReqLLM.Context
      import ReqLLM.Test.Helpers

      alias ReqLLM.Test.ModelMatrix

      @moduletag :coverage
      @moduletag category: :tool_calling
      @moduletag provider: provider

      defp debug?, do: System.get_env("REQ_LLM_DEBUG") in ["1", "true"]

      @provider provider
      @models ModelMatrix.models_for_provider(provider)

      for model_spec <- @models do
        @model_spec model_spec

        describe "#{model_spec}" do
          test "basic tool calling with get_weather function" do
            require Logger

            model_name =
              @model_spec |> String.split(":") |> List.last() |> String.replace("-", "_")

            fixture_name = "#{model_name}_basic_tool_call"

            if debug?() do
              IO.puts("\n[ToolCallingTest] model_spec=#{@model_spec}, model_name=#{model_name}")
              IO.puts("[ToolCallingTest] fixture_name=#{fixture_name}, provider=#{@provider}")
            end

            Logger.debug("ToolCallingTest: model_spec=#{@model_spec}")
            Logger.debug("ToolCallingTest: fixture_name=#{fixture_name}")

            tools = [
              ReqLLM.tool(
                name: "get_weather",
                description: "Get current weather information for a location",
                parameter_schema: [
                  location: [
                    type: :string,
                    required: true,
                    doc: "The city and state, e.g. San Francisco, CA"
                  ],
                  unit: [
                    type: {:in, ["celsius", "fahrenheit"]},
                    doc: "The temperature unit to use"
                  ]
                ],
                callback: fn _args -> {:ok, "Weather data would go here"} end
              )
            ]

            max_tokens = if @provider == :xai, do: 500, else: 100

            base_opts =
              param_bundles(@provider).deterministic |> Keyword.put(:max_tokens, max_tokens)

            ReqLLM.generate_text(
              @model_spec,
              "What's the weather like in Paris, France?",
              fixture_opts(@provider, fixture_name, base_opts ++ [tools: tools])
            )
            |> assert_basic_response()
            |> assert_tool_call_response("get_weather")
          end

          test "no tool called when query doesn't match" do
            model_name =
              @model_spec |> String.split(":") |> List.last() |> String.replace("-", "_")

            fixture_name = "#{model_name}_no_tool_call"

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

            max_tokens = if @provider == :xai, do: 500, else: 100

            base_opts =
              param_bundles(@provider).deterministic |> Keyword.put(:max_tokens, max_tokens)

            ReqLLM.generate_text(
              @model_spec,
              "Tell me a joke about cats",
              fixture_opts(@provider, fixture_name, base_opts ++ [tools: tools])
            )
            |> assert_basic_response()
            |> assert_no_tool_calls()
          end

          test "multi-tool selection chooses correct tool" do
            model_name =
              @model_spec |> String.split(":") |> List.last() |> String.replace("-", "_")

            fixture_name = "#{model_name}_multi_tool_call"

            tools = [
              ReqLLM.tool(
                name: "get_weather",
                description: "Get current weather information for a location",
                parameter_schema: [
                  location: [type: :string, required: true]
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

            max_tokens = if @provider == :xai, do: 500, else: 100

            base_opts =
              param_bundles(@provider).deterministic |> Keyword.put(:max_tokens, max_tokens)

            ReqLLM.generate_text(
              @model_spec,
              "Tell me a joke about programming",
              fixture_opts(@provider, fixture_name, base_opts ++ [tools: tools])
            )
            |> assert_basic_response()
            |> assert_tool_call_response("tell_joke")
          end
        end
      end

      # Helper for tool call specific assertions
      defp assert_tool_call_response(response, expected_tool_name) do
        # Find tool call in content
        tool_call_content =
          Enum.find(response.message.content, fn content ->
            content.type == :tool_call
          end)

        assert tool_call_content, "Expected to find tool_call in message content"
        assert tool_call_content.tool_name == expected_tool_name
        assert tool_call_content.input
        assert is_map(tool_call_content.input)

        response
      end

      # Helper for asserting no tool calls were made
      defp assert_no_tool_calls(response) do
        tool_calls =
          Enum.filter(response.message.content || [], fn content ->
            content.type == :tool_call
          end)

        assert Enum.empty?(tool_calls),
               "Expected no tool calls, but found: #{inspect(tool_calls)}"

        # Should have regular text content instead
        text = ReqLLM.Response.text(response)
        assert String.length(text) > 0, "Expected text response when no tools called"

        response
      end
    end
  end
end
