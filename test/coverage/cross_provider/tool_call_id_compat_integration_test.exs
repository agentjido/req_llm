defmodule ReqLLM.Coverage.CrossProvider.ToolCallIdCompatIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :coverage
  @moduletag :integration
  @moduletag timeout: 300_000

  @openai_model System.get_env("REQ_LLM_COMPAT_OPENAI_MODEL") || "openai:gpt-4o"
  @anthropic_model System.get_env("REQ_LLM_COMPAT_ANTHROPIC_MODEL")

  @live_ready ReqLLM.Test.Env.fixtures_mode() == :record and
                is_binary(@openai_model) and @openai_model != "" and
                is_binary(@anthropic_model) and @anthropic_model != ""

  if not @live_ready do
    @moduletag skip:
                 "Run with REQ_LLM_FIXTURES_MODE=record and set REQ_LLM_COMPAT_ANTHROPIC_MODEL"
  end

  setup_all do
    LLMDB.load(allow: :all, custom: %{})
    :ok
  end

  @tag provider: "openai"
  @tag scenario: :tool_id_compat_openai_passthrough
  test "OpenAI request preserves OpenAI-style tool call IDs" do
    fixture_name = "tool_call_id_compat_openai_passthrough"

    {:ok, response} =
      ReqLLM.generate_text(
        @openai_model,
        openai_shaped_context("functions.add:0"),
        ReqLLM.Test.Helpers.fixture_opts(fixture_name, base_opts() ++ [tools: [add_tool()]])
      )

    assert %ReqLLM.Response{} = response

    body = recorded_canonical_json(@openai_model, fixture_name)
    encoded = Jason.encode!(body)

    assert encoded =~ "functions.add:0"
    refute encoded =~ "functions_add_0"
  end

  @tag provider: "anthropic"
  @tag scenario: :tool_id_compat_openai_to_anthropic
  test "Anthropic request sanitizes IDs from OpenAI-shaped context" do
    fixture_name = "tool_call_id_compat_openai_to_anthropic"

    {:ok, response} =
      ReqLLM.generate_text(
        @anthropic_model,
        openai_shaped_context("functions.add:0"),
        ReqLLM.Test.Helpers.fixture_opts(fixture_name, base_opts() ++ [tools: [add_tool()]])
      )

    assert %ReqLLM.Response{} = response

    body = recorded_canonical_json(@anthropic_model, fixture_name)
    encoded = Jason.encode!(body)
    {call_id, result_id} = anthropic_tool_ids(body)

    assert encoded =~ "functions_add_0"
    refute encoded =~ "functions.add:0"
    assert call_id == result_id
  end

  @tag provider: "anthropic"
  @tag scenario: :tool_id_compat_turn_boundary
  test "Anthropic rejects unresolved tool turns" do
    assert_raise ReqLLM.Error.Invalid.Parameter,
                 ~r/Switch providers only after appending tool results/,
                 fn ->
                   ReqLLM.generate_text(
                     @anthropic_model,
                     openai_shaped_unresolved_context("functions.add:0"),
                     ReqLLM.Test.Helpers.fixture_opts(
                       "tool_call_id_compat_anthropic_unresolved",
                       base_opts() ++ [tools: [add_tool()]]
                     )
                   )
                 end
  end

  defp base_opts do
    [temperature: 0.0, max_tokens: 48]
  end

  defp add_tool do
    ReqLLM.Tool.new!(
      name: "add",
      description: "Add two numbers",
      parameter_schema: [
        a: [type: :integer, required: true],
        b: [type: :integer, required: true]
      ],
      callback: fn _args -> {:ok, "3"} end
    )
  end

  defp openai_shaped_context(tool_call_id) do
    ReqLLM.Context.new([
      ReqLLM.Context.user("Use add to sum 1 and 2."),
      ReqLLM.Context.assistant("",
        tool_calls: [
          %{id: tool_call_id, name: "add", arguments: %{"a" => 1, "b" => 2}}
        ]
      ),
      ReqLLM.Context.tool_result(tool_call_id, "add", "3"),
      ReqLLM.Context.user("Reply with OK if the tool result was 3.")
    ])
  end

  defp openai_shaped_unresolved_context(tool_call_id) do
    ReqLLM.Context.new([
      ReqLLM.Context.user("Use add to sum 1 and 2."),
      ReqLLM.Context.assistant("",
        tool_calls: [
          %{id: tool_call_id, name: "add", arguments: %{"a" => 1, "b" => 2}}
        ]
      )
    ])
  end

  defp recorded_canonical_json(model_spec, fixture_name) do
    {:ok, model} = ReqLLM.model(model_spec)
    path = ReqLLM.Test.FixturePath.file(model, fixture_name)
    transcript = ReqLLM.Test.VCR.load!(path)

    Map.get(transcript.request, "canonical_json", %{})
  end

  defp anthropic_tool_ids(body) do
    messages = Map.get(body, "messages", [])

    call_id =
      messages
      |> Enum.find_value(fn
        %{"role" => "assistant", "content" => content} when is_list(content) ->
          content
          |> Enum.find_value(fn
            %{"type" => "tool_use", "id" => id} when is_binary(id) -> id
            _ -> nil
          end)

        _ ->
          nil
      end)

    result_id =
      messages
      |> Enum.find_value(fn
        %{"role" => "user", "content" => content} when is_list(content) ->
          content
          |> Enum.find_value(fn
            %{"type" => "tool_result", "tool_use_id" => id} when is_binary(id) -> id
            _ -> nil
          end)

        _ ->
          nil
      end)

    {call_id, result_id}
  end
end
