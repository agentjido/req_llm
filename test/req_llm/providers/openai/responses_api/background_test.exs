defmodule ReqLLM.OpenAI.Responses.BackgroundTest do
  use ExUnit.Case, async: true

  alias ReqLLM.{Context, Error, Response, Tool, ToolCall}
  alias ReqLLM.OpenAI.Responses.Background

  @fixtures Path.expand("../../../../support/fixtures/openai/background/responses.json", __DIR__)
  @model "openai:gpt-6.1-terra"
  @opts [
    api_key: "test-project-key",
    req_http_options: [
      plug: {Req.Test, __MODULE__},
      headers: [{"openai-project", "proj_background"}]
    ]
  ]
  @background_opts [completion_window: "8h", continuation_id: "review-doc1"]

  setup do
    %{fixture: @fixtures |> File.read!() |> Jason.decode!()}
  end

  test "submits, resumes from a saved ID and sends the resulting tool output", %{fixture: fixture} do
    tool =
      Tool.new!(
        name: "lookup",
        description: "Fetch a document",
        parameter_schema: [id: [type: :string, required: true]],
        callback: fn _ -> flunk("the client must leave local tool execution to the caller") end
      )

    Req.Test.expect(__MODULE__, fn conn ->
      conn = assert_request(conn, "POST", "/v1/responses")
      {body, conn} = request_body(conn)

      assert %{
               "background" => true,
               "stream" => false,
               "store" => false,
               "service_tier" => "default",
               "model" => "gpt-6.1-terra",
               "background_options" => %{
                 "completion_window" => "8h",
                 "continuation_id" => "review-doc1"
               },
               "tools" => [%{"name" => "lookup", "type" => "function"}]
             } = body

      assert Enum.any?(body["input"], fn item -> item["role"] == "user" end)
      Req.Test.json(conn, fixture["queued"])
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      conn = assert_request(conn, "GET", "/v1/responses/resp_lookup")

      assert URI.query_decoder(conn.query_string) |> Enum.to_list() ==
               [{"include[]", "reasoning.encrypted_content"}]

      Req.Test.json(conn, fixture["completed"])
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      conn = assert_request(conn, "POST", "/v1/responses")
      {body, conn} = request_body(conn)

      assert %{
               "previous_response_id" => "resp_lookup",
               "store" => false,
               "background_options" => %{
                 "completion_window" => "8h",
                 "continuation_id" => "review-doc1"
               },
               "input" => [
                 %{
                   "type" => "function_call_output",
                   "call_id" => "call_lookup",
                   "output" => "Signed document"
                 }
               ]
             } = body

      Req.Test.json(conn, fixture["follow_up"])
    end)

    prompt = Context.new([Context.system("Check approvals."), Context.user("Review doc1.")])
    submit_opts = @opts ++ [tools: [tool], background_options: @background_opts]

    assert {:ok,
            %Response{
              id: id,
              usage: nil,
              finish_reason: nil,
              provider_meta: %{"status" => "queued"}
            }} =
             Background.submit(@model, prompt, submit_opts)

    saved = Jason.encode!(%{id: id, completion_window: "8h"})
    caller = self()

    result =
      Task.async(fn ->
        Req.Test.allow(__MODULE__, caller, self())
        %{"id" => id, "completion_window" => window} = Jason.decode!(saved)

        Background.retrieve(
          id,
          @opts ++ [completion_window: window, include: ["reasoning.encrypted_content"]]
        )
      end)

    assert {:ok, %Response{finish_reason: :tool_calls} = completed} = Task.await(result)
    assert completed.provider_meta["status"] == "completed"
    assert completed.provider_meta["output"] == fixture["completed"]["output"]
    assert completed.provider_meta["usage"] == fixture["completed"]["usage"]
    assert [%ToolCall{id: "call_lookup"} = call] = Response.tool_calls(completed)
    assert ToolCall.name(call) == "lookup"

    assert %{input_tokens: 100, output_tokens: 20, reasoning_tokens: 5} =
             Response.usage(completed)

    assert_in_delta completed.usage.total_cost, 0.00012, 1.0e-10

    output = Context.tool_result(call.id, "Signed document")

    assert {:ok, %Response{id: "resp_follow_up", provider_meta: %{"status" => "in_progress"}}} =
             Background.submit(
               @model,
               output,
               submit_opts ++ [previous_response_id: completed.id]
             )
  end

  test "preserves the provider's terminal status and details", %{fixture: fixture} do
    Req.Test.expect(__MODULE__, fn conn ->
      conn = assert_request(conn, "POST", "/v1/responses/resp_lookup/cancel")
      assert {"", _conn} = request_body(conn, :raw)
      Req.Test.json(conn, fixture["cancelled"])
    end)

    for status <- ["failed", "incomplete"] do
      Req.Test.expect(__MODULE__, fn conn ->
        conn = assert_request(conn, "GET", "/v1/responses/resp_#{status}")
        Req.Test.json(conn, fixture[status])
      end)
    end

    assert {:ok, %Response{finish_reason: :cancelled, provider_meta: %{"status" => "cancelled"}}} =
             Background.cancel("resp_lookup", @opts)

    assert {:ok,
            %Response{
              finish_reason: :error,
              error: detail,
              provider_meta: %{"status" => "failed"}
            }} =
             Background.retrieve("resp_failed", @opts)

    assert detail == fixture["failed"]["error"]

    assert {:ok,
            %Response{provider_meta: %{"status" => "incomplete", "incomplete_details" => details}} =
              incomplete} =
             Background.retrieve("resp_incomplete", @opts)

    assert details == %{"reason" => "max_output_tokens"}
    assert Response.text(incomplete) == "Partial answer"
    assert %{output_tokens: 20, pricing: %{status: :unknown}} = incomplete.usage
    refute Map.has_key?(incomplete.usage, :total_cost)
  end

  test "defaults to soonest and allows explicit storage", %{fixture: fixture} do
    Req.Test.expect(__MODULE__, fn conn ->
      conn = assert_request(conn, "POST", "/v1/responses")
      {body, conn} = request_body(conn)
      assert body["background_options"] == %{"completion_window" => "soonest"}
      assert body["store"] == true
      refute Map.has_key?(body, "service_tier")
      Req.Test.json(conn, fixture["queued"])
    end)

    assert {:ok, %Response{}} =
             Background.submit(@model, "Check approvals.", @opts ++ [store: true])
  end

  test "validates nonstreaming Standard requests and preserves service eligibility errors", %{
    fixture: fixture
  } do
    opts = @opts ++ [background_options: [completion_window: "2h"]]

    assert {:error,
            %Error.Invalid.Parameter{parameter: "background responses use nonstreaming HTTP"}} =
             Background.submit(@model, "Review docs.", opts ++ [stream?: true])

    assert {:error, %Error.Invalid.Parameter{parameter: reason}} =
             Background.submit(
               @model,
               "Review docs.",
               opts ++ [provider_options: [service_tier: "flex"]]
             )

    assert reason =~ "requires service_tier"

    Req.Test.expect(__MODULE__, fn conn ->
      conn = assert_request(conn, "POST", "/v1/responses")
      {body, conn} = request_body(conn)
      assert %{"completion_window" => "2h"} = body["background_options"]
      assert body["service_tier"] == "default"
      conn |> Plug.Conn.put_status(400) |> Req.Test.json(fixture["discounted_window_rejected"])
    end)

    model = %{provider: :openai, id: "example-model"}

    assert {:error, %Error.API.Request{status: 400, response_body: rejection}} =
             Background.submit(model, "Review docs.", opts)

    assert rejection == fixture["discounted_window_rejected"]
  end

  test "keeps usage when a discounted tariff cannot be resolved", %{fixture: fixture} do
    Req.Test.expect(__MODULE__, fn conn ->
      conn = assert_request(conn, "GET", "/v1/responses/resp_lookup")
      payload = Map.put(fixture["completed"], "model", "unknown-model")
      Req.Test.json(conn, payload)
    end)

    assert {:ok, %Response{usage: usage}} =
             Background.retrieve("resp_lookup", @opts ++ [completion_window: "2h"])

    assert %{input_tokens: 100, output_tokens: 20, pricing: %{status: :unknown}} = usage
    refute Map.has_key?(usage, :total_cost)
  end

  test "does not resubmit when a create response is lost" do
    Req.Test.expect(__MODULE__, fn conn ->
      conn = assert_request(conn, "POST", "/v1/responses")
      Req.Test.transport_error(conn, :closed)
    end)

    assert {:error, %Error.API.Request{cause: %Req.TransportError{reason: :closed}}} =
             Background.submit(@model, "Review docs.", @opts)
  end

  defp request_body(conn, format \\ :json) do
    assert {:ok, body, conn} = Plug.Conn.read_body(conn)
    {if(format == :json, do: Jason.decode!(body), else: body), conn}
  end

  defp assert_request(conn, method, path) do
    assert conn.method == method
    assert conn.request_path == path
    assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-project-key"]
    assert Plug.Conn.get_req_header(conn, "openai-project") == ["proj_background"]
    conn
  end
end
