defmodule ReqLLM.AnthropicPricingContextTest do
  use ExUnit.Case, async: true

  import ReqLLM.Test.StreamServerHelpers

  alias ReqLLM.PricingContext
  alias ReqLLM.Providers.Anthropic
  alias ReqLLM.StreamServer
  alias ReqLLM.Test.Billing.Samples

  @url "https://api.anthropic.com/v1/messages"
  @facts %{"inference_geo" => "global", "speed" => "standard", "service_tier" => "standard"}

  defmodule MessagesPlug do
    def init(body), do: body

    def call(conn, body) do
      {:ok, request, conn} = Plug.Conn.read_body(conn)

      if Jason.decode!(request)["stream"] do
        events = [
          %{"type" => "message_start", "message" => put_in(body, ["usage", "output_tokens"], 0)},
          %{
            "type" => "message_delta",
            "delta" => %{"stop_reason" => "end_turn"},
            "usage" => %{"output_tokens" => 10}
          },
          %{"type" => "message_stop"}
        ]

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, Enum.map_join(events, &"data: #{Jason.encode!(&1)}\n\n"))
      else
        Req.Test.json(conn, body)
      end
    end
  end

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  test "returned facts and the physical endpoint replace conflicting caller context" do
    context = %{
      "api" => "batch",
      "inference_geo" => "us",
      "service_tier" => "auto",
      "request_body" => %{"speed" => "fast", "other" => true},
      cache_ttl: "1h"
    }

    assert PricingContext.from_anthropic(@url, @facts, context) == %{
             api: "messages",
             inference_geo: "global",
             service_tier: "standard",
             request_body: %{"other" => true, :speed => "standard"},
             cache_ttl: "1h"
           }

    assert PricingContext.from_anthropic("https://api.anthropic.com/v1/messages/batches", nil) ==
             %{api: "batch"}

    assert PricingContext.from_anthropic(
             "https://api.anthropic.com/v1/messages/batches/batch_123/results",
             nil
           ) == %{api: "batch"}

    assert PricingContext.from_anthropic(nil, nil, inference_geo: "global") ==
             %{inference_geo: "global"}
  end

  test "only standard request speed is confirmed without returned speed" do
    assert PricingContext.from_anthropic(@url, nil, %{}, Jason.encode!(%{model: "test"})) ==
             %{api: "messages", request_body: %{speed: "standard"}}

    assert PricingContext.from_anthropic(@url, nil, %{}, %{speed: "fast"}) ==
             %{api: "messages"}

    assert PricingContext.from_anthropic(
             @url,
             nil,
             %{request_body: %{speed: "standard"}},
             %{speed: "fast"}
           ) == %{api: "messages", request_body: %{speed: "standard"}}

    assert PricingContext.from_anthropic(@url, nil, %{}, %{speed: nil}) ==
             %{api: "messages", request_body: %{}}

    assert PricingContext.from_anthropic("https://proxy.example/v1/messages", nil, %{}, %{}) ==
             %{api: "messages"}

    assert PricingContext.from_anthropic(@url, nil, %{}, "invalid") == %{api: "messages"}

    assert PricingContext.from_anthropic(@url, %{speed: :standard, inference_geo: :us}) ==
             %{api: "messages", inference_geo: "us", request_body: %{speed: "standard"}}
  end

  test "invalid returned facts clear conflicting caller facts" do
    for invalid <- [nil, "", "auto", "not_available", "future", false, 1, [], %{}] do
      metadata = %{inference_geo: invalid, speed: invalid, service_tier: invalid}

      assert PricingContext.from_anthropic(
               @url,
               metadata,
               %{
                 inference_geo: "global",
                 service_tier: "standard",
                 request_body: %{speed: "standard"}
               },
               %{}
             ) == %{api: "messages", request_body: %{}}
    end
  end

  test "present atom facts take precedence over string aliases, including nil" do
    for invalid <- [nil, false, "future"] do
      metadata =
        Map.merge(@facts, %{inference_geo: invalid, speed: invalid, service_tier: invalid})

      assert PricingContext.from_anthropic(@url, metadata, %{}, %{}) ==
               %{api: "messages", request_body: %{}}

      assert PricingContext.from_anthropic(@url, nil, %{}, %{
               "speed" => "standard",
               speed: invalid
             }) ==
               %{api: "messages", request_body: %{}}
    end
  end

  for path <- [:buffered, :streamed] do
    test "#{path} pricing uses returned facts without explicit context" do
      path = unquote(path)

      for {id, expected} <- [
            {"anthropic:claude-haiku-4-5", 0.00015},
            {"anthropic:claude-opus-5-5", 0.0006}
          ] do
        {usage, metadata} = usage_for(path, sample(id, @facts))
        assert usage.pricing.status == :priced
        assert_in_delta usage.total_cost, expected, 1.0e-12
        assert Map.take(metadata, Map.keys(@facts)) == @facts
      end
    end

    test "#{path} pricing applies fast and regional modifiers once" do
      for {facts, expected} <- [
            {%{"speed" => "fast"}, 0.0012},
            {%{"inference_geo" => "us"}, 0.00066},
            {%{"speed" => "fast", "inference_geo" => "us"}, 0.00132}
          ] do
        {usage, _} =
          usage_for(unquote(path), sample("anthropic:claude-opus-5-5", Map.merge(@facts, facts)))

        assert usage.pricing.status == :priced
        assert_in_delta usage.total_cost, expected, 1.0e-12
      end
    end

    test "#{path} pricing uses confirmed facts over caller preferences" do
      explicit = %{
        api: "batch",
        inference_geo: "us",
        request_body: %{"speed" => "fast"},
        service_tier: "auto"
      }

      {usage, _} =
        usage_for(unquote(path), sample("anthropic:claude-opus-5-5", @facts), explicit)

      assert usage.pricing.status == :priced
      assert_in_delta usage.total_cost, 0.0006, 1.0e-12
    end

    test "#{path} pricing remains unknown when required returned facts are invalid or absent" do
      for facts <- [
            %{},
            Map.delete(@facts, "inference_geo"),
            Map.put(@facts, "inference_geo", "not_available"),
            Map.put(@facts, "speed", nil)
          ] do
        {usage, _} = usage_for(unquote(path), sample("anthropic:claude-opus-5-5", facts))
        assert usage.pricing.status == :unknown
        refute Map.has_key?(usage, :total_cost)
      end
    end

    test "#{path} pricing keeps independent explicit context for missing response facts" do
      explicit = %{inference_geo: "global", request_body: %{"speed" => "standard"}}
      {usage, _} = usage_for(unquote(path), sample("anthropic:claude-opus-5-5", %{}), explicit)

      assert usage.pricing.status == :priced
      assert_in_delta usage.total_cost, 0.0006, 1.0e-12
    end

    test "#{path} pricing confirms ordinary first-party calls from the endpoint and request" do
      {haiku, _} = usage_for(unquote(path), sample("anthropic:claude-haiku-4-5", %{}))
      assert haiku.pricing.status == :priced
      assert_in_delta haiku.total_cost, 0.00015, 1.0e-12

      {opus, _} =
        usage_for(
          unquote(path),
          sample("anthropic:claude-opus-5-5", %{"inference_geo" => "global"})
        )

      assert opus.pricing.status == :priced
      assert_in_delta opus.total_cost, 0.0006, 1.0e-12
    end

    test "#{path} pricing requires returned speed for a fast request" do
      sample = sample("anthropic:claude-opus-5-5", %{"inference_geo" => "global"})
      {usage, _} = usage_for(unquote(path), sample, %{}, %{"speed" => "fast"})

      assert usage.pricing.status == :unknown
      refute Map.has_key?(usage, :total_cost)

      sample = %{sample | body: put_in(sample.body, ["usage", "speed"], "standard")}
      {usage, _} = usage_for(unquote(path), sample, %{}, %{"speed" => "fast"})

      assert usage.pricing.status == :priced
      assert_in_delta usage.total_cost, 0.0006, 1.0e-12
    end

    test "#{path} pricing requires token counts and accepts reported zero counts" do
      for raw_usage <- [
            nil,
            %{},
            @facts,
            Map.put(@facts, "input_tokens", 100),
            Map.put(@facts, "output_tokens", 10),
            Map.merge(@facts, %{"input_tokens" => 0, "output_tokens" => 0})
          ] do
        sample = sample("anthropic:claude-haiku-4-5", @facts)

        body =
          if is_nil(raw_usage),
            do: Map.delete(sample.body, "usage"),
            else: Map.put(sample.body, "usage", raw_usage)

        sample = %{sample | body: body}

        {usage, _} =
          case unquote(path) do
            :buffered ->
              usage_for(:buffered, sample)

            :streamed ->
              events = [
                %{"type" => "message_start", "message" => body},
                %{"type" => "message_stop"}
              ]

              stream_usage(sample, events, %{})
          end

        if is_map(raw_usage) and Map.has_key?(raw_usage, "input_tokens") and
             Map.has_key?(raw_usage, "output_tokens") do
          assert usage.pricing.status == :priced
          assert usage.total_cost == 0
        else
          assert get_in(usage, [:pricing, :status]) in [nil, :unknown]
          refute Map.has_key?(usage, :total_cost)
        end
      end
    end

    test "#{path} pricing retains cache duration facts without explicit context" do
      sample = Samples.sample("mixed_cache_ttl", "anthropic:claude-opus-5-5")
      sample = %{sample | body: Map.update!(sample.body, "usage", &Map.merge(&1, @facts))}
      {usage, _} = usage_for(unquote(path), sample)

      assert usage.pricing.status == :priced

      assert ReqLLM.Usage.normalize(usage).cache_write_tokens_by_ttl == %{
               "5m" => 4000,
               "1h" => 6000
             }

      assert_in_delta usage.total_cost, 0.0686, 1.0e-12
    end
  end

  test "public normal and streaming calls are priced without explicit context" do
    for {id, expected} <- [
          {"anthropic:claude-haiku-4-5", 0.00015},
          {"anthropic:claude-opus-5-5", 0.0006}
        ] do
      body = sample(id, @facts).body

      server =
        start_supervised!(
          {Bandit, plug: {MessagesPlug, body}, port: 0, startup_log: false},
          id: make_ref()
        )

      {:ok, {_, port}} = ThousandIsland.listener_info(server)
      opts = [api_key: "test-key", base_url: "http://127.0.0.1:#{port}", max_tokens: 16]

      assert {:ok, response} = ReqLLM.generate_text(id, "Say hi", opts)
      assert response.usage.pricing.status == :priced
      assert_in_delta response.usage.total_cost, expected, 1.0e-12

      assert {:ok, stream} = ReqLLM.stream_text(id, "Say hi", opts)
      usage = ReqLLM.StreamResponse.usage(stream)
      assert usage.pricing.status == :priced
      assert_in_delta usage.total_cost, expected, 1.0e-12
    end
  end

  test "later streamed facts can change a known price to unknown" do
    sample = sample("anthropic:claude-opus-5-5", @facts)
    events = Samples.events(sample)
    delta = Enum.at(events, 1) |> put_in(["usage", "speed"], "future")
    {usage, _} = stream_usage(sample, [hd(events), delta, List.last(events)], %{})

    assert usage.pricing.status == :unknown
    refute Map.has_key?(usage, :total_cost)
  end

  test "metadata-only streamed facts recalculate the existing usage" do
    metadata = canonical_usage([%{}, @facts, %{"speed" => "fast", "inference_geo" => "us"}])

    assert metadata.usage.pricing.status == :priced
    assert_in_delta metadata.usage.total_cost, 0.00132, 1.0e-12
    assert metadata.usage.input_tokens == 100
    assert metadata.usage.output_tokens == 10
  end

  test "later streamed facts replace both aliases and clear an old price" do
    for key <- [:speed, :inference_geo], atom_first? <- [true, false] do
      initial =
        if atom_first?,
          do: Map.new(@facts, fn {k, v} -> {String.to_existing_atom(k), v} end),
          else: @facts

      incoming_key = if atom_first?, do: Atom.to_string(key), else: key
      stale_key = if atom_first?, do: key, else: Atom.to_string(key)
      metadata = canonical_usage([initial, %{incoming_key => nil}])

      assert metadata.usage.pricing.status == :unknown
      refute Map.has_key?(metadata.usage, :total_cost)
      assert Map.fetch!(metadata.provider_meta, incoming_key) == nil
      refute Map.has_key?(metadata.provider_meta, stale_key)
    end
  end

  test "both stream decoder callbacks preserve returned pricing facts" do
    sample = sample("anthropic:claude-opus-5-5", @facts)
    model = ReqLLM.model!(sample.model)
    event = %{data: hd(Samples.events(sample))}
    stateless = Anthropic.decode_stream_event(event, model)
    {stateful, _} = Anthropic.decode_stream_event(event, model, nil)

    for chunks <- [stateless, stateful] do
      assert [chunk] = chunks
      assert chunk.metadata.provider_meta == @facts
    end
  end

  defp sample(id, facts) do
    sample = Samples.sample("basic_usage", id)
    %{sample | body: Map.update!(sample.body, "usage", &Map.merge(&1, facts))}
  end

  defp usage_for(path, sample, explicit \\ %{}, request_body \\ %{})

  defp usage_for(:buffered, sample, explicit, request_body) do
    model = ReqLLM.model!(sample.model)

    request = %Req.Request{
      url: URI.parse(@url),
      body: Jason.encode!(Map.merge(%{"model" => model.id}, request_body)),
      options: %{model: model.id, context: ReqLLM.Context.new([])},
      private: %{req_llm_model: model, req_llm_pricing_context: explicit}
    }

    {request, response} =
      Anthropic.decode_response({request, %Req.Response{status: 200, body: sample.body}})

    {_, response} = ReqLLM.Step.Usage.handle({request, response})
    {response.body.usage, response.body.provider_meta}
  end

  defp usage_for(:streamed, sample, explicit, request_body),
    do: stream_usage(sample, Samples.events(sample), explicit, request_body)

  defp stream_usage(sample, events, explicit, request_body \\ %{}) do
    server =
      start_server(
        provider_mod: Anthropic,
        model: ReqLLM.model!(sample.model),
        pricing_context: explicit
      )

    mock_http_task(server)

    StreamServer.set_fixture_context(
      server,
      %{url: @url},
      Map.merge(%{"model" => sample.model}, request_body)
    )

    for event <- events do
      assert :ok = StreamServer.http_event(server, {:data, "data: #{Jason.encode!(event)}\n\n"})
    end

    assert :ok = StreamServer.http_event(server, :done)
    assert {:ok, metadata} = StreamServer.await_metadata(server, 1000)
    StreamServer.cancel(server)
    {Map.get(metadata, :usage, %{}), metadata.provider_meta}
  end

  defp canonical_usage([initial | updates]) do
    server =
      start_server(
        provider_mod: Anthropic,
        model: ReqLLM.model!("anthropic:claude-opus-5-5"),
        canonical_stream?: true
      )

    mock_http_task(server)

    StreamServer.set_fixture_context(server, %{url: @url}, %{})

    metadata = %{usage: %{input_tokens: 100, output_tokens: 10}, provider_meta: initial}
    chunk = ReqLLM.StreamChunk.meta(metadata)
    assert :ok = StreamServer.in_process_event(server, {:chunk, chunk})

    for facts <- updates do
      chunk = ReqLLM.StreamChunk.meta(%{provider_meta: facts})
      assert :ok = StreamServer.in_process_event(server, {:chunk, chunk})
    end

    assert :ok = StreamServer.in_process_event(server, :done)
    assert {:ok, metadata} = StreamServer.await_metadata(server, 1000)
    StreamServer.cancel(server)
    metadata
  end
end
