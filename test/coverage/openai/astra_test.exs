defmodule ReqLLM.Coverage.OpenAI.AstraTest do
  use ExUnit.Case, async: false

  import ReqLLM.Test.Helpers

  alias ReqLLM.Context
  alias ReqLLM.OpenAI.Responses
  alias ReqLLM.Response
  alias ReqLLM.Test.CompatibilityScenario
  alias ReqLLM.Test.WebSocketFixture
  alias ReqLLM.ToolCall

  @moduletag :coverage
  @moduletag provider: "openai"
  @moduletag model: "gpt-6-astra"
  @moduletag timeout: 240_000

  @model "openai:gpt-6-astra"

  unless @model in ReqLLM.Test.ModelMatrix.models_for_provider(:openai) do
    @moduletag skip: "Astra is not selected"
  end

  setup_all do
    LLMDB.load(allow: :all, custom: %{})
    :ok
  end

  @tag CompatibilityScenario.tag!(:astra_async_tools)
  test "async calls remain pending across a turn and accept a delayed result" do
    {:ok, first} = ReqLLM.generate_text(@model, async_prompt(), async_opts(:astra_async_tools, 0))
    call = assert_async_call(first)
    assert {:ok, pending} = Context.append_tool_exchange(first.context, first, [])

    pending =
      Context.append(
        pending,
        Context.user(
          "The report is still running. Reply briefly with what we can do while we wait. Do not call any tools."
        )
      )

    {:ok, second} =
      ReqLLM.generate_text(
        @model,
        pending,
        opts(:astra_async_tools, 1, tools: [report_tool()], tool_choice: :none)
      )

    assert Response.text(second) != ""

    delayed =
      Context.append(
        second.context,
        Context.tool_result(
          call.id,
          "Report 123 is complete. The result code is REPORT_READY_123."
        )
      )

    {:ok, final} =
      ReqLLM.generate_text(
        @model,
        delayed,
        opts(:astra_async_tools, 2, tools: [report_tool()], tool_choice: :none)
      )

    assert Response.text(final) =~ "REPORT_READY_123"

    assert Enum.any?(
             final.context.messages,
             &Enum.any?(&1.tool_calls || [], fn stored ->
               stored.id == call.id and ToolCall.async?(stored)
             end)
           )
  end

  @tag CompatibilityScenario.tag!(:astra_async_streaming)
  test "SSE preserves async call metadata and text in one response" do
    {:ok, stream} =
      ReqLLM.stream_text(@model, async_prompt(), async_opts(:astra_async_streaming, 0))

    assert {:ok, response} = ReqLLM.StreamResponse.to_response(stream)
    call = assert_async_call(response)
    assert {:ok, _pending} = Context.append_tool_exchange(response.context, response, [])
    assert ToolCall.to_map(call).metadata.async
  end

  @tag CompatibilityScenario.tag!(:astra_reasoning_update)
  test "reasoning updates retain history and request effort across follow-ups" do
    cache = [provider_options: [store: false, prompt_cache_options: %{ttl: "30m"}]]

    {:ok, first} =
      ReqLLM.generate_text(
        @model,
        "Suggest one short database migration step.",
        opts(:astra_reasoning_update, 0, cache)
      )

    update =
      Context.user("Give two failure risks and one rollback step. Keep the answer brief.")
      |> Responses.with_reasoning_effort(:high)

    context = Context.append(first.context, update)
    {:ok, second} = ReqLLM.generate_text(@model, context, opts(:astra_reasoning_update, 1, cache))
    assert Response.text(second) != ""
    assert second.provider_meta["reasoning"]["effort"] == "low"

    later =
      Context.append(
        second.context,
        Context.user("Name the most important check in one sentence.")
      )

    {:ok, third} = ReqLLM.generate_text(@model, later, opts(:astra_reasoning_update, 2, cache))
    assert Response.text(third) != ""
    assert third.provider_meta["reasoning"]["effort"] == "low"

    assert Enum.count(third.context.messages, &(&1.metadata[:openai_reasoning_effort] == "high")) ==
             1
  end

  @tag CompatibilityScenario.tag!(:astra_steering)
  test "a steer produces a successor after the original terminal event" do
    WebSocketFixture.run(@model, CompatibilityScenario.fixture!(:astra_steering), fn connection ->
      WebSocketFixture.create(connection, %{
        "input" =>
          "Write a numbered plan with 60 concise one-sentence steps for building a small task tracking application.",
        "reasoning" => %{"effort" => "low"},
        "max_output_tokens" => 5_000,
        "store" => false
      })

      initial = wait_created(connection)

      WebSocketFixture.steer(
        connection,
        initial,
        "Reduce the plan to exactly five concise steps."
      )

      events = WebSocketFixture.until(connection, &successor_completed?(&1, initial))
      assert_accepted(events, initial)
      assert Enum.any?(events, &terminal_for?(&1, initial))
      final = List.last(events)["response"]
      assert final["id"] != initial
      assert final["status"] == "completed"
      assert length(Regex.scan(~r/^\d+\.\s/m, output_text(final))) == 5
    end)
  end

  @tag CompatibilityScenario.tag!(:astra_steering_pending)
  test "a pending steer accepts tool results on the same session" do
    WebSocketFixture.run(
      @model,
      CompatibilityScenario.fixture!(:astra_steering_pending),
      fn connection ->
        settings = %{
          "instructions" =>
            "Use lookup_report when asked to check a report. When a result is available, include its result code.",
          "tools" => [
            %{
              "type" => "function",
              "name" => "lookup_report",
              "description" => "Get a project report",
              "parameters" => %{
                "type" => "object",
                "properties" => %{"report_id" => %{"type" => "string"}},
                "required" => ["report_id"],
                "additionalProperties" => false
              }
            }
          ],
          "reasoning" => %{"effort" => "low"},
          "max_output_tokens" => 2_000,
          "store" => false
        }

        WebSocketFixture.create(
          connection,
          Map.merge(settings, %{
            "input" => "Call lookup_report for report 123 before answering.",
            "tool_choice" => %{"type" => "function", "name" => "lookup_report"}
          })
        )

        initial = wait_created(connection)

        WebSocketFixture.steer(
          connection,
          initial,
          "Keep the final report summary to one sentence."
        )

        events = WebSocketFixture.until(connection, &(&1["type"] == "response.steer.pending"))
        accepted = assert_accepted(events, initial)
        pending = List.last(events)
        assert pending["steer"]["id"] == accepted["steer"]["id"]
        assert pending["steer"]["previous_response_id"] == initial

        assert [%{"type" => "function_call_output", "call_id" => call_id}] =
                 pending["required_input"]

        WebSocketFixture.create(
          connection,
          Map.merge(settings, %{
            "previous_response_id" => initial,
            "tool_choice" => "none",
            "input" => [
              %{
                "type" => "function_call_output",
                "call_id" => call_id,
                "output" => "Report 123 is complete. Result code REPORT_READY_123."
              }
            ]
          })
        )

        continuation = WebSocketFixture.until(connection, &successor_completed?(&1, initial))
        assert output_text(List.last(continuation)["response"]) =~ "REPORT_READY_123"
      end
    )
  end

  defp opts(scenario, index, extra) do
    common = [
      reasoning_effort: :low,
      max_tokens: 1_024,
      max_retries: 0,
      receive_timeout: 120_000,
      provider_options: [store: false]
    ]

    fixture_opts(CompatibilityScenario.fixture!(scenario, index), Keyword.merge(common, extra))
  end

  defp async_opts(scenario, index) do
    opts(scenario, index,
      tools: [report_tool()],
      tool_choice: %{type: "tool", name: "lookup_report"}
    )
  end

  defp async_prompt do
    "Call lookup_report for report 123. Also tell me that the lookup started. When its result arrives, include the result code."
  end

  defp report_tool do
    ReqLLM.Tool.new!(
      name: "lookup_report",
      description: "Get a short project report by its ID",
      parameter_schema: [report_id: [type: :string, required: true]],
      callback: fn _ -> {:ok, "unused"} end,
      provider_options: [openai: [async: true]]
    )
  end

  defp assert_async_call(response) do
    assert [call] = response.message.tool_calls
    assert ToolCall.async?(call)
    assert ToolCall.name(call) == "lookup_report"
    assert ToolCall.args_map(call) == %{"report_id" => "123"}
    assert Response.text(response) != ""
    call
  end

  defp wait_created(connection) do
    connection
    |> WebSocketFixture.until(&(&1["type"] == "response.created"))
    |> List.last()
    |> get_in(["response", "id"])
  end

  defp successor_completed?(event, initial) do
    event["type"] == "response.completed" and event["response"]["id"] != initial
  end

  defp terminal_for?(event, id) do
    event["type"] in ["response.completed", "response.incomplete"] and
      event["response"]["id"] == id
  end

  defp assert_accepted(events, id) do
    accepted = Enum.find(events, &(&1["type"] == "response.steer.accepted"))
    assert accepted
    assert accepted["steer"]["previous_response_id"] == id
    assert is_binary(accepted["steer"]["id"])
    accepted
  end

  defp output_text(response) do
    response["output"]
    |> Enum.flat_map(&(&1["content"] || []))
    |> Enum.map_join(&(&1["text"] || ""))
  end
end
