defmodule Provider.OpenAI.ResponsesAPI.RequestEncodingTest do
  use ExUnit.Case, async: false

  import ReqLLM.Test.OpenAI.ResponsesAPIHelpers, only: [build_request: 1]

  alias ReqLLM.Providers.OpenAI
  alias ReqLLM.Providers.OpenAI.ResponsesAPI

  describe "path/0" do
    test "returns correct endpoint path" do
      assert ResponsesAPI.path() == "/responses"
    end
  end

  describe "encode_body/1" do
    test "encodes basic request with max_output_tokens" do
      request = build_request(max_output_tokens: 1000)

      encoded = ResponsesAPI.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(encoded)

      assert body["max_output_tokens"] == 1000
      assert body["model"] == "gpt-5"
      assert body["stream"] == nil
    end

    test "normalizes max_completion_tokens to max_output_tokens" do
      request = build_request(max_completion_tokens: 2048)

      encoded = ResponsesAPI.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(encoded)

      assert body["max_output_tokens"] == 2048
    end

    test "normalizes max_tokens to max_output_tokens" do
      request = build_request(max_tokens: 512)

      encoded = ResponsesAPI.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(encoded)

      assert body["max_output_tokens"] == 512
    end

    test "prioritizes max_output_tokens over other token limits" do
      request =
        build_request(
          max_output_tokens: 1000,
          max_completion_tokens: 2000,
          max_tokens: 3000
        )

      encoded = ResponsesAPI.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(encoded)

      assert body["max_output_tokens"] == 1000
    end

    test "encodes streaming request" do
      request = build_request(stream: true)

      encoded = ResponsesAPI.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(encoded)

      assert body["stream"] == true
    end

    test "omits access_programs unless explicitly selected" do
      model = ReqLLM.model!("openai:gpt-5")
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])
      opts = [api_key: "test-key"]

      assert {:ok, request} = OpenAI.prepare_request(:chat, model, context, opts)
      body = request |> OpenAI.encode_body() |> ReqLLM.Test.Helpers.json_body()
      refute Map.has_key?(body, "access_programs")

      assert {:ok, stream} = OpenAI.attach_stream(model, context, opts, ReqLLM.Finch)
      refute Map.has_key?(Jason.decode!(stream.body), "access_programs")

      assert {:ok, %{initial_messages: [event]}} =
               OpenAI.attach_websocket_stream(model, context, opts)

      refute Map.has_key?(Jason.decode!(event), "access_programs")
    end

    test "encodes the validated access program on buffered and streaming Responses requests" do
      model = ReqLLM.model!("openai:gpt-5")
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      for programs <- [%{cyber: "daybreak_blue"}, %{"cyber" => "daybreak_blue"}] do
        opts = [api_key: "test-key", provider_options: [access_programs: programs]]

        assert {:ok, request} = OpenAI.prepare_request(:chat, model, context, opts)
        assert request.url.path == "/responses"

        buffered = request |> OpenAI.encode_body() |> ReqLLM.Test.Helpers.json_body()
        assert buffered["access_programs"] == %{"cyber" => "daybreak_blue"}

        assert {:ok, stream} = OpenAI.attach_stream(model, context, opts, ReqLLM.Finch)
        assert Jason.decode!(stream.body)["access_programs"] == %{"cyber" => "daybreak_blue"}
      end
    end

    test "validates the access program and rejects unknown fields and invalid values" do
      model = ReqLLM.model!("openai:gpt-5")

      for program <- ~w(standard daybreak_blue daybreak_red) do
        assert {:ok, request} =
                 OpenAI.prepare_request(:chat, model, "Hello",
                   api_key: "test-key",
                   provider_options: [access_programs: %{"cyber" => program}]
                 )

        assert request
               |> OpenAI.encode_body()
               |> ReqLLM.Test.Helpers.json_body()
               |> Map.get("access_programs") ==
                 %{"cyber" => program}
      end

      for invalid <- [
            nil,
            [],
            %{},
            "daybreak_blue",
            %{cyber: :daybreak_blue},
            %{"cyber" => "unknown"},
            %{"other" => "daybreak_blue"},
            %{"cyber" => "standard", "other" => "daybreak_blue"},
            %{"cyber" => "daybreak_red", cyber: "standard"}
          ] do
        assert {:error, error} =
                 OpenAI.prepare_request(:chat, model, "Hello",
                   api_key: "test-key",
                   provider_options: [access_programs: invalid]
                 )

        assert Exception.message(error) =~ "access_programs"
      end
    end

    test "rejects access_programs when the model routes to Chat Completions" do
      model = %LLMDB.Model{
        provider: :openai,
        id: "gpt-4",
        extra: %{wire: %{protocol: "openai_chat"}}
      }

      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])
      opts = [api_key: "test-key", provider_options: [access_programs: %{cyber: "standard"}]]

      assert {:error, %ReqLLM.Error.Invalid.Parameter{parameter: parameter}} =
               OpenAI.prepare_request(:chat, model, context, opts)

      assert parameter =~ "access_programs requires an OpenAI Responses API generation request"

      assert_raise ReqLLM.Error.Invalid.Parameter, ~r/access_programs requires/, fn ->
        OpenAI.attach_stream(model, context, opts, ReqLLM.Finch)
      end
    end

    test "encodes top-level and nested access_programs on WebSocket requests" do
      model = ReqLLM.model!("openai:gpt-5")
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])
      programs = %{cyber: "standard"}

      for opts <- [[access_programs: programs], [provider_options: [access_programs: programs]]] do
        assert {:ok, %{initial_messages: [event]}} =
                 OpenAI.attach_websocket_stream(model, context, [api_key: "test-key"] ++ opts)

        assert Jason.decode!(event)["access_programs"] == %{"cyber" => "standard"}
      end
    end

    test "rejects invalid access_programs before sending a WebSocket request" do
      model = ReqLLM.model!("openai:gpt-5")
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      for invalid <- [nil, %{"cyber" => "unknown"}] do
        opts = [api_key: "test-key", provider_options: [access_programs: invalid]]

        assert {:error, %ReqLLM.Error.API.Request{reason: reason}} =
                 OpenAI.attach_websocket_stream(model, context, opts)

        assert reason =~ "access_programs"
      end
    end

    test "encodes explicit prompt cache controls" do
      breakpoint = %{mode: "explicit"}

      context =
        ReqLLM.Context.new([
          ReqLLM.Context.user([
            ReqLLM.Message.ContentPart.text("Stable text", %{
              prompt_cache_breakpoint: breakpoint
            }),
            ReqLLM.Message.ContentPart.image_url("https://example.com/image.png", %{
              "prompt_cache_breakpoint" => breakpoint
            }),
            ReqLLM.Message.ContentPart.file_id("file_123", %{
              prompt_cache_breakpoint: breakpoint
            })
          ])
        ])

      request =
        build_request(
          context: context,
          provider_options: [
            prompt_cache_key: "tenant:acme:knowledge-v1",
            prompt_cache_options: %{mode: "explicit", ttl: "30m"}
          ]
        )

      body = request |> ResponsesAPI.encode_body() |> ReqLLM.Test.Helpers.json_body()

      assert body["prompt_cache_key"] == "tenant:acme:knowledge-v1"
      assert body["prompt_cache_options"] == %{"mode" => "explicit", "ttl" => "30m"}

      assert [%{"content" => [text_block, image_block, file_block]}] = body["input"]
      assert text_block["prompt_cache_breakpoint"] == %{"mode" => "explicit"}
      assert image_block["prompt_cache_breakpoint"] == %{"mode" => "explicit"}
      assert file_block["prompt_cache_breakpoint"] == %{"mode" => "explicit"}
    end

    test "encodes image detail from content part metadata" do
      context =
        ReqLLM.Context.new([
          ReqLLM.Context.user([
            ReqLLM.Message.ContentPart.image_url("https://example.com/low.png", %{detail: :low}),
            ReqLLM.Message.ContentPart.image(<<1, 2, 3>>, "image/png", %{"detail" => "high"}),
            ReqLLM.Message.ContentPart.image_url("https://example.com/plain.png")
          ])
        ])

      body =
        build_request(context: context)
        |> ResponsesAPI.encode_body()
        |> ReqLLM.Test.Helpers.json_body()

      assert [%{"content" => [low_block, high_block, plain_block]}] = body["input"]
      assert low_block["detail"] == "low"
      assert high_block["detail"] == "high"
      refute Map.has_key?(plain_block, "detail")
    end

    test "does not emit unverified-model warnings when the request uses the id field" do
      warning =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          request = build_request([])

          encoded = ResponsesAPI.encode_body(request)
          body = ReqLLM.Test.Helpers.json_body(encoded)

          assert body["model"] == "gpt-5"
        end)

      assert warning == ""
    end

    test "encodes file_id content parts as input_file items" do
      file_part = ReqLLM.Message.ContentPart.file_id("file-6F2ksmvXxt4VdoqmHRw6kL")

      context = %ReqLLM.Context{
        messages: [
          %ReqLLM.Message{
            role: :user,
            content: [
              ReqLLM.Message.ContentPart.text("Summarize this file"),
              file_part
            ]
          }
        ]
      }

      request = build_request(context: context)

      encoded = ResponsesAPI.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(encoded)

      assert [
               %{
                 "role" => "user",
                 "content" => [
                   %{"type" => "input_text", "text" => "Summarize this file"},
                   %{"type" => "input_file", "file_id" => "file-6F2ksmvXxt4VdoqmHRw6kL"}
                 ]
               }
             ] = body["input"]
    end

    test "encodes explicitly owned OpenAI file references without ownership metadata" do
      file_part =
        ReqLLM.Message.ContentPart.owned_file_id("file-owned", :openai,
          purpose: :assistants,
          status: :processed
        )

      context = %ReqLLM.Context{
        messages: [
          %ReqLLM.Message{
            role: :user,
            content: [file_part]
          }
        ]
      }

      body = context |> then(&build_request(context: &1)) |> ResponsesAPI.encode_body()
      decoded = ReqLLM.Test.Helpers.json_body(body)

      assert [%{"content" => [%{"type" => "input_file", "file_id" => "file-owned"}]}] =
               decoded["input"]

      refute Jason.encode!(decoded) =~ "req_llm"
    end

    test "encodes input messages correctly" do
      msg1 = %ReqLLM.Message{
        role: :user,
        content: [%ReqLLM.Message.ContentPart{type: :text, text: "Hello"}]
      }

      msg2 = %ReqLLM.Message{
        role: :assistant,
        content: [%ReqLLM.Message.ContentPart{type: :text, text: "Hi there"}]
      }

      context = %ReqLLM.Context{messages: [msg1, msg2]}
      request = build_request(context: context)

      encoded = ResponsesAPI.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(encoded)

      assert [input1, input2] = body["input"]
      assert input1["role"] == "user"
      assert input1["content"] == [%{"type" => "input_text", "text" => "Hello"}]
      assert input2["role"] == "assistant"
      assert input2["content"] == [%{"type" => "output_text", "text" => "Hi there"}]
    end

    test "encodes response_format with keyword list schema (converts to JSON schema)" do
      keyword_schema = [
        name: [type: :string, required: true, doc: "Person name"],
        age: [type: :pos_integer, doc: "Person age"]
      ]

      response_format = %{
        type: "json_schema",
        json_schema: %{
          name: "person_schema",
          strict: true,
          schema: keyword_schema
        }
      }

      request = build_request(provider_options: [response_format: response_format])

      encoded = ResponsesAPI.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(encoded)

      assert body["text"]["format"]["type"] == "json_schema"
      assert body["text"]["format"]["name"] == "person_schema"
      assert body["text"]["format"]["strict"] == true
      assert body["text"]["format"]["schema"]["type"] == "object"
      assert body["text"]["format"]["schema"]["properties"]["name"]["type"] == "string"
      assert body["text"]["format"]["schema"]["properties"]["age"]["type"] == "integer"
      assert body["text"]["format"]["schema"]["properties"]["age"]["minimum"] == 1
      assert body["text"]["format"]["schema"]["required"] == ["name"]

      # propertyOrdering is consumed during encoding — verify wire order instead
      refute Map.has_key?(body["text"]["format"]["schema"], "propertyOrdering")

      # Verify the actual JSON wire order of properties
      assert IO.iodata_to_binary(ReqLLM.Test.Helpers.json_iodata(encoded)) =~
               ~r/"properties"\s*:\s*\{\s*"name".*"age"/s
    end

    test "encodes response_format with direct JSON schema (pass-through)" do
      json_schema = %{
        "type" => "object",
        "properties" => %{
          "location" => %{"type" => "string", "description" => "City name"},
          "units" => %{"type" => "string", "enum" => ["celsius", "fahrenheit"]}
        },
        "required" => ["location"],
        "additionalProperties" => false
      }

      response_format = %{
        type: "json_schema",
        json_schema: %{
          name: "weather_schema",
          strict: true,
          schema: json_schema
        }
      }

      request = build_request(provider_options: [response_format: response_format])

      encoded = ResponsesAPI.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(encoded)

      assert body["text"]["format"]["type"] == "json_schema"
      assert body["text"]["format"]["name"] == "weather_schema"
      assert body["text"]["format"]["strict"] == true
      # Schema should pass through unchanged
      assert body["text"]["format"]["schema"] == json_schema
    end

    test "encodes response_format with string keys" do
      json_schema = %{
        "type" => "object",
        "properties" => %{"query" => %{"type" => "string"}},
        "required" => ["query"]
      }

      response_format = %{
        "type" => "json_schema",
        "json_schema" => %{
          "name" => "search_schema",
          "strict" => true,
          "schema" => json_schema
        }
      }

      request = build_request(provider_options: [response_format: response_format])

      encoded = ResponsesAPI.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(encoded)

      assert body["text"]["format"]["type"] == "json_schema"
      assert body["text"]["format"]["name"] == "search_schema"
      assert body["text"]["format"]["strict"] == true
      assert body["text"]["format"]["schema"] == json_schema
    end

    test "encodes verbosity when provided as atom" do
      request = build_request(provider_options: [verbosity: :low])

      encoded = ResponsesAPI.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(encoded)

      assert body["text"]["verbosity"] == "low"
    end

    test "encodes verbosity when provided as string" do
      request = build_request(provider_options: [verbosity: "high"])

      encoded = ResponsesAPI.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(encoded)

      assert body["text"]["verbosity"] == "high"
    end

    test "omits text field when no verbosity or response_format" do
      request = build_request(provider_options: [])

      encoded = ResponsesAPI.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(encoded)

      refute Map.has_key?(body, "text")
    end

    test "encodes verbosity alongside response_format in text object" do
      json_schema = %{
        "type" => "object",
        "properties" => %{"name" => %{"type" => "string"}},
        "required" => ["name"]
      }

      response_format = %{
        type: "json_schema",
        json_schema: %{
          name: "test_schema",
          strict: true,
          schema: json_schema
        }
      }

      request =
        build_request(provider_options: [response_format: response_format, verbosity: :medium])

      encoded = ResponsesAPI.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(encoded)

      assert body["text"]["format"]["type"] == "json_schema"
      assert body["text"]["format"]["name"] == "test_schema"
      assert body["text"]["verbosity"] == "medium"
    end
  end
end
