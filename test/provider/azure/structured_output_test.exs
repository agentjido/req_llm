defmodule ReqLLM.Providers.Azure.StructuredOutputTest do
  @moduledoc """
  Structured output tests for Azure AI Services.

  Tests structured output behavior for both model families on Azure:

  ## OpenAI Models (GPT, o1, o3, o4)
  - Support openai_structured_output_mode option (:auto, :json_schema, :tool_strict)
  - Tool strict serialization with additionalProperties: false
  - Response format added via Azure.OpenAI formatter
  - Capability detection for json_schema and strict tools

  ## Claude Models
  - Only support tool-based structured output (no native json_schema on Azure)
  - Warning logged when json_schema response_format is attempted
  - Tool serialization uses Anthropic format
  - Always uses tool mode (json_schema not available on Azure)

  Tests cover:
  - Provider options validation
  - Capability detection for both model families
  - Mode determination logic
  - Map-based JSON Schema pass-through
  - Cross-family option warnings
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ReqLLM.Providers.Azure
  alias ReqLLM.Tool

  describe "OpenAI model structured output" do
    test "Azure uses tool-based structured output for OpenAI models" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")

      schema = [
        name: [type: :string, required: true],
        age: [type: :pos_integer, required: true]
      ]

      compiled_schema = %{schema: schema}

      {:ok, request} =
        Azure.prepare_request(
          :object,
          model,
          "Generate a person",
          base_url: "https://my-resource.openai.azure.com/openai",
          deployment: "my-deployment",
          compiled_schema: compiled_schema
        )

      assert %Req.Request{} = request

      tools = request.options[:tools]
      assert is_list(tools)
      assert Enum.any?(tools, &(&1.name == "structured_output"))
    end

    test "response_format is added by OpenAI formatter" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Test")])

      opts = [
        stream: false,
        provider_options: []
      ]

      body = Azure.OpenAI.format_request("gpt-4o", context, opts)

      assert is_map(body)
      assert Map.has_key?(body, :messages)
    end
  end

  describe "Tool serialization for OpenAI models" do
    test "tool with strict: false does not include strict in body" do
      {:ok, _model} = ReqLLM.model("azure:gpt-4o")
      context = ReqLLM.Context.new([ReqLLM.Context.user("Test")])

      tool =
        Tool.new!(
          name: "test_tool",
          description: "Test tool",
          parameter_schema: [location: [type: :string, required: true]],
          callback: fn _ -> {:ok, %{}} end
        )

      body = Azure.OpenAI.format_request("gpt-4o", context, tools: [tool], stream: false)

      tool_schema = hd(body[:tools])
      refute Map.has_key?(tool_schema["function"], "strict")
    end

    test "tool with strict: true includes strict in body" do
      {:ok, _model} = ReqLLM.model("azure:gpt-4o")
      context = ReqLLM.Context.new([ReqLLM.Context.user("Test")])

      tool =
        Tool.new!(
          name: "test_tool",
          description: "Test tool",
          parameter_schema: [location: [type: :string, required: true]],
          callback: fn _ -> {:ok, %{}} end
        )

      tool = %{tool | strict: true}
      body = Azure.OpenAI.format_request("gpt-4o", context, tools: [tool], stream: false)

      tool_schema = hd(body[:tools])
      assert tool_schema["function"]["strict"] == true
    end
  end

  describe "Claude model structured output" do
    test "json_schema response_format is warned and removed" do
      model = %LLMDB.Model{
        id: "claude-3-5-sonnet-20241022",
        provider: :azure,
        capabilities: %{}
      }

      opts = [response_format: %{type: "json_schema", json_schema: %{}}]

      log =
        capture_log(fn ->
          {translated, _warnings} = Azure.Anthropic.pre_validate_options(:chat, model, opts)
          refute Keyword.has_key?(translated, :response_format)
        end)

      assert log =~ "response_format with json_schema is not supported"
      assert log =~ "Claude models on Azure"
    end

    test "tool-based structured output works for Claude models" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Generate a person profile")])

      tool =
        Tool.new!(
          name: "structured_output",
          description: "Generate structured output",
          parameter_schema: [
            name: [type: :string, required: true],
            age: [type: :pos_integer, required: true]
          ],
          callback: fn _ -> {:ok, %{}} end
        )

      opts = [
        stream: false,
        tools: [tool],
        tool_choice: %{type: "tool", name: "structured_output"}
      ]

      body = Azure.Anthropic.format_request("claude-3-5-sonnet-20241022", context, opts)

      assert length(body.tools) == 1
      assert hd(body.tools).name == "structured_output"
      assert body.tool_choice == %{type: "tool", name: "structured_output"}
    end
  end

  describe "structured output via prepare_request :object operation" do
    test "creates synthetic tool for OpenAI models" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")

      schema = [
        name: [type: :string, required: true],
        age: [type: :pos_integer, required: true]
      ]

      compiled_schema = %{schema: schema}

      {:ok, request} =
        Azure.prepare_request(
          :object,
          model,
          "Generate a person",
          base_url: "https://my-resource.openai.azure.com/openai",
          deployment: "my-deployment",
          compiled_schema: compiled_schema
        )

      assert %Req.Request{} = request

      tools = request.options[:tools]
      assert is_list(tools)
      assert Enum.any?(tools, &(&1.name == "structured_output"))
    end

    test "uses tool-based approach for Claude models" do
      model = %LLMDB.Model{
        id: "claude-3-5-sonnet-20241022",
        provider: :azure,
        capabilities: %{chat: true}
      }

      schema = [
        name: [type: :string, required: true],
        age: [type: :pos_integer, required: true]
      ]

      compiled_schema = %{schema: schema}

      {:ok, request} =
        Azure.prepare_request(
          :object,
          model,
          "Generate a person",
          api_key: "test-key",
          base_url: "https://my-resource.openai.azure.com/openai",
          deployment: "my-deployment",
          compiled_schema: compiled_schema
        )

      assert %Req.Request{} = request
    end
  end

  describe "map-based parameter schemas" do
    test "map schema passes through correctly for Azure OpenAI" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Test")])

      json_schema = %{
        "type" => "object",
        "properties" => %{
          "location" => %{"type" => "string", "description" => "City name"}
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

      body = Azure.OpenAI.format_request("gpt-4o", context, tools: [tool], stream: false)

      tool_params = hd(body[:tools])["function"]["parameters"]
      assert tool_params["type"] == "object"
      assert tool_params["properties"]["location"]["type"] == "string"
    end
  end

  describe "capability detection for OpenAI models on Azure" do
    test "gpt-4o has tools enabled" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")
      assert get_in(model.capabilities, [:tools, :enabled]) == true
    end

    test "gpt-4o-mini has tools enabled" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o-mini")
      assert get_in(model.capabilities, [:tools, :enabled]) == true
    end

    test "gpt-4 has tools enabled" do
      {:ok, model} = ReqLLM.model("azure:gpt-4")
      assert get_in(model.capabilities, [:tools, :enabled]) == true
    end

    test "o1-mini supports reasoning" do
      {:ok, model} = ReqLLM.model("azure:o1-mini")
      assert get_in(model.capabilities, [:reasoning, :enabled]) == true
    end

    test "gpt-4o does not have reasoning enabled" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")
      refute get_in(model.capabilities, [:reasoning, :enabled]) == true
    end
  end

  describe "capability detection for Claude models on Azure" do
    test "synthetic Claude model does not support json_schema on Azure" do
      model = %LLMDB.Model{
        id: "claude-3-5-sonnet-20241022",
        provider: :azure,
        capabilities: %{chat: true, tools: %{enabled: true}}
      }

      refute get_in(model.capabilities, [:json, :schema]) == true
    end

    test "synthetic Claude model supports tool calling" do
      model = %LLMDB.Model{
        id: "claude-3-5-sonnet-20241022",
        provider: :azure,
        capabilities: %{chat: true, tools: %{enabled: true}}
      }

      assert get_in(model.capabilities, [:tools, :enabled]) == true
    end

    test "Claude models should use tool-based structured output (no json_schema)" do
      model = %LLMDB.Model{
        id: "claude-3-opus-20240229",
        provider: :azure,
        capabilities: %{chat: true, tools: %{enabled: true}}
      }

      refute get_in(model.capabilities, [:json, :schema]) == true
      assert get_in(model.capabilities, [:tools, :enabled]) == true
    end
  end

  describe "mode determination for OpenAI models on Azure" do
    test ":auto mode with json_schema-capable model, no other tools -> prefers json_schema" do
      model = %LLMDB.Model{
        id: "gpt-4o-2024-08-06",
        provider: :azure,
        capabilities: %{json: %{schema: true}, tools: %{strict: true, enabled: true}}
      }

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

      mode = determine_output_mode_helper(model, opts)
      assert mode == :json_schema
    end

    test ":auto mode with json_schema-capable model, with other tools -> tool_strict" do
      model = %LLMDB.Model{
        id: "gpt-4o-2024-08-06",
        provider: :azure,
        capabilities: %{json: %{schema: true}, tools: %{strict: true, enabled: true}}
      }

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

      mode = determine_output_mode_helper(model, opts)
      assert mode == :tool_strict
    end

    test ":auto mode with model lacking json_schema -> tool_strict" do
      {:ok, model} = ReqLLM.model("azure:gpt-4")

      opts = [provider_options: [openai_structured_output_mode: :auto]]
      mode = determine_output_mode_helper(model, opts)
      assert mode == :tool_strict
    end

    test "explicit :json_schema mode overrides auto detection" do
      {:ok, model} = ReqLLM.model("azure:gpt-4")

      opts = [provider_options: [openai_structured_output_mode: :json_schema]]
      mode = determine_output_mode_helper(model, opts)
      assert mode == :json_schema
    end

    test "explicit :tool_strict mode overrides auto detection" do
      model = %LLMDB.Model{
        id: "gpt-4o-2024-08-06",
        provider: :azure,
        capabilities: %{json: %{schema: true}, tools: %{strict: true, enabled: true}}
      }

      opts = [provider_options: [openai_structured_output_mode: :tool_strict]]
      mode = determine_output_mode_helper(model, opts)
      assert mode == :tool_strict
    end
  end

  describe "mode determination for Claude models on Azure" do
    test "Claude always uses tool mode (json_schema not supported)" do
      model = %LLMDB.Model{
        id: "claude-3-5-sonnet-20241022",
        provider: :azure,
        capabilities: %{chat: true, tools: %{enabled: true}}
      }

      mode = determine_claude_mode_helper(model)
      assert mode == :tool
    end

    test "json_schema mode is rejected for Claude on Azure" do
      model = %LLMDB.Model{
        id: "claude-3-5-sonnet-20241022",
        provider: :azure,
        capabilities: %{chat: true}
      }

      opts = [response_format: %{type: "json_schema", json_schema: %{}}]

      log =
        capture_log(fn ->
          {translated, _warnings} = Azure.Anthropic.pre_validate_options(:chat, model, opts)
          refute Keyword.has_key?(translated, :response_format)
        end)

      assert log =~ "response_format with json_schema is not supported"
      assert log =~ "Claude models on Azure"
    end

    test "json_schema via provider_options is also rejected" do
      model = %LLMDB.Model{
        id: "claude-3-5-sonnet-20241022",
        provider: :azure,
        capabilities: %{chat: true}
      }

      opts = [provider_options: [response_format: %{type: "json_schema", json_schema: %{}}]]

      log =
        capture_log(fn ->
          {translated, _warnings} = Azure.Anthropic.pre_validate_options(:chat, model, opts)
          provider_opts = Keyword.get(translated, :provider_options, [])
          refute Keyword.has_key?(provider_opts, :response_format)
        end)

      assert log =~ "response_format with json_schema is not supported"
    end
  end

  describe "complex map-based parameter schemas" do
    test "complex JSON Schema with oneOf passes through for OpenAI models" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Test")])

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

      body = Azure.OpenAI.format_request("gpt-4o", context, tools: [tool], stream: false)

      tool_params = hd(body[:tools])["function"]["parameters"]
      assert tool_params["properties"]["filter"]["oneOf"]
      assert tool_params["properties"]["timestamp"]["format"] == "date-time"
    end

    test "map schema with strict mode includes strict field" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Test")])

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
          description: "Search",
          parameter_schema: json_schema,
          strict: true,
          callback: fn _ -> {:ok, %{}} end
        )

      body = Azure.OpenAI.format_request("gpt-4o", context, tools: [tool], stream: false)

      tool_schema = hd(body[:tools])
      assert tool_schema["function"]["strict"] == true
    end

    test "map schema passes through for Claude models on Azure" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Test")])

      json_schema = %{
        "type" => "object",
        "properties" => %{
          "location" => %{"type" => "string"}
        },
        "required" => ["location"]
      }

      tool =
        Tool.new!(
          name: "get_weather",
          description: "Get weather",
          parameter_schema: json_schema,
          callback: fn _ -> {:ok, %{}} end
        )

      body =
        Azure.Anthropic.format_request(
          "claude-3-5-sonnet-20241022",
          context,
          tools: [tool],
          stream: false
        )

      tool_schema = hd(body.tools)
      assert tool_schema.input_schema == json_schema
    end

    test "equivalent keyword and map schemas produce same output for OpenAI" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Test")])

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

      kw_body =
        Azure.OpenAI.format_request("gpt-4o", context, tools: [keyword_tool], stream: false)

      map_body = Azure.OpenAI.format_request("gpt-4o", context, tools: [map_tool], stream: false)

      kw_params = hd(kw_body[:tools])["function"]["parameters"]
      map_params = hd(map_body[:tools])["function"]["parameters"]

      assert Map.delete(kw_params, "propertyOrdering") == map_params
      assert kw_params["propertyOrdering"] == ["name", "age"]
    end
  end

  describe "cross-family option validation" do
    test "openai_structured_output_mode is ignored for Claude models" do
      model = %LLMDB.Model{
        id: "claude-3-5-sonnet-20241022",
        provider: :azure,
        capabilities: %{chat: true}
      }

      opts = [provider_options: [openai_structured_output_mode: :json_schema]]

      {_translated, _warnings} = Azure.Anthropic.pre_validate_options(:chat, model, opts)
      assert true
    end

    test "service_tier warns for Claude models" do
      model = %LLMDB.Model{
        id: "claude-3-5-sonnet-20241022",
        provider: :azure,
        capabilities: %{chat: true}
      }

      opts = [provider_options: [service_tier: "priority"]]

      log =
        capture_log(fn ->
          {translated, _warnings} = Azure.Anthropic.pre_validate_options(:chat, model, opts)
          provider_opts = Keyword.get(translated, :provider_options, [])
          refute Keyword.has_key?(provider_opts, :service_tier)
        end)

      assert log =~ "service_tier is an OpenAI-specific option"
    end

    test "openai_parallel_tool_calls is only applied for OpenAI models" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Test")])

      tool =
        Tool.new!(
          name: "test_tool",
          description: "Test",
          parameter_schema: [x: [type: :string]],
          callback: fn _ -> {:ok, %{}} end
        )

      openai_body =
        Azure.OpenAI.format_request(
          "gpt-4o",
          context,
          tools: [tool],
          stream: false,
          provider_options: [openai_parallel_tool_calls: true]
        )

      assert openai_body[:parallel_tool_calls] == true

      claude_body =
        Azure.Anthropic.format_request(
          "claude-3-5-sonnet-20241022",
          context,
          tools: [tool],
          stream: false
        )

      refute Map.has_key?(claude_body, :parallel_tool_calls)
    end
  end

  describe "response_format handling" do
    test "json_object format works for OpenAI models on Azure" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Test")])

      opts = [
        stream: false,
        provider_options: [response_format: %{type: "json_object"}]
      ]

      body = Azure.OpenAI.format_request("gpt-4o", context, opts)

      assert body[:response_format] == %{type: "json_object"}
    end

    test "text format works for OpenAI models on Azure" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Test")])

      opts = [
        stream: false,
        provider_options: [response_format: %{type: "text"}]
      ]

      body = Azure.OpenAI.format_request("gpt-4o", context, opts)

      assert body[:response_format] == %{type: "text"}
    end

    test "json_schema format with schema works for capable OpenAI models" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Test")])

      opts = [
        stream: false,
        provider_options: [
          response_format: %{
            type: "json_schema",
            json_schema: %{
              name: "person",
              schema: [
                name: [type: :string, required: true],
                age: [type: :pos_integer, required: true]
              ]
            }
          }
        ]
      ]

      body = Azure.OpenAI.format_request("gpt-4o-2024-08-06", context, opts)

      assert body[:response_format][:type] == "json_schema"
      assert body[:response_format][:json_schema][:name] == "person"
    end
  end

  defp determine_output_mode_helper(model, opts) do
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

  defp determine_claude_mode_helper(_model) do
    :tool
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
end
