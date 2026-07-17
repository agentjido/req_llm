defmodule ReqLLM.Providers.MoonshotAITest do
  use ReqLLM.ProviderCase, provider: ReqLLM.Providers.MoonshotAI

  import ExUnit.CaptureIO

  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Providers.MoonshotAI

  defp kimi_k3_model do
    %LLMDB.Model{
      id: "kimi-k3",
      model: "kimi-k3",
      provider_model_id: "kimi-k3",
      provider: :moonshotai,
      name: "Kimi K3",
      family: "openai_chat_compatible",
      capabilities: %{
        chat: true,
        tools: %{enabled: true, streaming: true},
        reasoning: %{enabled: true}
      },
      limits: %{context: 1_048_576, output: 1_048_576},
      extra: %{wire: %{protocol: "openai_chat"}}
    }
  end

  describe "provider contract" do
    test "exposes Moonshot identity and configuration" do
      assert MoonshotAI.provider_id() == :moonshotai
      assert MoonshotAI.base_url() == "https://api.moonshot.ai/v1"
      assert MoonshotAI.default_env_key() == "MOONSHOT_API_KEY"
      assert MoonshotAI.display_name() == "Moonshot AI"
    end

    test "registers through provider discovery" do
      assert {:ok, MoonshotAI} = ReqLLM.provider(:moonshotai)
    end

    test "resolves Kimi K3 from LLMDB without an unverified warning" do
      warning =
        capture_io(:stderr, fn ->
          assert %LLMDB.Model{provider: :moonshotai, id: "kimi-k3"} =
                   ReqLLM.model!("moonshotai:kimi-k3")
        end)

      refute warning =~ "Using unverified model"
    end

    test "prepares the Chat Completions endpoint with bearer authentication" do
      assert {:ok, request} =
               MoonshotAI.prepare_request(:chat, kimi_k3_model(), "Hello", api_key: "test-key")

      assert request.url.path == "/chat/completions"
      assert request.options[:base_url] == "https://api.moonshot.ai/v1"

      attached = MoonshotAI.attach(request, kimi_k3_model(), api_key: "test-key")
      assert attached.headers["authorization"] == ["Bearer test-key"]
    end
  end

  describe "Kimi K3 option translation" do
    test "omits fixed sampling parameters and forces max reasoning" do
      {translated, warnings} =
        MoonshotAI.translate_options(
          :chat,
          kimi_k3_model(),
          temperature: 0.2,
          top_p: 0.5,
          n: 2,
          presence_penalty: 1.0,
          frequency_penalty: 1.0,
          reasoning_effort: :low
        )

      for option <- [:temperature, :top_p, :n, :presence_penalty, :frequency_penalty] do
        refute Keyword.has_key?(translated, option)
      end

      assert translated[:reasoning_effort] == :max
      assert translated[:receive_timeout] == 300_000
      assert length(warnings) == 6
    end

    test "translates max_tokens and removes K2.x thinking" do
      {translated, warnings} =
        MoonshotAI.translate_options(
          :chat,
          kimi_k3_model(),
          max_tokens: 2048,
          provider_options: [thinking: %{type: "enabled"}]
        )

      assert translated[:max_completion_tokens] == 2048
      refute Keyword.has_key?(translated, :max_tokens)
      refute Keyword.has_key?(translated, :provider_options)
      assert translated[:reasoning_effort] == :max
      assert Enum.any?(warnings, &String.contains?(&1, "translated max_tokens"))
      assert Enum.any?(warnings, &String.contains?(&1, "K2.x thinking"))
    end

    test "removes K2.x thinking through the public option pipeline" do
      processed =
        ReqLLM.Provider.Options.process!(
          MoonshotAI,
          :chat,
          kimi_k3_model(),
          provider_options: [thinking: %{type: "enabled"}],
          on_unsupported: :ignore
        )

      refute Keyword.has_key?(processed, :thinking)
      refute Keyword.has_key?(processed, :provider_options)
    end

    test "rejects K2.x thinking when unsupported options are errors" do
      assert_raise ReqLLM.Error.Validation.Error, ~r/K2\.x thinking/, fn ->
        ReqLLM.Provider.Options.process!(
          MoonshotAI,
          :chat,
          kimi_k3_model(),
          provider_options: [thinking: %{type: "enabled"}],
          on_unsupported: :error
        )
      end
    end

    test "retains an explicit max completion token limit" do
      {translated, warnings} =
        MoonshotAI.translate_options(
          :chat,
          kimi_k3_model(),
          max_tokens: 1024,
          max_completion_tokens: 4096,
          reasoning_effort: :max
        )

      assert translated[:max_completion_tokens] == 4096
      assert translated[:reasoning_effort] == :max
      refute Keyword.has_key?(translated, :max_tokens)
      assert Enum.any?(warnings, &String.contains?(&1, "ignored max_tokens"))
    end

    test "translates named tool choice to required for always-on reasoning" do
      {translated, warnings} =
        MoonshotAI.translate_options(
          :object,
          kimi_k3_model(),
          tool_choice: %{type: "function", function: %{name: "structured_output"}}
        )

      assert translated[:tool_choice] == "required"
      assert Enum.any?(warnings, &String.contains?(&1, "named tool choice"))
    end
  end

  describe "request encoding" do
    test "builds the K3 body without incompatible parameters" do
      request = %Req.Request{
        options: [
          context: context_fixture(),
          model: "kimi-k3",
          stream: false,
          temperature: 0.0,
          top_p: 1.0,
          max_completion_tokens: 4096,
          reasoning_effort: "max"
        ],
        private: %{req_llm_model: kimi_k3_model()}
      }

      body = request |> MoonshotAI.encode_body() |> ReqLLM.Test.Helpers.json_body()

      assert body["model"] == "kimi-k3"
      assert body["max_completion_tokens"] == 4096
      assert body["reasoning_effort"] == "max"
      refute Map.has_key?(body, "max_tokens")
      refute Map.has_key?(body, "temperature")
      refute Map.has_key?(body, "top_p")
      refute Map.has_key?(body, "thinking")
    end

    test "preserves assistant reasoning and tool calls in a follow-up request" do
      assistant = %Message{
        role: :assistant,
        content: [
          %ContentPart{type: :thinking, text: "I should call the weather tool."},
          %ContentPart{type: :text, text: ""}
        ],
        tool_calls: [
          %ReqLLM.ToolCall{
            id: "call_weather",
            type: "function",
            function: %{name: "get_weather", arguments: ~s({"city":"Chicago"})}
          }
        ]
      }

      context =
        ReqLLM.Context.new([ReqLLM.Context.user("Weather?")]) |> ReqLLM.Context.append(assistant)

      body =
        %Req.Request{
          options: [context: context, model: "kimi-k3", stream: false],
          private: %{req_llm_model: kimi_k3_model()}
        }
        |> MoonshotAI.encode_body()
        |> ReqLLM.Test.Helpers.json_body()

      encoded_assistant = Enum.find(body["messages"], &(&1["role"] == "assistant"))
      assert encoded_assistant["reasoning_content"] == "I should call the weather tool."
      assert get_in(encoded_assistant, ["tool_calls", Access.at(0), "id"]) == "call_weather"
    end

    test "encodes required tool choice, strict JSON schema, and image input" do
      tool =
        ReqLLM.Tool.new!(
          name: "describe_scene",
          description: "Describe an image",
          parameter_schema: [description: [type: :string, required: true]],
          callback: fn _ -> {:ok, "described"} end,
          strict: true
        )

      context =
        ReqLLM.Context.new([
          %Message{
            role: :user,
            content: [
              %ContentPart{type: :image, data: <<1, 2, 3>>, media_type: "image/png"},
              %ContentPart{type: :text, text: "Describe this image"}
            ]
          }
        ])

      response_format = %{
        type: "json_schema",
        json_schema: %{
          name: "scene",
          strict: true,
          schema: %{type: "object", properties: %{description: %{type: "string"}}}
        }
      }

      body =
        %Req.Request{
          options: [
            context: context,
            model: "kimi-k3",
            stream: false,
            tools: [tool],
            tool_choice: "required",
            response_format: response_format
          ],
          private: %{req_llm_model: kimi_k3_model()}
        }
        |> MoonshotAI.encode_body()
        |> ReqLLM.Test.Helpers.json_body()

      assert body["tool_choice"] == "required"
      assert get_in(body, ["tools", Access.at(0), "function", "strict"]) == true
      assert get_in(body, ["response_format", "type"]) == "json_schema"

      assert get_in(body, ["messages", Access.at(0), "content", Access.at(0), "type"]) ==
               "image_url"
    end

    test "builds a streaming body with K3 constraints" do
      assert {:ok, finch_request} =
               MoonshotAI.attach_stream(
                 kimi_k3_model(),
                 context_fixture(),
                 [api_key: "test-key", max_tokens: 2048, temperature: 0.2],
                 ReqLLM.Finch
               )

      body = finch_request.body |> IO.iodata_to_binary() |> Jason.decode!()

      assert finch_request.path == "/v1/chat/completions"
      assert body["stream"] == true
      assert body["max_completion_tokens"] == 2048
      assert body["reasoning_effort"] == "max"
      refute Map.has_key?(body, "max_tokens")
      refute Map.has_key?(body, "temperature")
      refute Map.has_key?(body, "n")
    end
  end

  describe "response decoding" do
    test "normalizes non-streaming reasoning_content" do
      response = %Req.Response{
        status: 200,
        body: %{
          "id" => "chatcmpl-k3",
          "model" => "kimi-k3",
          "choices" => [
            %{
              "index" => 0,
              "finish_reason" => "stop",
              "message" => %{
                "role" => "assistant",
                "reasoning_content" => "Reasoning",
                "content" => "Answer"
              }
            }
          ],
          "usage" => %{"prompt_tokens" => 4, "completion_tokens" => 6, "total_tokens" => 10}
        }
      }

      request = %Req.Request{
        options: [context: context_fixture(), stream: false, id: "moonshotai:kimi-k3"],
        private: %{req_llm_model: kimi_k3_model()}
      }

      {_request, decoded} = MoonshotAI.decode_response({request, response})
      assert ReqLLM.Response.text(decoded.body) == "Answer"
      assert ReqLLM.Response.thinking(decoded.body) == "Reasoning"
    end

    test "normalizes streaming reasoning_content separately from final content" do
      reasoning_event = %{
        data: %{
          "choices" => [%{"index" => 0, "delta" => %{"reasoning_content" => "Think"}}]
        }
      }

      content_event = %{
        data: %{"choices" => [%{"index" => 0, "delta" => %{"content" => "Answer"}}]}
      }

      assert [%ReqLLM.StreamChunk{type: :thinking, text: "Think"}] =
               MoonshotAI.decode_stream_event(reasoning_event, kimi_k3_model())

      assert [%ReqLLM.StreamChunk{type: :content, text: "Answer"}] =
               MoonshotAI.decode_stream_event(content_event, kimi_k3_model())
    end
  end
end
