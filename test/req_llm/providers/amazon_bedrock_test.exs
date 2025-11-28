defmodule ReqLLM.Providers.AmazonBedrockTest do
  use ExUnit.Case, async: true

  alias ReqLLM.{Context, Providers.AmazonBedrock}

  describe "provider basics" do
    test "provider_id returns :amazon_bedrock" do
      assert AmazonBedrock.provider_id() == :amazon_bedrock
    end

    test "default_base_url returns Bedrock endpoint format" do
      url = AmazonBedrock.base_url()
      assert url =~ "bedrock-runtime"
      assert url =~ "amazonaws.com"
    end
  end

  describe "parse_stream_protocol/2" do
    test "parses AWS Event Stream binary data" do
      # Create a simple AWS Event Stream message
      payload = Jason.encode!(%{"type" => "chunk", "data" => "test"})
      binary = build_aws_event_stream_message(payload)

      assert {:ok, events, rest} = AmazonBedrock.parse_stream_protocol(binary, <<>>)
      refute Enum.empty?(events)
      assert rest == <<>>
    end

    test "handles incomplete data" do
      # Incomplete prelude
      partial = <<0, 0, 0, 100>>

      assert {:incomplete, buffer} = AmazonBedrock.parse_stream_protocol(partial, <<>>)
      assert buffer == partial
    end

    test "accumulates with buffer" do
      # Split a message across two chunks
      payload = Jason.encode!(%{"test" => "data"})
      full_message = build_aws_event_stream_message(payload)

      split = div(byte_size(full_message), 2)
      part1 = binary_part(full_message, 0, split)
      part2 = binary_part(full_message, split, byte_size(full_message) - split)

      # First chunk should be incomplete
      assert {:incomplete, buffer} = AmazonBedrock.parse_stream_protocol(part1, <<>>)

      # Second chunk should complete the message
      assert {:ok, events, <<>>} = AmazonBedrock.parse_stream_protocol(part2, buffer)
      assert length(events) == 1
    end
  end

  describe "unwrap_stream_chunk/1" do
    alias ReqLLM.Providers.AmazonBedrock.Response

    test "unwraps AWS SDK format with chunk wrapper" do
      event = %{"type" => "content_block_delta", "delta" => %{"text" => "hello"}}
      encoded = Base.encode64(Jason.encode!(event))
      chunk = %{"chunk" => %{"bytes" => encoded}}

      assert {:ok, unwrapped} = Response.unwrap_stream_chunk(chunk)
      assert unwrapped == event
    end

    test "unwraps direct bytes format" do
      event = %{"type" => "message_start", "message" => %{"id" => "msg_123"}}
      encoded = Base.encode64(Jason.encode!(event))
      chunk = %{"bytes" => encoded}

      assert {:ok, unwrapped} = Response.unwrap_stream_chunk(chunk)
      assert unwrapped == event
    end

    test "passes through already decoded events" do
      event = %{"type" => "message_stop"}
      chunk = event

      assert {:ok, unwrapped} = Response.unwrap_stream_chunk(chunk)
      assert unwrapped == event
    end

    test "returns error for unknown format" do
      chunk = %{"unknown" => "format"}

      assert {:error, :unknown_chunk_format} = Response.unwrap_stream_chunk(chunk)
    end

    test "returns error for invalid base64" do
      chunk = %{"bytes" => "invalid-base64!!!"}

      assert {:error, {:unwrap_failed, _}} = Response.unwrap_stream_chunk(chunk)
    end

    test "returns error for invalid JSON" do
      encoded = Base.encode64("not valid json")
      chunk = %{"bytes" => encoded}

      assert {:error, {:unwrap_failed, _}} = Response.unwrap_stream_chunk(chunk)
    end
  end

  describe "multi-turn tool calling with Converse API" do
    test "encodes complete multi-turn conversation with tool results" do
      alias ReqLLM.ToolCall
      # Set up AWS credentials for test
      System.put_env("AWS_ACCESS_KEY_ID", "AKIATEST")
      System.put_env("AWS_SECRET_ACCESS_KEY", "secretTEST")
      System.put_env("AWS_REGION", "us-east-1")

      # Simulate a complete tool calling flow using Converse API
      {:ok, model} = ReqLLM.model("amazon-bedrock:anthropic.claude-3-haiku-20240307-v1:0")

      # Create tool call using new ToolCall API
      tool_call = ToolCall.new("toolu_add_123", "add", Jason.encode!(%{a: 5, b: 3}))

      messages = [
        Context.system("You are a calculator"),
        Context.user("What is 5 + 3?"),
        Context.assistant("I'll calculate that for you.", tool_calls: [tool_call]),
        Context.tool_result("toolu_add_123", "8")
      ]

      context = Context.new(messages)

      # Define a simple tool
      tools = [
        ReqLLM.Tool.new!(
          name: "add",
          description: "Add two numbers",
          parameter_schema: [
            a: [type: :integer, required: true],
            b: [type: :integer, required: true]
          ],
          callback: fn %{a: a, b: b} -> {:ok, a + b} end
        )
      ]

      opts = [
        tools: tools,
        use_converse: true,
        access_key_id: "AKIATEST",
        secret_access_key: "secretTEST"
      ]

      # Test that prepare_request works with tool calling
      {:ok, request} = AmazonBedrock.prepare_request(:chat, model, context, opts)

      assert %Req.Request{} = request
      # Should use Converse API endpoint when tools are present
      assert request.url.path =~ "/converse"

      # Verify the body is properly encoded
      body = Jason.decode!(request.body)

      # Verify system instruction
      assert body["system"] == [%{"text" => "You are a calculator"}]

      # Verify messages structure
      assert is_list(body["messages"])
      assert length(body["messages"]) == 3

      [user_msg, assistant_msg, tool_result_msg] = body["messages"]

      # User message
      assert user_msg["role"] == "user"
      assert user_msg["content"] == [%{"text" => "What is 5 + 3?"}]

      # Assistant message with tool call
      assert assistant_msg["role"] == "assistant"
      assert is_list(assistant_msg["content"])
      assert length(assistant_msg["content"]) == 2

      [text_block, tool_use_block] = assistant_msg["content"]
      assert text_block["text"] == "I'll calculate that for you."
      assert tool_use_block["toolUse"]["toolUseId"] == "toolu_add_123"
      assert tool_use_block["toolUse"]["name"] == "add"
      assert tool_use_block["toolUse"]["input"] == %{"a" => 5, "b" => 3}

      # Tool result message (Converse API uses "user" role)
      assert tool_result_msg["role"] == "user",
             "Converse API requires tool results in 'user' role"

      assert is_list(tool_result_msg["content"])
      [tool_result_block] = tool_result_msg["content"]

      assert tool_result_block["toolResult"]["toolUseId"] == "toolu_add_123"
      assert tool_result_block["toolResult"]["content"] == [%{"text" => "8"}]

      # Verify toolConfig is present
      assert body["toolConfig"]
      assert is_list(body["toolConfig"]["tools"])
      assert length(body["toolConfig"]["tools"]) == 1

      [tool_spec] = body["toolConfig"]["tools"]
      assert tool_spec["toolSpec"]["name"] == "add"
    end

    test "encodes multi-turn tool calling with native Anthropic endpoint" do
      alias ReqLLM.ToolCall
      # Test with native Anthropic endpoint (not Converse API)
      System.put_env("AWS_ACCESS_KEY_ID", "AKIATEST")
      System.put_env("AWS_SECRET_ACCESS_KEY", "secretTEST")

      {:ok, model} = ReqLLM.model("amazon-bedrock:anthropic.claude-3-haiku-20240307-v1:0")

      # Create tool call using new ToolCall API
      tool_call = ToolCall.new("toolu_add_123", "add", Jason.encode!(%{a: 5, b: 3}))

      messages = [
        Context.system("You are a calculator"),
        Context.user("What is 5 + 3?"),
        Context.assistant("I'll calculate that for you.", tool_calls: [tool_call]),
        Context.tool_result("toolu_add_123", "8")
      ]

      context = Context.new(messages)

      opts = [
        use_converse: false,
        access_key_id: "AKIATEST",
        secret_access_key: "secretTEST"
      ]

      # Test that prepare_request works without forcing Converse
      {:ok, request} = AmazonBedrock.prepare_request(:chat, model, context, opts)

      # Should use native Anthropic endpoint when use_converse is false
      assert request.url.path =~ "/invoke"
      refute request.url.path =~ "/converse"

      # Verify the body uses native Anthropic format (via delegation)
      body = Jason.decode!(request.body)

      # Native Anthropic format has different structure than Converse
      assert body["anthropic_version"] == "bedrock-2023-05-31"
      assert body["system"] == "You are a calculator"

      # Check messages are encoded with role transformation
      assert is_list(body["messages"])
      [_user_msg, _assistant_msg, tool_result_msg] = body["messages"]

      # Tool result should use "user" role (Anthropic only accepts user/assistant)
      assert tool_result_msg["role"] == "user",
             "Native Anthropic API requires tool results in 'user' role"

      # Verify tool_result content block structure
      [tool_result_block] = tool_result_msg["content"]
      assert tool_result_block["type"] == "tool_result"
      assert tool_result_block["tool_use_id"] == "toolu_add_123"
      assert tool_result_block["content"] == "8"
    end
  end

  describe "AWS session token support" do
    test "includes session token in signed Req request headers" do
      # Test non-streaming path (Req pipeline via put_aws_sigv4)
      {:ok, model} = ReqLLM.model("amazon-bedrock:anthropic.claude-3-haiku-20240307-v1:0")
      context = Context.new([Context.user("Hello")])
      session_token = "FwoGZXIvYXdzEBYaDHhBTEMPLESessionToken123"

      opts = [
        access_key_id: "AKIATEST",
        secret_access_key: "secretTEST",
        region: "us-east-1",
        session_token: session_token
      ]

      # Build request using prepare_request
      {:ok, request} = AmazonBedrock.prepare_request(:chat, model, context, opts)

      # The request should have the AWS SigV4 signing step attached
      assert %Req.Request{} = request

      # Manually trigger the request steps to verify signing behavior
      # The aws_sigv4 step should add the session token header
      signed_request =
        request.request_steps
        |> Enum.reduce(request, fn {_name, step}, req ->
          step.(req)
        end)

      # Check that signed headers include session token
      headers_map =
        Map.new(signed_request.headers, fn
          {k, [v | _]} -> {String.downcase(k), v}
          {k, v} -> {String.downcase(k), v}
        end)

      assert headers_map["x-amz-security-token"] == session_token

      # Verify proper AWS4-HMAC-SHA256 signature with token
      auth_header = headers_map["authorization"]
      assert auth_header =~ "AWS4-HMAC-SHA256"
      assert auth_header =~ "x-amz-security-token"
    end
  end

  describe "attach_stream/4" do
    setup do
      {:ok, model} = ReqLLM.model("amazon-bedrock:anthropic.claude-3-haiku-20240307-v1:0")
      context = Context.new([Context.user("Hello")])

      opts = [
        access_key_id: "AKIATEST",
        secret_access_key: "secretTEST",
        region: "us-east-1"
      ]

      {:ok, model: model, context: context, opts: opts}
    end

    test "builds Finch.Request for streaming", %{model: model, context: context, opts: opts} do
      assert {:ok, finch_request} =
               AmazonBedrock.attach_stream(model, context, opts, ReqLLM.Finch)

      assert %Finch.Request{} = finch_request
      assert finch_request.method == "POST"
      assert finch_request.path =~ "/model/"
      assert finch_request.path =~ "/invoke-with-response-stream"
    end

    test "includes proper headers", %{model: model, context: context, opts: opts} do
      assert {:ok, finch_request} =
               AmazonBedrock.attach_stream(model, context, opts, ReqLLM.Finch)

      headers_map = Map.new(finch_request.headers)
      assert headers_map["content-type"] == "application/json"
      assert headers_map["accept"] == "application/vnd.amazon.eventstream"
      assert Map.has_key?(headers_map, "authorization")
    end

    test "signs request with AWS SigV4", %{model: model, context: context, opts: opts} do
      assert {:ok, finch_request} =
               AmazonBedrock.attach_stream(model, context, opts, ReqLLM.Finch)

      # Check for AWS signature in authorization header
      auth_header = Enum.find(finch_request.headers, fn {k, _} -> k == "authorization" end)
      assert auth_header != nil
      {_, auth_value} = auth_header
      assert auth_value =~ "AWS4-HMAC-SHA256"
    end

    test "uses correct region", %{model: model, context: context, opts: opts} do
      custom_opts = Keyword.put(opts, :region, "eu-west-1")

      assert {:ok, finch_request} =
               AmazonBedrock.attach_stream(model, context, custom_opts, ReqLLM.Finch)

      assert finch_request.host =~ "eu-west-1"
    end

    test "includes session token in signed request", %{model: model, context: context, opts: opts} do
      session_token = "FwoGZXIvYXdzEBYaDHhBTEMPLESessionToken123"
      opts_with_token = Keyword.put(opts, :session_token, session_token)

      assert {:ok, finch_request} =
               AmazonBedrock.attach_stream(model, context, opts_with_token, ReqLLM.Finch)

      # Verify session token is included in headers
      headers_map = Map.new(finch_request.headers)
      assert headers_map["x-amz-security-token"] == session_token

      # Verify the request is still properly signed with the session token
      auth_header = headers_map["authorization"]
      assert auth_header != nil
      assert auth_header =~ "AWS4-HMAC-SHA256"
      # Session token should be included in the signed headers list
      assert auth_header =~ "x-amz-security-token"
    end
  end

  describe "service_tier parameter" do
    test "includes service_tier in request body when specified" do
      System.put_env("AWS_ACCESS_KEY_ID", "AKIATEST")
      System.put_env("AWS_SECRET_ACCESS_KEY", "secretTEST")

      {:ok, model} = ReqLLM.model("amazon-bedrock:anthropic.claude-3-haiku-20240307-v1:0")

      messages = [Context.user("Hello")]
      context = Context.new(messages)

      opts = [
        access_key_id: "AKIATEST",
        secret_access_key: "secretTEST",
        service_tier: "priority"
      ]

      {:ok, request} = AmazonBedrock.prepare_request(:chat, model, context, opts)

      assert %Req.Request{} = request
      body = Jason.decode!(request.body)
      assert body["service_tier"] == "priority"
    end

    test "includes service_tier=flex in request body" do
      System.put_env("AWS_ACCESS_KEY_ID", "AKIATEST")
      System.put_env("AWS_SECRET_ACCESS_KEY", "secretTEST")

      {:ok, model} = ReqLLM.model("amazon-bedrock:anthropic.claude-3-haiku-20240307-v1:0")

      messages = [Context.user("Hello")]
      context = Context.new(messages)

      opts = [
        access_key_id: "AKIATEST",
        secret_access_key: "secretTEST",
        service_tier: "flex"
      ]

      {:ok, request} = AmazonBedrock.prepare_request(:chat, model, context, opts)

      body = Jason.decode!(request.body)
      assert body["service_tier"] == "flex"
    end

    test "omits service_tier when default" do
      System.put_env("AWS_ACCESS_KEY_ID", "AKIATEST")
      System.put_env("AWS_SECRET_ACCESS_KEY", "secretTEST")

      {:ok, model} = ReqLLM.model("amazon-bedrock:anthropic.claude-3-haiku-20240307-v1:0")

      messages = [Context.user("Hello")]
      context = Context.new(messages)

      opts = [
        access_key_id: "AKIATEST",
        secret_access_key: "secretTEST",
        service_tier: "default"
      ]

      {:ok, request} = AmazonBedrock.prepare_request(:chat, model, context, opts)

      body = Jason.decode!(request.body)
      refute Map.has_key?(body, "service_tier")
    end

    test "omits service_tier when not specified" do
      System.put_env("AWS_ACCESS_KEY_ID", "AKIATEST")
      System.put_env("AWS_SECRET_ACCESS_KEY", "secretTEST")

      {:ok, model} = ReqLLM.model("amazon-bedrock:anthropic.claude-3-haiku-20240307-v1:0")

      messages = [Context.user("Hello")]
      context = Context.new(messages)

      opts = [
        access_key_id: "AKIATEST",
        secret_access_key: "secretTEST"
      ]

      {:ok, request} = AmazonBedrock.prepare_request(:chat, model, context, opts)

      body = Jason.decode!(request.body)
      refute Map.has_key?(body, "service_tier")
    end
  end

  # Helper to build a valid AWS Event Stream message for testing
  defp build_aws_event_stream_message(payload) when is_binary(payload) do
    headers = <<>>
    headers_length = byte_size(headers)
    payload_length = byte_size(payload)
    total_length = 16 + headers_length + payload_length

    # Calculate prelude CRC
    prelude = <<total_length::32-big, headers_length::32-big>>
    prelude_crc = :erlang.crc32(prelude)

    # Calculate message CRC
    message_without_crc = <<
      prelude::binary,
      prelude_crc::32,
      headers::binary,
      payload::binary
    >>

    message_crc = :erlang.crc32(message_without_crc)

    <<
      total_length::32-big,
      headers_length::32-big,
      prelude_crc::32,
      headers::binary,
      payload::binary,
      message_crc::32
    >>
  end
end
