defmodule ReqLLM.Providers.MinimaxTest do
  use ReqLLM.ProviderCase, provider: ReqLLM.Providers.Minimax

  alias ReqLLM.Context
  alias ReqLLM.Message.ReasoningDetails
  alias ReqLLM.Provider.ResponseBuilder
  alias ReqLLM.Providers.Minimax
  alias ReqLLM.Providers.Minimax.ImagesAPI
  alias ReqLLM.StreamChunk
  alias ReqLLM.ToolCall

  defp minimax_model(model_id \\ "MiniMax-M2.7") do
    %LLMDB.Model{
      id: model_id,
      model: model_id,
      provider_model_id: model_id,
      provider: :minimax,
      name: model_id,
      family: "minimax-m2",
      capabilities: %{chat: true, tools: %{enabled: true}},
      limits: %{context: 204_800, output: 2048},
      extra: %{wire: %{protocol: "openai_chat"}}
    }
  end

  defp minimax_image_model(model_id \\ "image-01") do
    %LLMDB.Model{
      id: model_id,
      model: model_id,
      provider_model_id: model_id,
      provider: :minimax,
      name: model_id,
      family: "minimax-image",
      capabilities: %{images: true},
      limits: %{},
      extra: %{}
    }
  end

  describe "provider contract" do
    test "provider identity and configuration" do
      assert Minimax.provider_id() == :minimax
      assert Minimax.base_url() == "https://api.minimax.io/v1"
      assert Minimax.default_env_key() == "MINIMAX_API_KEY"
    end

    test "provider schema exposes MiniMax-specific request fields" do
      schema_keys = Minimax.provider_schema().schema |> Keyword.keys()

      assert :max_completion_tokens in schema_keys
      assert :reasoning_split in schema_keys
      assert :prompt_optimizer in schema_keys
      assert :subject_reference in schema_keys
    end

    test "provider_extended_generation_schema includes all core keys" do
      extended_schema = Minimax.provider_extended_generation_schema()
      extended_keys = extended_schema.schema |> Keyword.keys()
      core_keys = ReqLLM.Provider.Options.all_generation_keys()
      core_without_meta = Enum.reject(core_keys, &(&1 == :provider_options))

      for core_key <- core_without_meta do
        assert core_key in extended_keys
      end
    end
  end

  describe "model fallback" do
    test "resolves native MiniMax model strings even before LLMDB catalog support" do
      assert {:ok, model} = ReqLLM.model("minimax:MiniMax-M2.7")
      assert model.provider == :minimax
      assert model.id == "MiniMax-M2.7"
      assert model.capabilities.chat == true
      assert model.limits.context == 204_800
    end
  end

  describe "request preparation" do
    test "prepare_request for :chat creates /chat/completions request" do
      {:ok, request} =
        Minimax.prepare_request(:chat, minimax_model(), "Hello world", temperature: 0.7)

      assert %Req.Request{} = request
      assert request.url.path == "/chat/completions"
      assert request.method == :post
      assert request.options[:base_url] == "https://api.minimax.io/v1"
    end

    test "prepare_request rejects embedding operations" do
      {:error, error} = Minimax.prepare_request(:embedding, minimax_model(), "Hello", [])
      assert %ReqLLM.Error.Invalid.Parameter{} = error
    end
  end

  describe "authentication wiring" do
    test "attach adds Bearer authorization header" do
      attached = Minimax.attach(Req.new(), minimax_model(), [])

      auth_header = attached.headers["authorization"]
      assert auth_header != nil
      assert String.starts_with?(List.first(auth_header), "Bearer ")
    end

    test "attach adds pipeline steps" do
      attached = Minimax.attach(Req.new(), minimax_model(), [])

      assert :llm_encode_body in Keyword.keys(attached.request_steps)
      assert :llm_decode_response in Keyword.keys(attached.response_steps)
    end
  end

  describe "option translation and body encoding" do
    test "translate_options maps max_tokens and removes ignored fields" do
      {translated, warnings} =
        Minimax.translate_options(
          :chat,
          minimax_model(),
          max_tokens: 256,
          presence_penalty: 0.1,
          frequency_penalty: 0.2,
          seed: 123,
          reasoning_effort: :high,
          reasoning_token_budget: 1000
        )

      assert translated[:max_completion_tokens] == 256
      refute Keyword.has_key?(translated, :max_tokens)
      refute Keyword.has_key?(translated, :presence_penalty)
      refute Keyword.has_key?(translated, :frequency_penalty)
      refute Keyword.has_key?(translated, :seed)
      refute Keyword.has_key?(translated, :reasoning_effort)
      refute Keyword.has_key?(translated, :reasoning_token_budget)
      assert length(warnings) == 6
    end

    test "encode_body emits MiniMax-compatible chat body" do
      request = %Req.Request{
        options: [
          context: context_fixture(),
          model: "MiniMax-M2.7",
          stream: false,
          max_tokens: 256,
          max_completion_tokens: 256,
          reasoning_split: true
        ]
      }

      encoded_request = Minimax.encode_body(request)
      decoded = ReqLLM.Test.Helpers.json_body(encoded_request)

      assert decoded["model"] == "MiniMax-M2.7"
      assert decoded["max_completion_tokens"] == 256
      assert decoded["reasoning_split"] == true
      refute Map.has_key?(decoded, "max_tokens")
      assert is_list(decoded["messages"])
    end

    test "encode_body can disable reasoning_split explicitly" do
      request = %Req.Request{
        options: [
          context: context_fixture(),
          model: "MiniMax-M2.7",
          stream: false,
          reasoning_split: false
        ]
      }

      encoded_request = Minimax.encode_body(request)
      decoded = ReqLLM.Test.Helpers.json_body(encoded_request)

      assert decoded["reasoning_split"] == false
    end

    test "encode_body converts normalized MiniMax reasoning_details back to provider wire shape" do
      reasoning_details = [
        %ReasoningDetails{
          text: "I should call the tool.\n",
          signature: "reasoning-text-1",
          encrypted?: false,
          provider: :minimax,
          format: "MiniMax-response-v1",
          index: 0,
          provider_data: %{"type" => "reasoning.text"}
        }
      ]

      context =
        Context.new([
          Context.user("Use the add tool."),
          Context.assistant("",
            tool_calls: [ToolCall.new("call_1", "add", ~s({"a":2,"b":3}))]
          )
          |> Map.put(:reasoning_details, reasoning_details)
        ])

      request = %Req.Request{
        options: [
          context: context,
          model: "MiniMax-M2.7",
          stream: false,
          reasoning_split: true
        ]
      }

      encoded_request = Minimax.encode_body(request)
      decoded = ReqLLM.Test.Helpers.json_body(encoded_request)
      assistant = Enum.at(decoded["messages"], 1)

      assert [
               %{
                 "type" => "reasoning.text",
                 "id" => "reasoning-text-1",
                 "format" => "MiniMax-response-v1",
                 "index" => 0,
                 "text" => "I should call the tool.\n"
               }
             ] = assistant["reasoning_details"]

      refute Map.has_key?(hd(assistant["reasoning_details"]), "signature")
      refute Map.has_key?(hd(assistant["reasoning_details"]), "provider")
      refute Map.has_key?(hd(assistant["reasoning_details"]), "provider_data")
      refute Map.has_key?(hd(assistant["reasoning_details"]), "encrypted?")
    end
  end

  describe "response decoding" do
    test "decode_response parses OpenAI-format response" do
      mock_resp = %Req.Response{
        status: 200,
        body:
          openai_format_json_fixture(
            model: "MiniMax-M2.7",
            content: "Hello from MiniMax!"
          )
      }

      mock_req = %Req.Request{
        options: [
          context: context_fixture(),
          model: "MiniMax-M2.7",
          operation: :chat
        ]
      }

      {_req, decoded_resp} = Minimax.decode_response({mock_req, mock_resp})

      assert %ReqLLM.Response{} = decoded_resp.body
      assert ReqLLM.Response.text(decoded_resp.body) == "Hello from MiniMax!"
    end

    test "decode_response preserves reasoning_details on message and context" do
      reasoning_details = [%{"type" => "reasoning.text", "text" => "Thinking"}]

      body =
        openai_format_json_fixture(model: "MiniMax-M2.7", content: "Final answer")
        |> put_in(["choices", Access.at(0), "message", "reasoning_details"], reasoning_details)

      mock_resp = %Req.Response{status: 200, body: body}

      mock_req = %Req.Request{
        options: [
          context: context_fixture(),
          model: "MiniMax-M2.7",
          operation: :chat
        ]
      }

      {_req, decoded_resp} = Minimax.decode_response({mock_req, mock_resp})

      assert [%ReqLLM.Message.ReasoningDetails{} = detail] =
               decoded_resp.body.message.reasoning_details

      assert detail.text == "Thinking"
      assert detail.provider == :minimax
      assert detail.format == "minimax-response-v1"
      assert detail.index == 0
      assert detail.provider_data == %{"type" => "reasoning.text"}
      assert List.last(decoded_resp.body.context.messages).reasoning_details == [detail]
    end
  end

  describe "streaming support" do
    test "attach_stream builds translated streaming request" do
      {:ok, finch_request} =
        Minimax.attach_stream(
          minimax_model(),
          context_fixture(),
          [max_tokens: 128, presence_penalty: 0.1],
          MyApp.Finch
        )

      assert %Finch.Request{} = finch_request
      assert finch_request.method == "POST"
      assert String.contains?(finch_request.path, "/chat/completions")

      headers_map = Map.new(finch_request.headers)
      assert headers_map["Authorization"] == "Bearer test-key-12345"

      decoded = Jason.decode!(finch_request.body)
      assert decoded["stream"] == true
      assert decoded["reasoning_split"] == true
      assert decoded["max_completion_tokens"] == 128
      refute Map.has_key?(decoded, "max_tokens")
      refute Map.has_key?(decoded, "presence_penalty")
    end

    test "stream response builder assembles MiniMax reasoning fragments" do
      model = minimax_model("MiniMax-M2.7")
      context = Context.new([Context.user("Think briefly.")])

      chunks = [
        StreamChunk.meta(%{
          reasoning_details: [
            %ReasoningDetails{
              text: "First ",
              signature: "reasoning-text-1",
              encrypted?: false,
              provider: :minimax,
              format: "MiniMax-response-v1",
              index: 0,
              provider_data: %{"type" => "reasoning.text"}
            }
          ]
        }),
        StreamChunk.meta(%{
          reasoning_details: [
            %ReasoningDetails{
              text: "second.",
              signature: "reasoning-text-1",
              encrypted?: false,
              provider: :minimax,
              format: "MiniMax-response-v1",
              index: 0,
              provider_data: %{"type" => "reasoning.text"}
            }
          ]
        }),
        StreamChunk.text("Done")
      ]

      builder = ResponseBuilder.for_model(model)

      assert ReqLLM.Providers.Minimax.ResponseBuilder = builder

      assert {:ok, response} =
               builder.build_response(chunks, %{finish_reason: :stop},
                 context: context,
                 model: model
               )

      assert [
               %ReasoningDetails{
                 text: "First second.",
                 signature: "reasoning-text-1",
                 provider: :minimax,
                 format: "MiniMax-response-v1",
                 index: 0,
                 provider_data: %{"type" => "reasoning.text"}
               }
             ] = response.message.reasoning_details

      assert List.last(response.context.messages).reasoning_details ==
               response.message.reasoning_details
    end
  end

  describe "image generation" do
    test "prepare_request for :image creates /image_generation request with api_mod" do
      model = minimax_image_model()

      {:ok, request} = Minimax.prepare_request(:image, model, "A red square", api_key: "test-key")

      assert %Req.Request{} = request
      assert request.url.path == "/image_generation"
      assert request.method == :post
      assert request.options[:base_url] == "https://api.minimax.io/v1"
      assert request.options[:api_mod] == ImagesAPI
      assert request.options[:prompt] == "A red square"
      assert request.options[:operation] == :image
    end

    test "prepare_request for :image rejects empty prompt" do
      model = minimax_image_model()
      context = Context.new([Context.system("you are helpful")])

      assert {:error, %ReqLLM.Error.Invalid.Parameter{}} =
               Minimax.prepare_request(:image, model, context, api_key: "test-key")
    end

    test "encode_body emits MiniMax-native JSON with base64 response format" do
      request =
        Req.new(url: ImagesAPI.path())
        |> Req.Request.register_options([
          :model,
          :prompt,
          :n,
          :aspect_ratio,
          :response_format,
          :seed,
          :provider_options,
          :context
        ])
        |> Req.Request.merge_options(
          model: "image-01",
          prompt: "A lighthouse",
          n: 2,
          aspect_ratio: "16:9",
          response_format: :binary,
          seed: 42,
          provider_options: [prompt_optimizer: true],
          context: %Context{messages: []}
        )

      encoded = ImagesAPI.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(encoded)

      assert body["model"] == "image-01"
      assert body["prompt"] == "A lighthouse"
      assert body["n"] == 2
      assert body["aspect_ratio"] == "16:9"
      assert body["response_format"] == "base64"
      assert body["seed"] == 42
      assert body["prompt_optimizer"] == true
      refute Map.has_key?(body, "subject_reference")
    end

    test "encode_body maps size to aspect_ratio when aspect_ratio is absent" do
      request =
        Req.new(url: ImagesAPI.path())
        |> Req.Request.register_options([:model, :prompt, :size, :response_format, :context])
        |> Req.Request.merge_options(
          model: "image-01",
          prompt: "A lighthouse",
          size: "1024x1024",
          response_format: :url,
          context: %Context{messages: []}
        )

      encoded = ImagesAPI.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(encoded)

      assert body["aspect_ratio"] == "1:1"
      assert body["response_format"] == "url"
      refute Map.has_key?(body, "width")
      refute Map.has_key?(body, "height")
    end

    test "encode_body preserves string and tuple non-canonical sizes" do
      for size <- ["1792x1024", {1792, 1024}] do
        request =
          Req.new(url: ImagesAPI.path())
          |> Req.Request.register_options([:model, :prompt, :size, :response_format, :context])
          |> Req.Request.merge_options(
            model: "image-01",
            prompt: "A lighthouse",
            size: size,
            response_format: :url,
            context: %Context{messages: []}
          )

        encoded = ImagesAPI.encode_body(request)
        body = ReqLLM.Test.Helpers.json_body(encoded)

        assert body["width"] == 1792
        assert body["height"] == 1024
        refute Map.has_key?(body, "aspect_ratio")
      end
    end

    test "encode_body forwards subject_reference for image-to-image" do
      request =
        Req.new(url: ImagesAPI.path())
        |> Req.Request.register_options([
          :model,
          :prompt,
          :response_format,
          :provider_options,
          :context
        ])
        |> Req.Request.merge_options(
          model: "image-01",
          prompt: "A girl by a window",
          response_format: :binary,
          provider_options: [
            subject_reference: [type: "character", image_file: "https://example.com/face.jpg"]
          ],
          context: %Context{messages: []}
        )

      encoded = ImagesAPI.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(encoded)

      assert body["subject_reference"] == [
               %{"type" => "character", "image_file" => "https://example.com/face.jpg"}
             ]
    end

    test "prepare_request and encode_body accept a string-keyed subject_reference map" do
      model = minimax_image_model()

      {:ok, request} =
        Minimax.prepare_request(:image, model, "A girl by a window",
          api_key: "test-key",
          provider_options: [
            subject_reference: %{
              "type" => "character",
              "image_file" => "https://example.com/face.jpg"
            }
          ]
        )

      encoded = Minimax.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(encoded)

      assert body["subject_reference"] == [
               %{"type" => "character", "image_file" => "https://example.com/face.jpg"}
             ]
    end

    test "generate_image completes a MiniMax public API round trip" do
      image_data = <<0xFF, 0xD8, 0xFF, 0xE0, "generated-image">>

      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v1/image_generation"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-key"]

        {:ok, request_body, conn} = Plug.Conn.read_body(conn)
        request_json = Jason.decode!(request_body)

        assert request_json["model"] == "image-01"
        assert request_json["prompt"] == "A girl by a window"
        assert request_json["width"] == 1792
        assert request_json["height"] == 1024

        assert request_json["subject_reference"] == [
                 %{
                   "type" => "character",
                   "image_file" => "https://example.com/face.jpg"
                 }
               ]

        Req.Test.json(conn, %{
          "id" => "trace-public-api",
          "data" => %{"image_base64" => [Base.encode64(image_data)]},
          "base_resp" => %{"status_code" => 0, "status_msg" => "success"}
        })
      end)

      assert {:ok, response} =
               ReqLLM.generate_image(minimax_image_model(), "A girl by a window",
                 api_key: "test-key",
                 size: "1792x1024",
                 provider_options: [
                   subject_reference: %{
                     "type" => "character",
                     "image_file" => "https://example.com/face.jpg"
                   }
                 ],
                 req_http_options: [plug: {Req.Test, __MODULE__}]
               )

      assert response.id == "trace-public-api"
      assert ReqLLM.Response.image_data(response) == image_data
      assert [%{type: :image, media_type: "image/jpeg"}] = ReqLLM.Response.images(response)
    end

    test "decode_response detects image media type from decoded bytes" do
      req =
        Req.new(url: ImagesAPI.path())
        |> Req.Request.register_options([:model, :output_format, :context])
        |> Req.Request.merge_options(
          model: "image-01",
          output_format: :png,
          context: %Context{messages: []}
        )

      images = [
        {<<0xFF, 0xD8, 0xFF, 0xE0, "jpeg">>, "image/jpeg"},
        {<<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, "png">>, "image/png"},
        {<<"RIFF", 4::little-32, "WEBP", "webp">>, "image/webp"}
      ]

      for {image_data, expected_media_type} <- images do
        resp = %Req.Response{
          status: 200,
          body: %{
            "id" => "trace-123",
            "data" => %{"image_base64" => [Base.encode64(image_data)]},
            "base_resp" => %{"status_code" => 0, "status_msg" => "success"}
          }
        }

        {_req, updated} = ImagesAPI.decode_response({req, resp})

        assert %ReqLLM.Response{} = updated.body
        assert updated.body.id == "trace-123"
        assert ReqLLM.Response.image_data(updated.body) == image_data

        [part] = ReqLLM.Response.images(updated.body)
        assert part.type == :image
        assert part.media_type == expected_media_type
      end
    end

    test "decode_response decodes image_urls array into image_url content parts" do
      req =
        Req.new(url: ImagesAPI.path())
        |> Req.Request.register_options([:model, :context])
        |> Req.Request.merge_options(
          model: "image-01",
          context: %Context{messages: []}
        )

      resp = %Req.Response{
        status: 200,
        body: %{
          "data" => %{"image_urls" => ["https://example.com/img1.png"]}
        }
      }

      {_req, updated} = ImagesAPI.decode_response({req, resp})

      assert %ReqLLM.Response{} = updated.body
      assert ReqLLM.Response.image_url(updated.body) == "https://example.com/img1.png"

      [part] = ReqLLM.Response.images(updated.body)
      assert part.type == :image_url
    end

    test "decode_response returns an error on base_resp status_code != 0 even with HTTP 200" do
      req =
        Req.new(url: ImagesAPI.path())
        |> Req.Request.register_options([:model, :context])
        |> Req.Request.merge_options(
          model: "image-01",
          context: %Context{messages: []}
        )

      resp = %Req.Response{
        status: 200,
        body: %{
          "data" => %{},
          "base_resp" => %{"status_code" => 1026, "status_msg" => "Sensitive content"}
        }
      }

      {_req, result} = ImagesAPI.decode_response({req, resp})

      assert %ReqLLM.Error.API.Response{} = result
      assert result.status == 1026
      assert result.reason =~ "1026"
    end
  end
end
