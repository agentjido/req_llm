defmodule ReqLLM.OpenAIPricingContextTest do
  use ExUnit.Case, async: true

  import ReqLLM.Test.StreamServerHelpers

  alias ReqLLM.PricingContext
  alias ReqLLM.Providers.OpenAI
  alias ReqLLM.Providers.OpenAI.ResponsesAPI
  alias ReqLLM.Step.Usage
  alias ReqLLM.StreamServer

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  test "physical endpoint and returned tier override preferences without losing confirmed facts" do
    explicit = %{
      "api" => "batch",
      "service_tier" => "auto",
      "regional_processing" => true,
      cache_ttl: "1h"
    }

    assert PricingContext.from_openai(
             URI.parse("https://api.openai.com/v1/responses"),
             %{"service_tier" => "flex"},
             explicit
           ) == %{
             api: "responses",
             service_tier: "flex",
             regional_processing: false,
             cache_ttl: "1h"
           }

    for host <- ["us.api.openai.com", "eu.api.openai.com"] do
      assert PricingContext.from_openai("https://#{host}/v1/chat/completions", %{
               service_tier: :default
             }) == %{
               api: "chat_completions",
               regional_processing: true,
               service_tier: "default"
             }
    end

    assert PricingContext.from_openai("https://api.openai.com/v1/batches/batch_123", %{}) ==
             %{api: "batch", regional_processing: false}

    assert PricingContext.from_openai("http://localhost:4321/v1/responses", %{}) ==
             %{api: "responses"}

    assert PricingContext.from_openai("https://proxy.example/custom", %{}, %{
             regional_processing: false,
             service_tier: "default"
           }) == %{regional_processing: false}

    assert PricingContext.from_openai(nil, nil) == %{}

    for tier <- [nil, "auto", :auto, ""] do
      context =
        PricingContext.from_openai("https://api.openai.com/v1/responses", %{service_tier: tier},
          service_tier: "default"
        )

      refute Map.has_key?(context, :service_tier)
      refute Map.has_key?(context, "service_tier")
    end
  end

  test "buffered client functions retain arguments and ordinary token charges" do
    model = ReqLLM.model!("openai:gpt-5-nano")
    response = buffered(model, responses_body(100, "default", [function_item()]))

    assert [%ReqLLM.ToolCall{id: "call_read", function: function}] =
             response.body.message.tool_calls

    assert function.name == "read_market"
    assert Jason.decode!(function.arguments) == %{"symbol" => "SOL"}
    assert response.body.finish_reason == :tool_calls
    assert response.body.usage.tool_usage == %{}
    assert response.body.usage.total_cost > 0
    assert response.body.usage.pricing.status == :priced
    assert_client_execution(response.body.message.tool_calls)
  end

  test "streamed client functions retain arguments and ordinary token charges" do
    model = ReqLLM.model!("openai:gpt-5-nano")
    {chunks, metadata} = streamed(model, responses_body(100, "default", [function_item()]))

    assert metadata.usage.tool_usage == %{}
    assert metadata.usage.total_cost > 0

    assert {:ok, response} =
             ResponsesAPI.ResponseBuilder.build_response(chunks, metadata,
               context: %ReqLLM.Context{messages: []},
               model: model
             )

    assert [%ReqLLM.ToolCall{id: "call_read", function: function}] = response.message.tool_calls
    assert function.name == "read_market"
    assert Jason.decode!(function.arguments) == %{"symbol" => "SOL"}
    assert_client_execution(response.message.tool_calls)
  end

  test "known hosted calls remain separately charged beside client functions" do
    model = ReqLLM.model!("openai:gpt-5-nano")
    hosted = %{"type" => "web_search_call", "id" => "search_123", "status" => "completed"}
    body = responses_body(100, "default", [function_item(), hosted])
    response = buffered(model, body)
    {_chunks, metadata} = streamed(model, body)
    baseline = buffered(model, responses_body(100, "default", [function_item()]))

    for usage <- [response.body.usage, metadata.usage] do
      assert usage.tool_usage == %{web_search: %{count: 1, unit: :call}}
      assert usage.total_cost > baseline.body.usage.total_cost
      assert usage.pricing.status == :priced
    end
  end

  test "genuinely unknown hosted calls stay metered and unpriced in both paths" do
    model = ReqLLM.model!("openai:gpt-5-nano")
    item = %{"type" => "future_hosted_call", "id" => "hosted_123", "status" => "completed"}
    body = responses_body(100, "default", [item])
    response = buffered(model, body)
    {_chunks, metadata} = streamed(model, body)

    for usage <- [response.body.usage, metadata.usage] do
      assert usage.tool_usage["future_hosted"] == %{count: 1, unit: :call}
      assert usage.pricing.status == :unknown
      refute Map.has_key?(usage, :total_cost)
    end
  end

  test "buffered and streamed costs select short, long and returned tier tariffs before telemetry" do
    for {id, api} <- [{"gpt-6-sol", "responses"}, {"gpt-5.6-luna", "chat_completions"}],
        input <- [272_000, 272_001],
        {tier, host} <- [{"default", "api.openai.com"}, {"flex", "eu.api.openai.com"}] do
      model = ReqLLM.model!("openai:#{id}")
      body = wire_body(api, input, tier)
      url = endpoint(host, api)
      explicit = %{api: "batch", service_tier: "auto", regional_processing: false}
      response = buffered(model, body, url, explicit)
      {_chunks, metadata} = streamed(model, body, url, explicit)

      assert response.body.usage.input_tokens == input
      assert response.body.usage.output_tokens == 100_000
      assert metadata.usage.total_cost == response.body.usage.total_cost
      assert response.private.req_llm.usage.total_cost == response.body.usage.total_cost

      selected = response.body.usage.cost.line_items
      input_line = Enum.find(selected, &String.starts_with?(&1.id, "token.input"))
      assert String.ends_with?(input_line.id, ".long_context") == input > 272_000

      assert {:ok, expected} =
               ReqLLM.Billing.calculate(response.body.usage, model, %{
                 api: api,
                 service_tier: tier,
                 regional_processing: host != "api.openai.com"
               })

      assert response.body.usage.total_cost == expected.total
    end
  end

  test "unfamiliar hosts cannot establish a regional tariff" do
    model = ReqLLM.model!("openai:gpt-6-sol")
    body = responses_body(1_200, "default")
    url = "https://proxy.example/v1/responses"
    response = buffered(model, body, url)
    {_chunks, metadata} = streamed(model, body, url)

    for usage <- [response.body.usage, metadata.usage] do
      assert usage.pricing.status == :unknown
      refute Map.has_key?(usage, :total_cost)
    end
  end

  test "stream terminal token telemetry carries the conditional physical cost" do
    model = ReqLLM.model!("openai:gpt-6-sol")
    server = stream_server(model, endpoint("eu.api.openai.com", "responses"), %{})

    telemetry =
      model
      |> ReqLLM.Telemetry.new_context([],
        mode: :stream,
        transport: :finch,
        operation: :chat
      )
      |> ReqLLM.Telemetry.start_request(%{})

    pid = self()
    handler_id = {__MODULE__, make_ref()}
    request_id = telemetry.request_id

    :ok =
      :telemetry.attach(
        handler_id,
        [:req_llm, :token_usage],
        fn _event, measurements, metadata, _config ->
          if metadata.request_id == request_id do
            send(pid, {:physical_usage, measurements})
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    assert :ok = StreamServer.set_telemetry_context(server, telemetry)

    send_event(server, %{
      "type" => "response.completed",
      "response" => responses_body(272_001, "flex")
    })

    assert :ok = StreamServer.http_event(server, :done)
    assert {:ok, metadata} = StreamServer.await_metadata(server, 500)
    assert_receive {:physical_usage, measurements}
    assert measurements.cost == metadata.usage.total_cost
    assert measurements.cost > 0
    StreamServer.cancel(server)
  end

  test "missing or auto returned tier cannot borrow requested default; missing usage is not zero" do
    for {id, api} <- [{"gpt-6-sol", "responses"}, {"gpt-5.6-luna", "chat_completions"}],
        tier <- [nil, "auto"] do
      model = ReqLLM.model!("openai:#{id}")
      body = wire_body(api, 1_200, tier)
      explicit = %{service_tier: "default"}
      response = buffered(model, body, endpoint("api.openai.com", api), explicit)
      {_chunks, metadata} = streamed(model, body, endpoint("api.openai.com", api), explicit)

      for usage <- [response.body.usage, metadata.usage] do
        assert usage.pricing.status == :unknown
        refute Map.has_key?(usage, :total_cost)
      end

      missing_usage = Map.delete(wire_body(api, 1_200, "default"), "usage")
      response = buffered(model, missing_usage, endpoint("api.openai.com", api))
      {_chunks, metadata} = streamed(model, missing_usage, endpoint("api.openai.com", api))
      refute Map.has_key?(response.body.usage, :total_cost)
      refute Map.has_key?(Map.get(metadata, :usage, %{}), :total_cost)
    end
  end

  test "Chat streaming keeps an earlier returned tier when the final usage event omits it" do
    model = ReqLLM.model!("openai:gpt-5.6-luna")
    server = stream_server(model, endpoint("api.openai.com", "chat_completions"), %{})

    send_event(server, %{
      "id" => "chat_123",
      "service_tier" => "flex",
      "choices" => [%{"index" => 0, "delta" => %{"content" => "hello"}}]
    })

    send_event(server, Map.delete(chat_body(1_200, "flex"), "service_tier"))
    assert :ok = StreamServer.http_event(server, :done)
    assert {:ok, metadata} = StreamServer.await_metadata(server, 500)
    assert metadata.provider_meta["service_tier"] == "flex"

    response =
      buffered(model, chat_body(1_200, "flex"), endpoint("api.openai.com", "chat_completions"))

    assert metadata.usage.total_cost == response.body.usage.total_cost
    StreamServer.cancel(server)
  end

  defp assert_client_execution(calls) do
    owner = self()

    tool =
      ReqLLM.Tool.new!(
        name: "read_market",
        description: "Read a market",
        parameter_schema: [symbol: [type: :string, required: true]],
        callback: fn args ->
          send(owner, {:executed_client_function, args})
          {:ok, %{symbol: args.symbol}}
        end
      )

    result = ReqLLM.Context.execute_and_append_tools(ReqLLM.Context.new([]), calls, [tool])
    assert [%ReqLLM.Message{role: :tool, tool_call_id: "call_read"} = message] = result.messages
    refute message.metadata[:is_error]
    assert_receive {:executed_client_function, %{symbol: "SOL"}}
  end

  defp function_item do
    %{
      "type" => "function_call",
      "id" => "fc_read",
      "call_id" => "call_read",
      "name" => "read_market",
      "arguments" => ~s({"symbol":"SOL"}),
      "status" => "completed"
    }
  end

  defp responses_body(input, tier, output \\ []) do
    %{
      "id" => "resp_123",
      "object" => "response",
      "status" => "completed",
      "output" => output,
      "usage" => %{"input_tokens" => input, "output_tokens" => 100_000}
    }
    |> put_tier(tier)
  end

  defp chat_body(input, tier) do
    %{
      "id" => "chat_123",
      "choices" => [
        %{"message" => %{"role" => "assistant", "content" => "hello"}, "finish_reason" => "stop"}
      ],
      "usage" => %{
        "prompt_tokens" => input,
        "completion_tokens" => 100_000,
        "total_tokens" => input + 100_000
      }
    }
    |> put_tier(tier)
  end

  defp wire_body("responses", input, tier), do: responses_body(input, tier)
  defp wire_body("chat_completions", input, tier), do: chat_body(input, tier)
  defp put_tier(body, nil), do: body
  defp put_tier(body, tier), do: Map.put(body, "service_tier", tier)

  defp endpoint(host, "responses"), do: "https://#{host}/v1/responses"
  defp endpoint(host, "chat_completions"), do: "https://#{host}/v1/chat/completions"

  defp buffered(model, body, url \\ "https://api.openai.com/v1/responses", explicit \\ %{}) do
    request = %Req.Request{
      url: URI.parse(url),
      options: %{model: model.id, context: %ReqLLM.Context{messages: []}},
      private: %{req_llm_model: model, req_llm_pricing_context: explicit}
    }

    {request, response} =
      OpenAI.decode_response({request, %Req.Response{status: 200, body: body}})

    {_request, response} = Usage.handle({request, response})
    response
  end

  defp stream_server(model, url, explicit) do
    parser =
      case URI.parse(url).path do
        "/v1/chat/completions" -> ReqLLM.Providers.OpenAI.ChatAPI
        "/v1/responses" -> OpenAI
      end

    server = start_server(provider_mod: parser, model: model, pricing_context: explicit)
    _task = mock_http_task(server)
    :ok = StreamServer.set_fixture_context(server, %{url: url}, %{})
    server
  end

  defp streamed(model, body, url \\ "https://api.openai.com/v1/responses", explicit \\ %{}) do
    server = stream_server(model, url, explicit)

    if Map.has_key?(body, "output") do
      for {item, index} <- Enum.with_index(body["output"]) do
        send_event(server, %{
          "type" => "response.output_item.added",
          "output_index" => index,
          "item" => item
        })

        send_event(server, %{
          "type" => "response.output_item.done",
          "output_index" => index,
          "item" => item
        })
      end

      send_event(server, %{"type" => "response.completed", "response" => body})
    else
      body = Map.put(body, "choices", [])
      send_event(server, body)
    end

    assert :ok = StreamServer.http_event(server, :done)
    assert {:ok, metadata} = StreamServer.await_metadata(server, 500)
    chunks = drain(server)
    StreamServer.cancel(server)
    {chunks, metadata}
  end

  defp send_event(server, body) do
    payload = Jason.encode!(body)
    assert :ok = StreamServer.http_event(server, {:data, "data: #{payload}\n\n"})
  end

  defp drain(server) do
    case StreamServer.next(server, 500) do
      {:ok, chunk} -> [chunk | drain(server)]
      :halt -> []
    end
  end
end
