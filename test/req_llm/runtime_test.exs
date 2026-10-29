defmodule ReqLLM.RuntimeTest do
  use ExUnit.Case, async: true

  alias ReqLLM.RequestPlan
  alias ReqLLM.Runtime

  defmodule Provider do
    def prepare_request(_operation, _model, _input, error: error), do: {:error, error}

    def prepare_request(operation, model, input, opts) do
      send(opts[:owner], {:prepared, operation, model, input, opts})
      {:ok, opts[:request]}
    end
  end

  defmodule StreamProvider do
    def attach_in_process_stream(model, context, opts) do
      send(opts[:owner], {:stream_started, model, context, opts})

      {:ok,
       [
         ReqLLM.StreamChunk.text("planned stream"),
         ReqLLM.StreamChunk.meta(%{finish_reason: :stop, terminal?: true})
       ]}
    end
  end

  test "executes the provider's Req pipeline before applying the operation result policy" do
    model = %LLMDB.Model{provider: :runtime_test, id: "outside-the-catalog"}
    input = <<0, 1, 255>>
    schema = NimbleOptions.new!(value: [type: :string])

    request =
      Req.new(
        url: "https://runtime.example",
        plug: fn conn ->
          assert Plug.Conn.get_req_header(conn, "x-provider") == ["prepared"]
          Plug.Conn.send_resp(conn, 202, "wire response")
        end
      )
      |> Req.Request.append_request_steps(
        provider_encode: &Req.Request.put_header(&1, "x-provider", "prepared")
      )
      |> Req.Request.append_response_steps(
        provider_decode: fn {request, response} ->
          {request, %{response | body: {:decoded, response.body}}}
        end
      )

    opts = [owner: self(), request: request, schema: schema, duplicate: 1, duplicate: 2]
    assert {:ok, plan} = RequestPlan.from_resolved(model, :ocr, Provider, opts, :req)
    result_ref = make_ref()

    policy = fn %Req.Response{status: 202, body: {:decoded, "wire response"}} ->
      {:ok, result_ref}
    end

    assert Runtime.execute(plan, input, :infinity, policy) == {:ok, result_ref}
    assert_receive {:prepared, :ocr, ^model, ^input, ^opts}
    refute_received {:prepared, _, _, _, _}
  end

  test "prepares once without sending and allows changes before repeated sends" do
    owner = self()
    model = %LLMDB.Model{provider: :runtime_test, id: "outside-the-catalog"}
    schema = NimbleOptions.new!(value: [type: :string])

    request =
      Req.new(
        url: "https://runtime.example",
        adapter: fn request ->
          send(owner, {:sent, Req.Request.get_header(request, "x-operation")})
          {request, Req.Response.new(status: 202, body: :provider_result)}
        end
      )

    opts = [owner: owner, request: request, schema: schema, duplicate: 1, duplicate: 2]
    assert {:ok, plan} = RequestPlan.from_resolved(model, :video, Provider, opts, :req)
    assert {:ok, ^request} = Runtime.prepare(plan, :input)
    assert_receive {:prepared, :video, ^model, :input, ^opts}
    refute_received {:sent, _}

    request = Req.Request.put_header(request, "x-operation", "transformed")

    for _ <- 1..2 do
      assert {:ok, :operation_result} =
               Runtime.execute_prepared(request, :infinity, fn
                 %Req.Response{status: 202, body: :provider_result} -> {:ok, :operation_result}
               end)

      assert_receive {:sent, ["transformed"]}
    end

    refute_received {:prepared, _, _, _, _}
  end

  test "executes a planned in-process stream through the runtime" do
    model = %LLMDB.Model{provider: :runtime_test, id: "outside-the-catalog"}
    {:ok, context} = ReqLLM.Context.normalize("Hello")
    opts = [owner: self(), operation: :chat]

    assert {:ok, plan} =
             RequestPlan.from_resolved(model, :chat, StreamProvider, opts, :in_process)

    assert {:ok, response} = Runtime.execute_stream(plan, context)
    assert ReqLLM.StreamResponse.text(response) == "planned stream"
    assert ReqLLM.StreamResponse.finish_reason(response) == :stop
    assert_receive {:stream_started, ^model, ^context, ^opts}
  end

  test "passes completed HTTP errors to the result policy unchanged" do
    response = Req.Response.new(status: 422, body: %{"error" => "invalid input"})

    request =
      Req.new(
        url: "https://runtime.example",
        adapter: fn request -> {request, response} end
      )

    assert {:error, {:operation_error, ^response}} =
             Runtime.execute_prepared(request, :infinity, fn response ->
               {:error, {:operation_error, response}}
             end)
  end

  test "passes preparation errors through without sending or applying the policy" do
    error = ReqLLM.Error.Invalid.Parameter.exception(parameter: "provider preparation failed")
    model = %LLMDB.Model{provider: :runtime_test, id: "outside-the-catalog"}
    assert {:ok, plan} = RequestPlan.from_resolved(model, :speech, Provider, [error: error], :req)

    assert Runtime.prepare(plan, :input) == {:error, error}

    assert Runtime.execute(plan, :input, :infinity, fn _ -> flunk("unexpected result policy") end) ==
             {:error, error}
  end

  test "passes transport errors through without applying the policy" do
    error = %Req.TransportError{reason: :closed}

    request =
      Req.new(
        url: "https://runtime.example",
        retry: false,
        adapter: fn request -> {request, error} end
      )

    assert Runtime.execute_prepared(request, :infinity, fn _ ->
             flunk("unexpected result policy")
           end) == {:error, error}
  end

  test "preserves expired deadlines without sending or applying the policy" do
    request =
      Req.new(
        url: "https://runtime.example",
        adapter: fn _ -> flunk("unexpected transport execution") end
      )

    deadline = %{timeout: 10, expires_at: System.monotonic_time(:millisecond) - 1}

    assert {:error, %ReqLLM.Error.API.Timeout{kind: :total, timeout: 10}} =
             Runtime.execute_prepared(request, deadline, fn _ ->
               flunk("unexpected result policy")
             end)
  end
end
