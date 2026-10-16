defmodule ReqLLM.Providers.AmazonBedrock.ObjectStreamTest do
  use ExUnit.Case, async: true

  alias ReqLLM.StreamResponse

  @model "amazon_bedrock:eu.anthropic.claude-haiku-4-5-20251001-v1:0"
  @arn "arn:aws:bedrock:eu-west-1:123456789012:application-inference-profile/test"

  defmodule Endpoint do
    def init(opts), do: opts

    def call(conn, opts) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(opts[:owner], {:request, conn.request_path, Jason.decode!(body)})

      conn =
        conn
        |> Plug.Conn.put_resp_content_type("application/vnd.amazon.eventstream")
        |> Plug.Conn.send_chunked(200)

      Enum.reduce(opts[:frames], conn, fn frame, conn ->
        split = div(byte_size(frame), 2)
        <<first::binary-size(^split), last::binary>> = frame
        {:ok, conn} = Plug.Conn.chunk(conn, first)
        {:ok, conn} = Plug.Conn.chunk(conn, last)
        conn
      end)
    end
  end

  for use_converse <- [true, false],
      mode <- [:auto, :json_schema],
      profile? <- [false, true] do
    @tag use_converse: use_converse, mode: mode, profile?: profile?
    test "streams a final object with Converse=#{use_converse}, mode=#{mode}, profile=#{profile?}",
         %{
           use_converse: use_converse,
           mode: mode,
           profile?: profile?
         } do
      frames =
        use_converse
        |> events(mode)
        |> Enum.map(&encode_event(&1, use_converse))

      server =
        start_supervised!(
          {Bandit, plug: {Endpoint, owner: self(), frames: frames}, port: 0, ip: {127, 0, 0, 1}}
        )

      {:ok, {_address, port}} = ThousandIsland.listener_info(server)
      owner = self()

      redirect = fn request ->
        send(owner, {:signed_request, request})
        %{request | scheme: :http, host: "127.0.0.1", port: port}
      end

      provider_options = [
        access_key_id: "AKIATEST",
        secret_access_key: "secretTEST",
        session_token: "sessionTEST",
        region: "eu-west-1",
        use_converse: use_converse,
        anthropic_structured_output_mode: mode
      ]

      provider_options =
        if profile?,
          do: Keyword.put(provider_options, :inference_profile_arn, @arn),
          else: provider_options

      assert {:ok, %StreamResponse{} = stream} =
               ReqLLM.stream_object(
                 @model,
                 "Describe a city",
                 [name: [type: :string, required: true]],
                 max_tokens: 128,
                 temperature: 0.2,
                 max_retries: 0,
                 receive_timeout: 5_000,
                 on_finch_request: redirect,
                 provider_options: provider_options
               )

      assert {:ok, response} = StreamResponse.to_response(stream)
      assert response.object == %{"name" => "Lyon"}
      assert response.usage.input_tokens == 17
      assert response.usage.output_tokens == 9

      assert_receive {:signed_request, request}
      assert request.host == "bedrock-runtime.eu-west-1.amazonaws.com"
      headers = Map.new(request.headers)
      assert headers["authorization"] =~ "AWS4-HMAC-SHA256"
      assert headers["x-amz-security-token"] == "sessionTEST"

      assert_receive {:request, path, body}

      model_id =
        if profile?,
          do: URI.encode(@arn, &URI.char_unreserved?/1),
          else: "eu.anthropic.claude-haiku-4-5-20251001-v1:0"

      route = if use_converse, do: "converse-stream", else: "invoke-with-response-stream"
      assert path == "/model/#{model_id}/#{route}"

      schema = assert_request_body(body, use_converse, mode)
      assert schema["properties"]["name"]["type"] == "string"
      assert schema["required"] == ["name"]
    end
  end

  defp assert_request_body(body, true, mode) do
    assert body["inferenceConfig"]["maxTokens"] == 128
    assert body["inferenceConfig"]["temperature"] == 0.2

    if mode == :auto do
      assert [
               %{
                 "toolSpec" => %{
                   "name" => "structured_output",
                   "inputSchema" => %{"json" => schema}
                 }
               }
             ] =
               body["toolConfig"]["tools"]

      assert body["toolConfig"]["toolChoice"] == %{"tool" => %{"name" => "structured_output"}}
      schema
    else
      format = body["outputConfig"]["textFormat"]
      assert format["type"] == "json_schema"
      refute Map.has_key?(body, "toolConfig")
      schema = Jason.decode!(format["structure"]["jsonSchema"]["schema"])
      assert schema["additionalProperties"] == false
      schema
    end
  end

  defp assert_request_body(body, false, mode) do
    assert body["max_tokens"] == 128
    assert body["temperature"] == 0.2

    if mode == :auto do
      assert [%{"name" => "structured_output", "input_schema" => schema}] = body["tools"]
      assert body["tool_choice"] == %{"type" => "tool", "name" => "structured_output"}
      schema
    else
      format = body["output_config"]["format"]
      assert format["type"] == "json_schema"
      refute Map.has_key?(body, "tools")
      assert format["schema"]["additionalProperties"] == false
      format["schema"]
    end
  end

  defp events(true, mode) do
    {start, delta, reason} =
      if mode == :auto do
        {%{"toolUse" => %{"toolUseId" => "call_city", "name" => "structured_output"}},
         %{"toolUse" => %{"input" => ~s({"name":)}}, "tool_use"}
      else
        {%{}, %{"text" => ~s({"name":)}, "end_turn"}
      end

    [
      {"messageStart", %{"role" => "assistant"}},
      {"contentBlockStart", %{"contentBlockIndex" => 0, "start" => start}},
      {"contentBlockDelta", %{"contentBlockIndex" => 0, "delta" => delta}},
      {"contentBlockDelta",
       %{
         "contentBlockIndex" => 0,
         "delta" =>
           if(mode == :auto,
             do: %{"toolUse" => %{"input" => ~s("Lyon"})}},
             else: %{"text" => ~s("Lyon"})}
           )
       }},
      {"contentBlockStop", %{"contentBlockIndex" => 0}},
      {"messageStop", %{"stopReason" => reason}},
      {"metadata", %{"usage" => %{"inputTokens" => 17, "outputTokens" => 9, "totalTokens" => 26}}}
    ]
  end

  defp events(false, mode) do
    {block, delta, reason} =
      if mode == :auto do
        {%{
           "type" => "tool_use",
           "id" => "call_city",
           "name" => "structured_output",
           "input" => %{}
         }, %{"type" => "input_json_delta", "partial_json" => ~s({"name":)}, "tool_use"}
      else
        {%{"type" => "text", "text" => ""}, %{"type" => "text_delta", "text" => ~s({"name":)},
         "end_turn"}
      end

    [
      %{
        "type" => "message_start",
        "message" => %{
          "id" => "msg_city",
          "role" => "assistant",
          "content" => [],
          "usage" => %{"input_tokens" => 17, "output_tokens" => 0}
        }
      },
      %{"type" => "content_block_start", "index" => 0, "content_block" => block},
      %{"type" => "content_block_delta", "index" => 0, "delta" => delta},
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" =>
          if(mode == :auto,
            do: %{"type" => "input_json_delta", "partial_json" => ~s("Lyon"})},
            else: %{"type" => "text_delta", "text" => ~s("Lyon"})}
          )
      },
      %{"type" => "content_block_stop", "index" => 0},
      %{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => reason},
        "usage" => %{"output_tokens" => 9}
      },
      %{"type" => "message_stop"}
    ]
  end

  defp encode_event(event, false) do
    encode_event({"chunk", %{"bytes" => event |> Jason.encode!() |> Base.encode64()}}, true)
  end

  defp encode_event({event_type, payload}, true) do
    headers =
      Enum.map_join(
        [
          {":message-type", "event"},
          {":event-type", event_type},
          {":content-type", "application/json"}
        ],
        fn {name, value} ->
          <<byte_size(name)::8, name::binary, 7::8, byte_size(value)::16, value::binary>>
        end
      )

    payload = Jason.encode!(payload)
    prelude = <<16 + byte_size(headers) + byte_size(payload)::32, byte_size(headers)::32>>
    message = <<prelude::binary, :erlang.crc32(prelude)::32, headers::binary, payload::binary>>
    <<message::binary, :erlang.crc32(message)::32>>
  end
end
