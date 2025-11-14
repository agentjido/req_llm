defmodule ReqLLM.Providers.OpenAI.StructuredOutputTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Tool

  describe "provider options validation" do
    test "openai_structured_output_mode accepts valid modes" do
      {:ok, model} = ReqLLM.model("openai:gpt-4o-2024-08-06")

      valid_modes = [:auto, :json_schema, :tool_strict]

      for mode <- valid_modes do
        assert {:ok, _request} =
                 ReqLLM.Providers.OpenAI.prepare_request(
                   :chat,
                   model,
                   "test",
                   provider_options: [openai_structured_output_mode: mode]
                 )
      end
    end

    test "openai_structured_output_mode rejects invalid modes" do
      {:ok, model} = ReqLLM.model("openai:gpt-4o-2024-08-06")

      assert {:error, _} =
               ReqLLM.Providers.OpenAI.prepare_request(
                 :chat,
                 model,
                 "test",
                 provider_options: [openai_structured_output_mode: :invalid_mode]
               )
    end

    test "openai_structured_output_mode defaults to :auto" do
      {:ok, model} = ReqLLM.model("openai:gpt-4o-2024-08-06")

      {:ok, request} = ReqLLM.Providers.OpenAI.prepare_request(:chat, model, "test", [])

      provider_opts = request.options[:provider_options] || []
      mode = Keyword.get(provider_opts, :openai_structured_output_mode, :auto)

      assert mode == :auto
    end

    test "openai_parallel_tool_calls accepts boolean or nil" do
      {:ok, model} = ReqLLM.model("openai:gpt-4o-2024-08-06")

      for value <- [true, false, nil] do
        assert {:ok, _request} =
                 ReqLLM.Providers.OpenAI.prepare_request(
                   :chat,
                   model,
                   "test",
                   provider_options: [openai_parallel_tool_calls: value]
                 )
      end
    end

    test "openai_parallel_tool_calls defaults to nil" do
      {:ok, model} = ReqLLM.model("openai:gpt-4o-2024-08-06")

      {:ok, request} = ReqLLM.Providers.OpenAI.prepare_request(:chat, model, "test", [])

      provider_opts = request.options[:provider_options] || []
      parallel = Keyword.get(provider_opts, :openai_parallel_tool_calls)

      assert parallel == nil
    end
  end

  describe "Tool.strict field serialization" do
    test "tool with strict: false does not include strict in OpenAI format" do
      tool =
        Tool.new!(
          name: "test_tool",
          description: "Test tool",
          parameter_schema: [location: [type: :string, required: true]],
          callback: fn _ -> {:ok, %{}} end
        )

      schema = ReqLLM.Schema.to_openai_format(tool)

      refute Map.has_key?(schema["function"], "strict")
    end

    test "tool with strict: true includes strict in OpenAI format" do
      tool =
        Tool.new!(
          name: "test_tool",
          description: "Test tool",
          parameter_schema: [location: [type: :string, required: true]],
          callback: fn _ -> {:ok, %{}} end
        )

      tool = %{tool | strict: true}
      schema = ReqLLM.Schema.to_openai_format(tool)

      assert schema["function"]["strict"] == true
    end
  end

  describe "capability detection" do
    test "supports_json_schema? returns true for gpt-4o-2024-08-06" do
      {:ok, model} = ReqLLM.model("openai:gpt-4o-2024-08-06")

      assert get_in(model.capabilities, [:json, :schema]) == true
    end

    test "supports_json_schema? returns true for gpt-4o-2024-11-20" do
      {:ok, model} = ReqLLM.model("openai:gpt-4o-2024-11-20")

      assert get_in(model.capabilities, [:json, :schema]) == true
    end

    test "supports_json_schema? returns false for gpt-4o-mini" do
      {:ok, model} = ReqLLM.model("openai:gpt-4o-mini")

      assert get_in(model.capabilities, [:json, :schema]) == false
    end

    test "supports_strict_tools? returns true for gpt-4o-2024-08-06" do
      {:ok, model} = ReqLLM.model("openai:gpt-4o-2024-08-06")

      assert get_in(model.capabilities, [:tools, :strict]) == true
    end

    test "supports_strict_tools? returns false for older models" do
      {:ok, model} = ReqLLM.model("openai:gpt-4")

      refute get_in(model.capabilities, [:tools, :strict])
    end
  end

  describe "mode determination logic" do
    test ":auto mode with json_schema-capable model, no tools -> :json_schema" do
      {:ok, model} = ReqLLM.model("openai:gpt-4o-2024-08-06")

      opts = [
        provider_options: [openai_structured_output_mode: :auto],
        tools: [
          Tool.new!(
            name: "structured_output",
            description: "Schema tool",
            parameter_schema: [field: [type: :string]],
            callback: fn _ -> {:ok, %{}} end
          )
        ]
      ]

      mode = determine_output_mode_test_helper(model, opts)

      assert mode == :json_schema
    end

    test ":auto mode with json_schema-capable model, with other tools -> :tool_strict" do
      {:ok, model} = ReqLLM.model("openai:gpt-4o-2024-08-06")

      opts = [
        provider_options: [openai_structured_output_mode: :auto],
        tools: [
          Tool.new!(
            name: "structured_output",
            description: "Schema tool",
            parameter_schema: [field: [type: :string]],
            callback: fn _ -> {:ok, %{}} end
          ),
          Tool.new!(
            name: "other_tool",
            description: "Other tool",
            parameter_schema: [],
            callback: fn _ -> {:ok, %{}} end
          )
        ]
      ]

      mode = determine_output_mode_test_helper(model, opts)

      assert mode == :tool_strict
    end

    test ":auto mode with old model -> :tool_strict" do
      {:ok, model} = ReqLLM.model("openai:gpt-4")

      opts = [
        provider_options: [openai_structured_output_mode: :auto]
      ]

      mode = determine_output_mode_test_helper(model, opts)

      assert mode == :tool_strict
    end

    test "explicit :json_schema mode overrides auto detection" do
      {:ok, model} = ReqLLM.model("openai:gpt-4")

      opts = [
        provider_options: [openai_structured_output_mode: :json_schema]
      ]

      mode = determine_output_mode_test_helper(model, opts)

      assert mode == :json_schema
    end

    test "explicit :tool_strict mode overrides auto detection" do
      {:ok, model} = ReqLLM.model("openai:gpt-4")

      opts = [
        provider_options: [openai_structured_output_mode: :tool_strict]
      ]

      mode = determine_output_mode_test_helper(model, opts)

      assert mode == :tool_strict
    end

    test "explicit :tool_strict mode on json_schema-capable model" do
      {:ok, model} = ReqLLM.model("openai:gpt-4o-2024-08-06")

      opts = [
        provider_options: [openai_structured_output_mode: :tool_strict]
      ]

      mode = determine_output_mode_test_helper(model, opts)

      assert mode == :tool_strict
    end
  end

  defp determine_output_mode_test_helper(model, opts) do
    provider_opts = Keyword.get(opts, :provider_options, [])
    explicit_mode = Keyword.get(provider_opts, :openai_structured_output_mode, :auto)

    case explicit_mode do
      :auto ->
        cond do
          supports_json_schema?(model) and not has_other_tools?(opts) ->
            :json_schema

          supports_strict_tools?(model) ->
            :tool_strict

          true ->
            :tool_strict
        end

      mode ->
        mode
    end
  end

  defp supports_json_schema?(%LLMDB.Model{} = model) do
    get_in(model.capabilities, [:json, :schema]) == true
  end

  defp supports_strict_tools?(%LLMDB.Model{} = model) do
    get_in(model.capabilities, [:tools, :strict]) == true
  end

  defp has_other_tools?(opts) do
    tools = Keyword.get(opts, :tools, [])
    Enum.any?(tools, fn tool -> tool.name != "structured_output" end)
  end

  describe "map-based parameter schemas (JSON Schema pass-through)" do
    test "tool with map parameter_schema serializes to OpenAI format correctly" do
      json_schema = %{
        "type" => "object",
        "properties" => %{
          "location" => %{"type" => "string", "description" => "City name"},
          "units" => %{"type" => "string", "enum" => ["celsius", "fahrenheit"]}
        },
        "required" => ["location"],
        "additionalProperties" => false
      }

      tool =
        Tool.new!(
          name: "get_weather",
          description: "Get weather information",
          parameter_schema: json_schema,
          callback: fn _ -> {:ok, %{}} end
        )

      schema = ReqLLM.Schema.to_openai_format(tool)

      # Verify the tool format is correct
      assert schema["type"] == "function"
      assert schema["function"]["name"] == "get_weather"
      assert schema["function"]["description"] == "Get weather information"
      # The JSON schema should pass through unchanged
      assert schema["function"]["parameters"] == json_schema
    end

    test "tool with map parameter_schema and strict mode serializes correctly" do
      json_schema = %{
        "type" => "object",
        "properties" => %{
          "query" => %{"type" => "string"}
        },
        "required" => ["query"],
        "additionalProperties" => false
      }

      tool =
        Tool.new!(
          name: "search",
          description: "Search for items",
          parameter_schema: json_schema,
          strict: true,
          callback: fn _ -> {:ok, %{}} end
        )

      schema = ReqLLM.Schema.to_openai_format(tool)

      # Verify strict mode is included
      assert schema["function"]["strict"] == true
      # Verify JSON schema passes through
      assert schema["function"]["parameters"] == json_schema
    end

    test "tool with complex JSON Schema features passes through correctly" do
      complex_schema = %{
        "type" => "object",
        "properties" => %{
          "filter" => %{
            "oneOf" => [
              %{"type" => "string"},
              %{
                "type" => "object",
                "properties" => %{
                  "field" => %{"type" => "string"},
                  "operator" => %{"type" => "string", "enum" => ["eq", "ne", "gt", "lt"]},
                  "value" => %{}
                },
                "required" => ["field", "operator", "value"]
              }
            ]
          },
          "timestamp" => %{
            "type" => "string",
            "format" => "date-time"
          },
          "metadata" => %{
            "type" => "object",
            "additionalProperties" => true
          }
        },
        "required" => ["filter"]
      }

      tool =
        Tool.new!(
          name: "advanced_search",
          description: "Search with complex filters",
          parameter_schema: complex_schema,
          callback: fn _ -> {:ok, []} end
        )

      schema = ReqLLM.Schema.to_openai_format(tool)

      # Complex schema should pass through unchanged
      assert schema["function"]["parameters"] == complex_schema
      # Verify complex features are preserved
      assert schema["function"]["parameters"]["properties"]["filter"]["oneOf"]
      assert schema["function"]["parameters"]["properties"]["timestamp"]["format"] == "date-time"

      assert schema["function"]["parameters"]["properties"]["metadata"]["additionalProperties"] ==
               true
    end

    test "map-based schema works with provider prepare_request pipeline" do
      {:ok, model} = ReqLLM.model("openai:gpt-4o-2024-08-06")

      json_schema = %{
        "type" => "object",
        "properties" => %{
          "city" => %{"type" => "string"}
        },
        "required" => ["city"]
      }

      tool =
        Tool.new!(
          name: "weather_lookup",
          description: "Look up weather",
          parameter_schema: json_schema,
          callback: fn _ -> {:ok, %{}} end
        )

      # Should successfully prepare request with map-based tool
      {:ok, request} =
        ReqLLM.Providers.OpenAI.prepare_request(
          :chat,
          model,
          "What's the weather?",
          tools: [tool]
        )

      assert %Req.Request{} = request
      assert request.options[:tools] == [tool]
    end

    test "equivalent keyword and map schemas produce same OpenAI format" do
      # Keyword schema
      keyword_tool =
        Tool.new!(
          name: "test_kw",
          description: "Test",
          parameter_schema: [
            name: [type: :string, required: true, doc: "Name field"],
            age: [type: :integer, doc: "Age field"]
          ],
          callback: fn _ -> {:ok, %{}} end
        )

      # Equivalent map schema
      map_schema = %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string", "description" => "Name field"},
          "age" => %{"type" => "integer", "description" => "Age field"}
        },
        "required" => ["name"],
        "additionalProperties" => false
      }

      map_tool =
        Tool.new!(
          name: "test_map",
          description: "Test",
          parameter_schema: map_schema,
          callback: fn _ -> {:ok, %{}} end
        )

      kw_schema = ReqLLM.Schema.to_openai_format(keyword_tool)
      map_schema_result = ReqLLM.Schema.to_openai_format(map_tool)

      # Parameters should be equivalent (ignoring tool names)
      assert kw_schema["function"]["parameters"] == map_schema_result["function"]["parameters"]
    end
  end
end
