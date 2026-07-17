defmodule ReqLLM.RequestPlanTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias ReqLLM.RequestPlan

  describe "build/3" do
    test "plans OpenAI Responses without changing caller options" do
      assert {:ok, plan} =
               RequestPlan.build("openai:gpt-4o-mini", :chat,
                 max_tokens: 100,
                 temperature: 0.2
               )

      assert %LLMDB.Model{provider: :openai, id: "gpt-4o-mini"} = plan.model
      assert plan.operation == :chat
      assert plan.provider == :openai
      assert plan.surface == :openai_responses
      assert plan.transport == :req
      assert plan.provider_module == ReqLLM.Providers.OpenAI
      assert plan.api_module == ReqLLM.Providers.OpenAI.ResponsesAPI
      assert plan.options == [max_tokens: 100, temperature: 0.2]
      assert plan.warnings == []
    end

    test "plans inferred OpenAI Chat Completions and Finch streaming" do
      assert {:ok, plan} =
               RequestPlan.build("openai:chat-latest", :chat,
                 temperature: 0.3,
                 stream: true
               )

      assert plan.surface == :openai_chat_completions
      assert plan.transport == :finch
      assert plan.api_module == ReqLLM.Providers.OpenAI.ChatAPI

      assert plan.warnings == [
               "Defaulted to OpenAI Chat Completions because model wire metadata is absent"
             ]
    end

    test "plans Anthropic Messages over Finch" do
      assert {:ok, plan} =
               RequestPlan.build("anthropic:claude-sonnet-4-5-20250929", :object, stream: true)

      assert plan.operation == :object
      assert plan.provider == :anthropic
      assert plan.surface == :anthropic_messages
      assert plan.transport == :finch
      assert plan.provider_module == ReqLLM.Providers.Anthropic
      assert plan.api_module == ReqLLM.Providers.Anthropic
      assert plan.warnings == []
    end

    test "equivalent model inputs and option order produce equal plans" do
      model = ReqLLM.model!("openai:gpt-4o-mini")

      assert {:ok, from_string} =
               RequestPlan.build("openai:gpt-4o-mini", :chat,
                 temperature: 0.2,
                 max_tokens: 64
               )

      assert {:ok, from_tuple} =
               RequestPlan.build(
                 {:openai, "gpt-4o-mini", [max_tokens: 64, temperature: 0.2]},
                 :chat
               )

      assert {:ok, from_model} =
               RequestPlan.build(model, :chat, max_tokens: 64, temperature: 0.2)

      assert from_string == from_tuple
      assert from_tuple == from_model
    end

    test "inline specs and their resolved models produce equal plans" do
      model_spec = %{
        provider: :openai,
        id: "custom-chat",
        base_url: "https://llm.example.test/v1",
        extra: %{wire: %{protocol: "openai_chat"}}
      }

      model = ReqLLM.model!(model_spec)

      assert RequestPlan.build(model_spec, :chat, temperature: 0.4) ==
               RequestPlan.build(model, :chat, temperature: 0.4)
    end

    test "normalizes raw model structs like current execution" do
      raw_model = %LLMDB.Model{provider: :openai, id: "gpt-4o-mini"}

      assert {:ok, plan} = RequestPlan.build(raw_model, :chat)

      assert plan.model.id == "gpt-4o-mini"
      assert plan.model.model == "gpt-4o-mini"
      assert plan.model.family == "gpt-4o"
      assert plan.model.extra.wire.protocol == "openai_responses"
      assert plan.surface == :openai_responses
    end

    test "keeps planning warnings in deterministic source order" do
      model_input =
        {:openai, "chat-latest", [stream_transport: :http, unsupported_default: true]}

      assert capture_io(:stderr, fn ->
               send(
                 self(),
                 RequestPlan.build(model_input, :chat,
                   provider_options: [openai_stream_transport: :websocket]
                 )
               )
             end) == ""

      assert_received {:ok, plan}

      assert plan.warnings == [
               "Ignoring tuple model defaults for chat: :stream_transport is controlled by the operation boundary, not the model, :unsupported_default is not accepted by this operation. Pass only documented chat options; explicit call options take precedence.",
               "Defaulted to OpenAI Chat Completions because model wire metadata is absent",
               "Ignored streaming transport selection for a non-streaming request plan"
             ]
    end

    test "selects WebSocket only for streaming OpenAI Responses" do
      assert {:ok, plan} =
               RequestPlan.build("openai:gpt-4o-mini", :chat,
                 stream: true,
                 provider_options: [openai_stream_transport: :websocket]
               )

      assert plan.surface == :openai_responses
      assert plan.transport == :websocket
    end

    test "does not treat the internal transport flag as the provider selector" do
      assert {:ok, plan} =
               RequestPlan.build("openai:gpt-4o-mini", :chat,
                 stream: true,
                 stream_transport: :websocket
               )

      assert plan.transport == :finch
    end

    test "rejects an unsupported operation before execution" do
      assert {:error, %ReqLLM.Error.Invalid.Parameter{} = error} =
               RequestPlan.build("openai:gpt-4o-mini", :image)

      assert Exception.message(error) =~ "supports only :chat and :object"
    end

    test "rejects a provider and wire protocol mismatch" do
      model = %{
        provider: :anthropic,
        id: "custom-claude",
        extra: %{wire: %{protocol: "openai_chat"}}
      }

      assert {:error, %ReqLLM.Error.Invalid.Parameter{} = error} =
               RequestPlan.build(model, :chat)

      assert Exception.message(error) =~ "wire protocol \"openai_chat\" is invalid"
    end

    test "rejects WebSocket for OpenAI Chat Completions" do
      assert {:error, %ReqLLM.Error.Invalid.Parameter{} = error} =
               RequestPlan.build("openai:chat-latest", :chat,
                 stream: true,
                 provider_options: [openai_stream_transport: :websocket]
               )

      assert Exception.message(error) =~
               "WebSocket transport is not supported by OpenAI Chat Completions"
    end

    test "rejects invalid stream settings with typed errors" do
      assert {:error, %ReqLLM.Error.Invalid.Parameter{} = stream_error} =
               RequestPlan.build("openai:gpt-4o-mini", :chat, stream: :yes)

      assert Exception.message(stream_error) =~ ":stream must be a boolean"

      assert {:error, %ReqLLM.Error.Invalid.Parameter{} = transport_error} =
               RequestPlan.build("openai:gpt-4o-mini", :chat,
                 stream: true,
                 stream_transport: :udp
               )

      assert Exception.message(transport_error) =~ "unsupported internal stream transport"
    end
  end
end
