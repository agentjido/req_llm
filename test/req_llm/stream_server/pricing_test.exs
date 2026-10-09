defmodule ReqLLM.StreamServer.PricingTest do
  use ExUnit.Case, async: true

  import ReqLLM.Test.StreamServerHelpers

  alias ReqLLM.Providers.OpenAI
  alias ReqLLM.StreamChunk
  alias ReqLLM.StreamServer

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  test "non-map provider metadata does not lose a confirmed tier or stop the stream" do
    for invalid <- [nil, false, [], ["unexpected"], "unexpected", 7] do
      server = pricing_server()
      send_meta(server, %{provider_meta: invalid})
      send_meta(server, %{usage: token_usage(), provider_meta: %{service_tier: "default"}})
      send_meta(server, %{provider_meta: invalid})
      send_meta(server, %{provider_meta: %{"future_field" => %{"value" => nil}}})

      metadata = complete(server)
      assert metadata.usage.total_cost == 4.0
      assert metadata.provider_meta.service_tier == "default"
      assert metadata.provider_meta["future_field"] == %{"value" => nil}
    end
  end

  test "a later tier replaces the earlier tier across atom and string keys" do
    for {first_key, last_key} <- [
          {:service_tier, "service_tier"},
          {"service_tier", :service_tier}
        ],
        {first_tier, last_tier, expected} <- [
          {"default", "flex", 2.0},
          {"flex", "default", 4.0}
        ] do
      server = pricing_server()

      send_meta(server, %{
        provider_meta: Map.put(%{"request_field" => "kept"}, first_key, first_tier)
      })

      send_meta(server, %{usage: token_usage()})
      send_meta(server, %{provider_meta: Map.put(%{}, last_key, last_tier)})
      send_meta(server, %{provider_meta: %{system_fingerprint: "fingerprint"}})

      metadata = complete(server)
      assert metadata.usage.total_cost == expected
      assert metadata.provider_meta[last_key] == last_tier
      refute Map.has_key?(metadata.provider_meta, first_key)
      assert metadata.provider_meta["request_field"] == "kept"
      assert metadata.provider_meta.system_fingerprint == "fingerprint"
    end
  end

  test "an explicit unknown tier clears an earlier price across key forms" do
    for {first_key, last_key} <- [
          {:service_tier, "service_tier"},
          {"service_tier", :service_tier}
        ],
        unknown <- [nil, "", "auto", :auto, false, 7, [], %{}] do
      server = pricing_server(pricing_context: %{service_tier: "default"})

      send_meta(server, %{
        usage: token_usage(),
        provider_meta: Map.put(%{}, first_key, "default")
      })

      send_meta(server, %{provider_meta: Map.put(%{}, last_key, unknown)})

      metadata = complete(server)
      assert metadata.usage.pricing.status == :unknown
      refute Map.has_key?(metadata.usage, :total_cost)
      refute Map.has_key?(metadata.usage, :cost)
      refute Map.has_key?(metadata.provider_meta, first_key)
      assert metadata.provider_meta[last_key] == unknown
    end
  end

  test "an explicit nil atom tier cannot fall back to a conflicting string tier" do
    server = pricing_server()

    send_meta(server, %{
      usage: token_usage(),
      provider_meta: %{"service_tier" => "default", :service_tier => nil}
    })

    metadata = complete(server)
    assert metadata.usage.pricing.status == :unknown
    refute Map.has_key?(metadata.usage, :total_cost)
    assert metadata.provider_meta == %{service_tier: nil}
  end

  test "string-keyed provider metadata is merged into the canonical metadata field" do
    server = pricing_server()
    send_meta(server, %{"provider_meta" => %{"service_tier" => "default"}})
    send_meta(server, %{usage: token_usage()})
    send_meta(server, %{provider_meta: %{service_tier: "flex"}})

    metadata = complete(server)
    assert metadata.usage.total_cost == 2.0
    assert metadata.provider_meta == %{service_tier: "flex"}
    refute Map.has_key?(metadata, "provider_meta")
  end

  test "Chat stream event order gives a late returned tier the buffered price" do
    model = pricing_model()
    url = "https://api.openai.com/v1/chat/completions"

    events = [
      %{
        "service_tier" => "default",
        "choices" => [%{"delta" => %{"content" => "hello"}}]
      },
      %{"choices" => [%{"delta" => %{}, "finish_reason" => "stop"}]},
      %{"usage" => %{"prompt_tokens" => 100, "completion_tokens" => 50}},
      %{"service_tier" => "flex", "choices" => []}
    ]

    body = %{
      "service_tier" => "flex",
      "choices" => [
        %{
          "message" => %{"role" => "assistant", "content" => "hello"},
          "finish_reason" => "stop"
        }
      ],
      "usage" => %{"prompt_tokens" => 100, "completion_tokens" => 50}
    }

    for batch? <- [false, true] do
      server = pricing_server(provider_mod: OpenAI.ChatAPI, canonical_stream?: false)
      send_events(server, events, batch?)
      assert :ok = StreamServer.http_event(server, {:data, "data: [DONE]\n\n"})
      assert {:ok, metadata} = StreamServer.await_metadata(server, 500)
      chunks = drain(server)

      assert Enum.map(chunks, & &1.type) == [:meta, :content, :meta, :meta, :meta, :meta]
      assert Enum.at(chunks, 1).text == "hello"
      assert Enum.at(chunks, 2).metadata.finish_reason == :stop
      assert Enum.at(chunks, 3).metadata.usage.input_tokens == 100
      assert Enum.at(chunks, 4).metadata.provider_meta["service_tier"] == "flex"
      assert metadata.usage.total_cost == buffered_usage(model, body, url).total_cost
      assert metadata.usage.total_cost == 2.0
      StreamServer.cancel(server)
    end
  end

  test "Responses tier after a separate usage event gives the buffered price" do
    model = pricing_model()
    url = "https://api.openai.com/v1/responses"

    body = %{
      "id" => "resp_pricing",
      "object" => "response",
      "status" => "completed",
      "output" => [],
      "service_tier" => "flex",
      "usage" => %{"input_tokens" => 100, "output_tokens" => 50}
    }

    for batch? <- [false, true] do
      server =
        pricing_server(
          provider_mod: OpenAI.ResponsesAPI,
          canonical_stream?: false,
          pricing_context: %{service_tier: "default"}
        )

      assert :ok = StreamServer.set_fixture_context(server, %{url: url}, %{})

      send_events(
        server,
        [
          %{"type" => "response.usage", "usage" => body["usage"]},
          %{"type" => "response.completed", "response" => Map.delete(body, "usage")}
        ],
        batch?
      )

      assert {:ok, metadata} = StreamServer.await_metadata(server, 500)
      chunks = drain(server)
      assert Enum.map(chunks, & &1.type) == [:meta, :meta]
      assert hd(chunks).metadata.usage.input_tokens == 100
      assert List.last(chunks).metadata.provider_meta["service_tier"] == "flex"
      assert metadata.usage.total_cost == buffered_usage(model, body, url).total_cost
      assert metadata.usage.total_cost == 2.0
      StreamServer.cancel(server)
    end
  end

  test "Chat final usage applies its returned tier before terminal token telemetry" do
    owner = self()
    handler_id = {__MODULE__, make_ref()}

    assert :ok =
             :telemetry.attach(
               handler_id,
               [:req_llm, :token_usage],
               fn _event, measurements, metadata, _config ->
                 send(owner, {:stream_usage, metadata[:request_id], measurements})
               end,
               nil
             )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    for tier <- ["flex", nil, "auto"], batch? <- [false, true] do
      server = pricing_server(provider_mod: OpenAI.ChatAPI, canonical_stream?: false)

      telemetry =
        pricing_model()
        |> ReqLLM.Telemetry.new_context([],
          mode: :stream,
          transport: :finch,
          operation: :chat
        )
        |> ReqLLM.Telemetry.start_request(%{})

      request_id = telemetry.request_id
      assert :ok = StreamServer.set_telemetry_context(server, telemetry)

      send_events(
        server,
        [
          %{
            "service_tier" => "default",
            "choices" => [%{"delta" => %{"content" => "hello"}}]
          },
          %{
            "service_tier" => tier,
            "choices" => [],
            "usage" => %{"prompt_tokens" => 100, "completion_tokens" => 50}
          }
        ],
        batch?
      )

      assert {:ok, metadata} = StreamServer.await_metadata(server, 500)
      assert_receive {:stream_usage, ^request_id, measurements}
      assert measurements.cost == metadata.usage[:total_cost]

      if tier == "flex" do
        assert metadata.usage.total_cost == 2.0
      else
        assert metadata.usage.pricing.status == :unknown
        refute Map.has_key?(metadata.usage, :total_cost)
      end

      chunks = drain(server)
      assert Enum.map(chunks, & &1.type) == [:meta, :content, :meta, :meta]
      assert Enum.at(chunks, 2).metadata.provider_meta["service_tier"] == tier
      assert Enum.at(chunks, 3).metadata.usage.input_tokens == 100
      StreamServer.cancel(server)
    end
  end

  defp pricing_model do
    components =
      for {tier, multiplier} <- [{"default", 1.0}, {"flex", 0.5}],
          {meter, rate} <- [{"input", 0.02}, {"output", 0.04}] do
        %{
          id: "token.#{meter}.#{tier}",
          kind: "token",
          per: 1,
          rate: rate * multiplier,
          applies_when: %{service_tier: tier}
        }
      end

    %LLMDB.Model{
      provider: :openai,
      id: "stream-pricing",
      pricing: %{currency: "USD", components: components}
    }
  end

  defp pricing_server(opts \\ []) do
    opts = Keyword.merge([model: pricing_model(), canonical_stream?: true], opts)
    server = start_server(opts)
    _task = mock_http_task(server)

    assert :ok =
             StreamServer.set_fixture_context(
               server,
               %{url: "https://api.openai.com/v1/chat/completions"},
               %{}
             )

    server
  end

  defp token_usage, do: %{input_tokens: 100, output_tokens: 50}

  defp send_meta(server, metadata) do
    assert :ok = StreamServer.in_process_event(server, {:chunk, StreamChunk.meta(metadata)})
  end

  defp complete(server) do
    assert :ok = StreamServer.http_event(server, :done)
    assert {:ok, metadata} = StreamServer.await_metadata(server, 500)
    StreamServer.cancel(server)
    metadata
  end

  defp send_events(server, events, batch?) do
    encoded = Enum.map(events, &"data: #{Jason.encode!(&1)}\n\n")
    payloads = if batch?, do: [Enum.join(encoded)], else: encoded

    for payload <- payloads do
      assert :ok = StreamServer.http_event(server, {:data, payload})
    end
  end

  defp buffered_usage(model, body, url) do
    request = %Req.Request{
      url: URI.parse(url),
      options: %{model: model.id, context: ReqLLM.Context.new([])},
      private: %{req_llm_model: model}
    }

    {request, response} =
      OpenAI.decode_response({request, %Req.Response{status: 200, body: body}})

    {_request, response} = ReqLLM.Step.Usage.handle({request, response})
    response.body.usage
  end

  defp drain(server) do
    case StreamServer.next(server, 500) do
      {:ok, chunk} -> [chunk | drain(server)]
      :halt -> []
    end
  end
end
