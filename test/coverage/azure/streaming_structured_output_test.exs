defmodule ReqLLM.Coverage.Azure.StreamingStructuredOutputTest do
  @moduledoc """
  Streaming structured output validation for Azure AI Services.

  Tests streaming object generation with:
  - OpenAI models: native response_format json_schema mode
  - Claude models: tool-based structured output (json_schema not supported on Azure)

  Run with REQ_LLM_FIXTURES_MODE=record to test against live API and record fixtures.
  Otherwise uses fixtures for fast, reliable testing.

  ## Azure-Specific Requirements

  When recording fixtures, ensure these environment variables are set:
  - `AZURE_OPENAI_API_KEY` - Azure API key
  - `AZURE_OPENAI_BASE_URL` - Base URL (e.g., https://your-resource.openai.azure.com/openai)

  Deployment names default to model IDs unless explicitly specified.
  """

  use ExUnit.Case, async: false

  import ExUnit.Case
  import ReqLLM.Test.Helpers

  @moduletag :coverage
  @moduletag provider: "azure"
  @moduletag timeout: 180_000

  @schema [
    name: [type: :string, required: true, doc: "Person's full name"],
    age: [type: :pos_integer, required: true, doc: "Person's age in years"],
    occupation: [type: :string, doc: "Person's job or profession"]
  ]

  @openai_model "azure:gpt-4o"
  @claude_model "azure:claude-3-5-sonnet-20241022"

  setup_all do
    custom = Application.get_env(:llm_db, :custom, %{})
    LLMDB.load(allow: :all, custom: custom)
    :ok
  end

  describe "streaming with auto mode selection" do
    @tag ReqLLM.Test.CompatibilityScenario.tag!(:object_streaming_auto)

    test "auto-selects appropriate mode for OpenAI models (defaults to json_schema)" do
      opts =
        fixture_opts(
          ReqLLM.Test.CompatibilityScenario.fixture!(:object_streaming_auto),
          param_bundles().deterministic
          |> Keyword.put(:max_tokens, 500)
        )

      {:ok, stream_response} =
        ReqLLM.stream_object(
          @openai_model,
          "Generate a software engineer profile",
          @schema,
          opts
        )

      {:ok, response} = ReqLLM.StreamResponse.to_response(stream_response)

      assert %ReqLLM.Response{} = response
      object = ReqLLM.Response.object(response)

      assert is_map(object) and map_size(object) > 0
      assert Map.has_key?(object, "name")
      assert Map.has_key?(object, "age")
    end
  end

  describe "streaming with OpenAI models (json_schema mode)" do
    @tag ReqLLM.Test.CompatibilityScenario.tag!(:object_streaming_json_schema)

    test "streams object with native response_format json_schema" do
      opts =
        fixture_opts(
          ReqLLM.Test.CompatibilityScenario.fixture!(:object_streaming_json_schema),
          param_bundles().deterministic
          |> Keyword.put(:max_tokens, 500)
        )

      {:ok, stream_response} =
        ReqLLM.stream_object(
          @openai_model,
          "Generate a software engineer profile",
          @schema,
          opts
        )

      assert %ReqLLM.StreamResponse{} = stream_response
      assert stream_response.stream
      assert stream_response.metadata_handle

      {:ok, response} = ReqLLM.StreamResponse.to_response(stream_response)

      assert %ReqLLM.Response{} = response
      object = ReqLLM.Response.object(response)

      assert is_map(object) and map_size(object) > 0
      assert Map.has_key?(object, "name")
      assert Map.has_key?(object, "age")
      assert is_binary(object["name"])
      assert object["name"] != ""
      assert is_integer(object["age"])
      assert object["age"] > 0
    end
  end

  describe "streaming with tool_strict mode" do
    @tag ReqLLM.Test.CompatibilityScenario.tag!(:object_streaming_tool_strict)

    test "streams object with strict tool calling" do
      opts =
        fixture_opts(
          ReqLLM.Test.CompatibilityScenario.fixture!(:object_streaming_tool_strict),
          param_bundles().deterministic
          |> Keyword.put(:max_tokens, 500)
          |> Keyword.put(:provider_options, openai_structured_output_mode: :tool_strict)
        )

      {:ok, stream_response} =
        ReqLLM.stream_object(
          @openai_model,
          "Generate a software engineer profile",
          @schema,
          opts
        )

      assert %ReqLLM.StreamResponse{} = stream_response
      assert stream_response.stream
      assert stream_response.metadata_handle

      {:ok, response} = ReqLLM.StreamResponse.to_response(stream_response)

      assert %ReqLLM.Response{} = response
      object = ReqLLM.Response.object(response)

      assert is_map(object) and map_size(object) > 0
      assert Map.has_key?(object, "name")
      assert Map.has_key?(object, "age")
      assert is_binary(object["name"])
      assert object["name"] != ""
      assert is_integer(object["age"])
      assert object["age"] > 0

      tool_calls = ReqLLM.Response.tool_calls(response)
      assert is_list(tool_calls)
      assert Enum.any?(tool_calls, fn tc -> tc.name == "structured_output" end)
    end
  end

  describe "streaming with Claude models (tool-based structured output)" do
    @tag ReqLLM.Test.CompatibilityScenario.tag!(:object_streaming_claude_tool)
    @tag model_family: "anthropic"

    test "streams object using tool calling for Claude (json_schema not supported)" do
      opts =
        fixture_opts(
          ReqLLM.Test.CompatibilityScenario.fixture!(:object_streaming_claude_tool),
          param_bundles().deterministic
          |> Keyword.put(:max_tokens, 500)
        )

      {:ok, stream_response} =
        ReqLLM.stream_object(
          @claude_model,
          "Generate a software engineer profile",
          @schema,
          opts
        )

      assert %ReqLLM.StreamResponse{} = stream_response
      assert stream_response.stream
      assert stream_response.metadata_handle

      {:ok, response} = ReqLLM.StreamResponse.to_response(stream_response)

      assert %ReqLLM.Response{} = response
      object = ReqLLM.Response.object(response)

      assert is_map(object) and map_size(object) > 0
      assert Map.has_key?(object, "name")
      assert Map.has_key?(object, "age")
      assert is_binary(object["name"])
      assert object["name"] != ""
      assert is_integer(object["age"])
      assert object["age"] > 0

      tool_calls = ReqLLM.Response.tool_calls(response)
      assert is_list(tool_calls)
      assert Enum.any?(tool_calls, fn tc -> tc.name == "structured_output" end)
    end
  end

  describe "Claude auto mode selection" do
    @tag ReqLLM.Test.CompatibilityScenario.tag!(:object_streaming_claude_auto)
    @tag model_family: "anthropic"

    test "auto-selects tool mode for Claude models (json_schema unavailable on Azure)" do
      opts =
        fixture_opts(
          ReqLLM.Test.CompatibilityScenario.fixture!(:object_streaming_claude_auto),
          param_bundles().deterministic
          |> Keyword.put(:max_tokens, 500)
        )

      {:ok, stream_response} =
        ReqLLM.stream_object(
          @claude_model,
          "Generate a software engineer profile",
          @schema,
          opts
        )

      {:ok, response} = ReqLLM.StreamResponse.to_response(stream_response)

      assert %ReqLLM.Response{} = response
      object = ReqLLM.Response.object(response)

      assert is_map(object) and map_size(object) > 0
      assert Map.has_key?(object, "name")
      assert Map.has_key?(object, "age")
    end
  end

  describe "error handling in streaming" do
    @tag ReqLLM.Test.CompatibilityScenario.tag!(:streaming_error_handling)

    test "handles truncated stream gracefully" do
      opts =
        fixture_opts(
          ReqLLM.Test.CompatibilityScenario.fixture!(:streaming_error_handling),
          param_bundles().deterministic
          |> Keyword.put(:max_tokens, 10)
        )

      result =
        ReqLLM.stream_object(
          @openai_model,
          "Generate a very detailed software engineer profile with extensive background",
          @schema,
          opts
        )

      case result do
        {:ok, stream_response} ->
          {:ok, response} = ReqLLM.StreamResponse.to_response(stream_response)
          rt = ReqLLM.Response.reasoning_tokens(response)

          if truncated?(response) do
            assert is_number(rt) and rt >= 0
          else
            object = ReqLLM.Response.object(response)
            assert is_map(object) or (is_number(rt) and rt > 0)
          end

        {:error, _error} ->
          :ok
      end
    end
  end
end
