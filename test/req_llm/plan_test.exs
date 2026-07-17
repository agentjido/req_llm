defmodule ReqLLM.PlanTest do
  use ExUnit.Case, async: true

  @moduletag contract: :public_api

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias ReqLLM.Providers.{Anthropic, OpenAI}

  @api_key "plan-api-key-secret"
  @sensitive_value "plan-sensitive-value-842"

  describe "plan/3" do
    test "returns a small serializable OpenAI Responses diagnostic" do
      assert {:ok, diagnostic} =
               ReqLLM.plan("openai:gpt-4o-mini", :chat,
                 max_tokens: 256,
                 stream: true,
                 temperature: 0.2
               )

      assert diagnostic == %{
               model: %{provider: :openai, id: "gpt-4o-mini"},
               operation: :chat,
               surface: :openai_responses,
               transport: :finch,
               route: %{method: :post, path: "/responses"},
               options: %{
                 canonical: [:max_tokens, :stream, :temperature],
                 translated: [:max_tokens, :stream, :temperature]
               },
               fallbacks: [],
               warnings: []
             }

      assert {:ok, decoded} = diagnostic |> Jason.encode!() |> Jason.decode()
      assert decoded["surface"] == "openai_responses"
      assert decoded["route"] == %{"method" => "post", "path" => "/responses"}
    end

    test "reports OpenAI Chat option translation warnings without values" do
      model = %{
        provider: :openai,
        id: "chat-latest",
        extra: %{wire: %{protocol: "openai_chat"}}
      }

      assert {:ok, diagnostic} =
               ReqLLM.plan(model, :chat,
                 api_key: @api_key,
                 max_tokens: 128,
                 temperature: 0.2
               )

      assert diagnostic.surface == :openai_chat_completions
      assert diagnostic.route == %{method: :post, path: "/chat/completions"}
      assert diagnostic.options.canonical == [:max_tokens, :temperature]
      assert diagnostic.options.translated == [:max_completion_tokens]
      assert Enum.any?(diagnostic.warnings, &String.contains?(&1, ":max_tokens"))
      assert Enum.any?(diagnostic.warnings, &String.contains?(&1, "temperature"))
      refute inspect(diagnostic) =~ @api_key
    end

    test "honors the existing error policy for translated unsupported options" do
      model = %{
        provider: :openai,
        id: "chat-latest",
        extra: %{wire: %{protocol: "openai_chat"}}
      }

      assert {:error, %ReqLLM.Error.Validation.Error{} = error} =
               ReqLLM.plan(model, :chat,
                 max_tokens: 128,
                 on_unsupported: :error,
                 temperature: 0.2
               )

      assert Exception.message(error) =~ ":max_tokens"
      assert Exception.message(error) =~ "temperature"
    end

    test "reports Anthropic option translation without changing values or building a request" do
      assert {:ok, diagnostic} =
               ReqLLM.plan("anthropic:claude-sonnet-4-5-20250929", :object,
                 api_key: @api_key,
                 max_tokens: 64,
                 presence_penalty: 0.3,
                 stop: "END"
               )

      assert diagnostic.model == %{
               provider: :anthropic,
               id: "claude-sonnet-4-5-20250929"
             }

      assert diagnostic.operation == :object
      assert diagnostic.surface == :anthropic_messages
      assert diagnostic.transport == :req
      assert diagnostic.route == %{method: :post, path: "/v1/messages"}

      assert diagnostic.options.canonical == [
               :max_tokens,
               :presence_penalty,
               :stop
             ]

      assert diagnostic.options.translated == [:max_tokens, :stop_sequences]
      assert diagnostic.fallbacks == []
      refute inspect(diagnostic) =~ @api_key
      refute inspect(diagnostic) =~ "END"
    end

    test "translates object options through the underlying chat request operation" do
      model = chat_model()

      assert {:ok, diagnostic} =
               ReqLLM.plan(model, :object,
                 max_tokens: 128,
                 temperature: 0.2
               )

      assert diagnostic.operation == :object
      assert diagnostic.options.canonical == [:max_tokens, :temperature]
      assert diagnostic.options.translated == [:max_completion_tokens]
      assert Enum.any?(diagnostic.warnings, &String.contains?(&1, ":max_tokens"))
      assert Enum.any?(diagnostic.warnings, &String.contains?(&1, "temperature"))
    end

    test "uses an explicit WebSocket method for the Responses WebSocket route" do
      assert {:ok, diagnostic} =
               ReqLLM.plan("openai:gpt-4o-mini", :chat,
                 stream: true,
                 provider_options: [openai_stream_transport: :websocket]
               )

      assert diagnostic.transport == :websocket
      assert diagnostic.route == %{method: :websocket, path: "/responses"}
      assert diagnostic.options.canonical == [:openai_stream_transport, :stream]
    end

    test "returns inferred surface decisions as warnings, not runtime fallbacks" do
      model = %{provider: :openai, id: "unregistered-chat-model"}

      assert {:ok, diagnostic} = ReqLLM.plan(model, :chat)

      assert diagnostic.surface == :openai_chat_completions
      assert diagnostic.fallbacks == []

      assert diagnostic.warnings == [
               "Defaulted to OpenAI Chat Completions because model wire metadata is absent"
             ]
    end
  end

  describe "execution parity" do
    test "selects the same non-streaming surfaces and routes as provider execution" do
      cases = [
        {ReqLLM.model!("openai:gpt-4o-mini"), OpenAI},
        {chat_model(), OpenAI},
        {ReqLLM.model!("anthropic:claude-sonnet-4-5-20250929"), Anthropic}
      ]

      for {model, provider} <- cases do
        opts = [api_key: @api_key, max_tokens: 64]

        assert {:ok, diagnostic} = ReqLLM.plan(model, :chat, opts)
        assert {:ok, request} = provider.prepare_request(:chat, model, "Hello", opts)

        execution_plan = request.private[:req_llm_request_plan]

        assert diagnostic.surface == execution_plan.surface
        assert diagnostic.transport == execution_plan.transport
        assert diagnostic.operation == execution_plan.operation
        assert diagnostic.route.path == request.url.path
      end
    end

    test "selects the same Finch surface and transport as provider execution" do
      model = ReqLLM.model!("anthropic:claude-sonnet-4-5-20250929")
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])
      opts = [api_key: @api_key, max_tokens: 64, stream: true]

      assert {:ok, diagnostic} = ReqLLM.plan(model, :chat, opts)
      assert {:ok, request} = Anthropic.attach_stream(model, context, opts, nil)

      execution_plan = request.private[:req_llm_request_plan]

      assert diagnostic.surface == execution_plan.surface
      assert diagnostic.transport == execution_plan.transport
      assert diagnostic.route.path == request.path
    end

    test "reports the option translation used by object request execution" do
      model = chat_model()
      {:ok, schema} = ReqLLM.Schema.compile(name: [type: :string, required: true])
      opts = [api_key: @api_key, max_tokens: 128, temperature: 0.2]

      assert {:ok, diagnostic} = ReqLLM.plan(model, :object, opts)

      assert {:ok, request} =
               OpenAI.prepare_request(
                 :object,
                 model,
                 "Return a name",
                 Keyword.put(opts, :compiled_schema, schema)
               )

      assert diagnostic.options.translated == [:max_completion_tokens]
      assert request.options[:max_completion_tokens] == 128
      refute Map.has_key?(request.options, :max_tokens)
      refute Map.has_key?(request.options, :temperature)
    end
  end

  describe "redaction and no-I/O guarantees" do
    test "does not resolve credentials, access fixtures, or log translation warnings" do
      model = %{
        provider: :openai,
        id: "chat-latest",
        extra: %{wire: %{protocol: "openai_chat"}}
      }

      output =
        capture_io(:stderr, fn ->
          log =
            capture_log(fn ->
              send(
                self(),
                ReqLLM.plan(model, :chat,
                  max_tokens: 64,
                  temperature: 0.2
                )
              )
            end)

          send(self(), {:captured_log, log})
        end)

      assert output == ""
      assert_received {:captured_log, ""}
      assert_received {:ok, %{surface: :openai_chat_completions}}
    end

    test "omits credential, payload, header, callback, and option values" do
      callback = fn request -> request end

      assert {:ok, diagnostic} =
               ReqLLM.plan(
                 %{
                   provider: :anthropic,
                   id: "redaction-model",
                   base_url: @sensitive_value
                 },
                 :chat,
                 api_key: @sensitive_value,
                 access_token: @sensitive_value,
                 auth_mode: :oauth,
                 base_url: @sensitive_value,
                 fixture: @sensitive_value,
                 files: [@sensitive_value],
                 max_tokens: 64,
                 on_finch_request: callback,
                 req_http_options: [headers: [{"x-secret", @sensitive_value}]],
                 system_prompt: @sensitive_value,
                 tools: [%{name: @sensitive_value}],
                 provider_options: [secret_header: @sensitive_value]
               )

      serialized = inspect(diagnostic) <> Jason.encode!(diagnostic)

      refute serialized =~ @sensitive_value
      refute :api_key in diagnostic.options.canonical
      refute :access_token in diagnostic.options.canonical
      refute :auth_mode in diagnostic.options.canonical
      refute :fixture in diagnostic.options.canonical
      refute :on_finch_request in diagnostic.options.canonical
      refute :req_http_options in diagnostic.options.canonical
      refute :secret_header in diagnostic.options.canonical
      assert :base_url in diagnostic.options.canonical
      assert :files in diagnostic.options.canonical
      assert :system_prompt in diagnostic.options.canonical
      assert :tools in diagnostic.options.canonical
      refute serialized =~ "ReqLLM.Providers"
    end

    test "sanitizes invalid option and model errors" do
      invalid_options = [{"secret", @sensitive_value}, {:api_key, @sensitive_value}]

      assert {:error, option_error} =
               ReqLLM.plan("openai:gpt-4o-mini", :chat, invalid_options)

      invalid_model = %{provider: @sensitive_value, id: "model"}

      assert {:error, model_error} = ReqLLM.plan(invalid_model, :chat)

      errors = inspect(option_error) <> Exception.message(option_error) <> inspect(model_error)

      refute errors =~ @sensitive_value
      assert Exception.message(option_error) =~ "options must be a keyword list"
      assert Exception.message(model_error) =~ "Invalid model specification"
    end

    test "keeps unsupported combinations actionable without echoing their values" do
      assert {:error, stream_error} =
               ReqLLM.plan("openai:gpt-4o-mini", :chat, stream: @sensitive_value)

      assert Exception.message(stream_error) =~ ":stream must be a boolean"
      refute inspect(stream_error) =~ @sensitive_value

      assert {:error, transport_error} =
               ReqLLM.plan("anthropic:claude-sonnet-4-5-20250929", :chat,
                 stream: true,
                 provider_options: [openai_stream_transport: :websocket]
               )

      assert Exception.message(transport_error) =~
               "WebSocket transport is not supported by Anthropic Messages"

      invalid_wire_model = %{
        provider: :openai,
        id: "invalid-wire-model",
        extra: %{wire: %{protocol: @sensitive_value}}
      }

      assert {:error, wire_error} = ReqLLM.plan(invalid_wire_model, :chat)
      assert Exception.message(wire_error) =~ "wire protocol is invalid"
      refute inspect(wire_error) =~ @sensitive_value
    end
  end

  defp chat_model do
    ReqLLM.model!(%{
      provider: :openai,
      id: "chat-latest",
      extra: %{wire: %{protocol: "openai_chat"}}
    })
  end
end
