defmodule ReqLLM.Providers.OpenAI.StructuredOutputTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Model
  alias ReqLLM.Tool

  describe "provider options validation" do
    test "openai_structured_output_mode accepts valid modes" do
      {:ok, model} = Model.from("openai:gpt-4o-2024-08-06")

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
      {:ok, model} = Model.from("openai:gpt-4o-2024-08-06")

      assert {:error, _} =
               ReqLLM.Providers.OpenAI.prepare_request(
                 :chat,
                 model,
                 "test",
                 provider_options: [openai_structured_output_mode: :invalid_mode]
               )
    end

    test "openai_structured_output_mode defaults to :auto" do
      {:ok, model} = Model.from("openai:gpt-4o-2024-08-06")

      {:ok, request} = ReqLLM.Providers.OpenAI.prepare_request(:chat, model, "test", [])

      provider_opts = request.options[:provider_options] || []
      mode = Keyword.get(provider_opts, :openai_structured_output_mode, :auto)

      assert mode == :auto
    end

    test "openai_parallel_tool_calls accepts boolean or nil" do
      {:ok, model} = Model.from("openai:gpt-4o-2024-08-06")

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
      {:ok, model} = Model.from("openai:gpt-4o-2024-08-06")

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
      {:ok, model} = Model.from("openai:gpt-4o-2024-08-06")

      assert get_in(model._metadata, ["supports_json_schema_response_format"]) == true
    end

    test "supports_json_schema? returns true for gpt-4o-2024-11-20" do
      {:ok, model} = Model.from("openai:gpt-4o-2024-11-20")

      assert get_in(model._metadata, ["supports_json_schema_response_format"]) == true
    end

    test "supports_json_schema? returns true for gpt-4o-mini" do
      {:ok, model} = Model.from("openai:gpt-4o-mini")

      assert get_in(model._metadata, ["supports_json_schema_response_format"]) == true
    end

    test "supports_strict_tools? returns true for gpt-4o-2024-08-06" do
      {:ok, model} = Model.from("openai:gpt-4o-2024-08-06")

      assert get_in(model._metadata, ["supports_strict_tools"]) == true
    end

    test "supports_strict_tools? returns true for older models" do
      {:ok, model} = Model.from("openai:gpt-4")

      assert get_in(model._metadata, ["supports_strict_tools"]) == true
    end
  end

  describe "mode determination logic" do
    test ":auto mode with json_schema-capable model, no tools -> :json_schema" do
      {:ok, model} = Model.from("openai:gpt-4o-2024-08-06")

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
      {:ok, model} = Model.from("openai:gpt-4o-2024-08-06")

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
      {:ok, model} = Model.from("openai:gpt-3.5-turbo")

      opts = [
        provider_options: [openai_structured_output_mode: :auto]
      ]

      mode = determine_output_mode_test_helper(model, opts)

      assert mode == :tool_strict
    end

    test "explicit :json_schema mode overrides auto detection" do
      {:ok, model} = Model.from("openai:gpt-3.5-turbo")

      opts = [
        provider_options: [openai_structured_output_mode: :json_schema]
      ]

      mode = determine_output_mode_test_helper(model, opts)

      assert mode == :json_schema
    end

    test "explicit :tool_strict mode overrides auto detection" do
      {:ok, model} = Model.from("openai:gpt-3.5-turbo")

      opts = [
        provider_options: [openai_structured_output_mode: :tool_strict]
      ]

      mode = determine_output_mode_test_helper(model, opts)

      assert mode == :tool_strict
    end

    test "explicit :tool_strict mode on json_schema-capable model" do
      {:ok, model} = Model.from("openai:gpt-4o-2024-08-06")

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

  defp supports_json_schema?(%Model{} = model) do
    get_in(model, [Access.key(:_metadata, %{}), "supports_json_schema_response_format"]) == true
  end

  defp supports_strict_tools?(%Model{} = model) do
    get_in(model, [Access.key(:_metadata, %{}), "supports_strict_tools"]) == true
  end

  defp has_other_tools?(opts) do
    tools = Keyword.get(opts, :tools, [])
    Enum.any?(tools, fn tool -> tool.name != "structured_output" end)
  end
end
