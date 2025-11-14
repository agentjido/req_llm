defmodule ReqLLM.Providers.AmazonBedrock.MetaTest do
  use ExUnit.Case, async: true

  alias ReqLLM.{Context, Providers.AmazonBedrock.Meta}

  describe "format_request/3" do
    test "formats basic request with user message" do
      context = Context.new([Context.user("Hello")])

      formatted =
        Meta.format_request(
          "meta.llama3-8b-instruct-v1:0",
          context,
          []
        )

      assert formatted["prompt"]
      assert String.contains?(formatted["prompt"], "<|begin_of_text|>")
      assert String.contains?(formatted["prompt"], "<|start_header_id|>user<|end_header_id|>")
      assert String.contains?(formatted["prompt"], "Hello")
      assert String.contains?(formatted["prompt"], "<|eot_id|>")

      assert String.contains?(
               formatted["prompt"],
               "<|start_header_id|>assistant<|end_header_id|>"
             )
    end

    test "includes system message when present" do
      context =
        Context.new([
          Context.system("You are a helpful assistant"),
          Context.user("Hello")
        ])

      formatted =
        Meta.format_request(
          "meta.llama3-70b-instruct-v1:0",
          context,
          []
        )

      prompt = formatted["prompt"]
      assert String.contains?(prompt, "<|start_header_id|>system<|end_header_id|>")
      assert String.contains?(prompt, "You are a helpful assistant")
      assert String.contains?(prompt, "<|start_header_id|>user<|end_header_id|>")
      assert String.contains?(prompt, "Hello")
    end

    test "includes optional parameters when provided" do
      context = Context.new([Context.user("Hello")])

      formatted =
        Meta.format_request(
          "meta.llama3-8b-instruct-v1:0",
          context,
          max_tokens: 2048,
          temperature: 0.7,
          top_p: 0.9
        )

      assert formatted["max_gen_len"] == 2048
      assert formatted["temperature"] == 0.7
      assert formatted["top_p"] == 0.9
    end

    test "excludes nil parameters" do
      context = Context.new([Context.user("Hello")])

      formatted =
        Meta.format_request(
          "meta.llama3-8b-instruct-v1:0",
          context,
          max_tokens: 1000,
          temperature: nil
        )

      assert formatted["max_gen_len"] == 1000
      refute Map.has_key?(formatted, "temperature")
    end

    test "handles multi-turn conversation" do
      context =
        Context.new([
          Context.user("What is 2+2?"),
          Context.assistant("4"),
          Context.user("What about 3+3?")
        ])

      formatted =
        Meta.format_request(
          "meta.llama3-8b-instruct-v1:0",
          context,
          []
        )

      prompt = formatted["prompt"]
      assert String.contains?(prompt, "What is 2+2?")
      assert String.contains?(prompt, "4")
      assert String.contains?(prompt, "What about 3+3?")
    end
  end

  describe "format_llama_prompt/1" do
    test "formats single user message" do
      messages = [
        %ReqLLM.Message{
          role: :user,
          content: [%ReqLLM.Message.ContentPart{type: :text, text: "Test"}]
        }
      ]

      prompt = Meta.format_llama_prompt(messages)

      assert prompt ==
               "<|begin_of_text|><|start_header_id|>user<|end_header_id|>\n\nTest<|eot_id|><|start_header_id|>assistant<|end_header_id|>\n\n"
    end

    test "formats system and user messages" do
      messages = [
        %ReqLLM.Message{
          role: :system,
          content: [%ReqLLM.Message.ContentPart{type: :text, text: "System prompt"}]
        },
        %ReqLLM.Message{
          role: :user,
          content: [%ReqLLM.Message.ContentPart{type: :text, text: "User message"}]
        }
      ]

      prompt = Meta.format_llama_prompt(messages)

      assert String.starts_with?(prompt, "<|begin_of_text|>")
      assert String.contains?(prompt, "<|start_header_id|>system<|end_header_id|>")
      assert String.contains?(prompt, "System prompt<|eot_id|>")
      assert String.contains?(prompt, "<|start_header_id|>user<|end_header_id|>")
      assert String.contains?(prompt, "User message<|eot_id|>")
      assert String.ends_with?(prompt, "<|start_header_id|>assistant<|end_header_id|>\n\n")
    end

    test "handles content blocks" do
      messages = [
        %ReqLLM.Message{
          role: :user,
          content: [
            %ReqLLM.Message.ContentPart{type: :text, text: "First part"},
            %ReqLLM.Message.ContentPart{type: :text, text: "Second part"}
          ]
        }
      ]

      prompt = Meta.format_llama_prompt(messages)

      assert String.contains?(prompt, "First part\nSecond part")
    end
  end

  describe "parse_response/2" do
    test "parses basic Meta response" do
      response_body = %{
        "generation" => "Hello! How can I help you?",
        "prompt_token_count" => 10,
        "generation_token_count" => 25,
        "stop_reason" => "stop"
      }

      assert {:ok, parsed} =
               Meta.parse_response(response_body, model: "meta.llama3-8b-instruct-v1:0")

      assert %ReqLLM.Response{} = parsed
      assert parsed.model == "meta.llama3-8b-instruct-v1:0"
      assert parsed.finish_reason == :stop
      assert parsed.usage.input_tokens == 10
      assert parsed.usage.output_tokens == 25
      assert parsed.usage.total_tokens == 35

      assert parsed.message.role == :assistant
      assert ReqLLM.Response.text(parsed) == "Hello! How can I help you?"
    end

    test "parses response with length stop reason" do
      response_body = %{
        "generation" => "Truncated response",
        "prompt_token_count" => 15,
        "generation_token_count" => 2048,
        "stop_reason" => "length"
      }

      assert {:ok, parsed} =
               Meta.parse_response(response_body, model: "meta.llama3-70b-instruct-v1:0")

      assert parsed.finish_reason == :length
    end

    test "returns error for invalid response" do
      response_body = %{"invalid" => "format"}

      assert {:error, "Invalid response format: missing required fields"} =
               Meta.parse_response(response_body, [])
    end
  end

  describe "parse_stream_chunk/2" do
    test "parses text generation chunk" do
      inner_event = %{"generation" => "Hello"}

      chunk = %{
        "chunk" => %{
          "bytes" => Base.encode64(Jason.encode!(inner_event))
        }
      }

      assert {:ok, stream_chunk} = Meta.parse_stream_chunk(chunk, [])
      assert stream_chunk.type == :content
      assert stream_chunk.text == "Hello"
    end

    test "parses finish chunk with stop reason" do
      inner_event = %{"stop_reason" => "stop"}

      chunk = %{
        "chunk" => %{
          "bytes" => Base.encode64(Jason.encode!(inner_event))
        }
      }

      assert {:ok, stream_chunk} = Meta.parse_stream_chunk(chunk, [])
      assert stream_chunk.type == :meta
      assert stream_chunk.metadata[:finish_reason] == :stop
      assert stream_chunk.metadata[:terminal?] == true
    end

    test "parses invocation metrics chunk" do
      inner_event = %{
        "amazon-bedrock-invocationMetrics" => %{
          "inputTokenCount" => 50,
          "outputTokenCount" => 100
        }
      }

      chunk = %{
        "chunk" => %{
          "bytes" => Base.encode64(Jason.encode!(inner_event))
        }
      }

      assert {:ok, stream_chunk} = Meta.parse_stream_chunk(chunk, [])
      assert stream_chunk.type == :meta
      assert stream_chunk.metadata[:usage][:input_tokens] == 50
      assert stream_chunk.metadata[:usage][:output_tokens] == 100
    end

    test "handles empty generation chunk" do
      inner_event = %{"generation" => ""}

      chunk = %{
        "chunk" => %{
          "bytes" => Base.encode64(Jason.encode!(inner_event))
        }
      }

      assert {:ok, nil} = Meta.parse_stream_chunk(chunk, [])
    end

    test "handles unwrapped JSON event (native format)" do
      # Meta Llama sends unwrapped events directly with generation field
      chunk = %{"generation" => "Hello"}

      assert {:ok, stream_chunk} = Meta.parse_stream_chunk(chunk, [])
      assert stream_chunk.type == :content
      assert stream_chunk.text == "Hello"
    end

    test "handles malformed chunk" do
      chunk = %{"invalid" => "format"}

      assert {:error, :unknown_chunk_format} = Meta.parse_stream_chunk(chunk, [])
    end

    test "handles invalid base64" do
      chunk = %{"chunk" => %{"bytes" => "not-valid-base64!!!"}}

      assert {:error, {:unwrap_failed, _}} = Meta.parse_stream_chunk(chunk, [])
    end
  end

  describe "extract_usage/2" do
    test "extracts usage from response" do
      body = %{
        "prompt_token_count" => 10,
        "generation_token_count" => 20
      }

      assert {:ok, usage} = Meta.extract_usage(body, nil)
      assert usage.input_tokens == 10
      assert usage.output_tokens == 20
      assert usage.total_tokens == 30
    end

    test "returns error when no usage" do
      body = %{"generation" => "test"}

      assert {:error, :no_usage} = Meta.extract_usage(body, nil)
    end
  end
end
