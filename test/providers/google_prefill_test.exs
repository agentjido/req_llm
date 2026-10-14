defmodule ReqLLM.Providers.GooglePrefillTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Context
  alias ReqLLM.Error.Invalid.Parameter
  alias ReqLLM.Providers.{Google, GoogleVertex}

  for {provider, provider_id, opts} <- [
        {Google, :google, [api_key: "test"]},
        {GoogleVertex, :google_vertex,
         [access_token: "test-token", project_id: "test-project", region: "us-central1"]}
      ] do
    describe "#{provider_id} assistant prefill" do
      setup do
        model = ReqLLM.model!(unquote("#{provider_id}:gemini-2.5-flash"))

        context =
          Context.new([Context.user("Translate hello"), Context.assistant("Translation:")])

        {:ok, provider: unquote(provider), model: model, opts: unquote(opts), context: context}
      end

      for operation <- [:chat, :object] do
        test "rejects #{operation} requests before credential validation", state do
          assert {:error, %Parameter{} = error} =
                   state.provider.prepare_request(
                     unquote(operation),
                     state.model,
                     state.context,
                     []
                   )

          assert error.parameter =~ "assistant message"
          assert error.parameter =~ "prefill"
          assert error.parameter =~ "user message"
        end
      end

      test "rejects streaming requests before credential validation", state do
        assert {:error, %Parameter{} = error} =
                 state.provider.attach_stream(state.model, state.context, [], nil)

        assert error.parameter =~ "assistant message"
      end

      test "ignores trailing system messages when checking the last turn", state do
        context = Context.append(state.context, Context.system("Use French"))

        assert {:error, %Parameter{}} =
                 state.provider.prepare_request(:chat, state.model, context, state.opts)

        assert {:error, %Parameter{}} =
                 state.provider.attach_stream(state.model, context, state.opts, nil)
      end

      test "validates loose message maps after normalization", state do
        messages = [
          %{"role" => "user", "content" => "Translate hello"},
          %{"role" => "assistant", "content" => "Translation:"}
        ]

        assert {:error, %Parameter{}} =
                 state.provider.prepare_request(:chat, state.model, messages, state.opts)
      end

      test "rejects a final assistant tool call", state do
        context = tool_context()

        assert {:error, %Parameter{}} =
                 state.provider.prepare_request(:chat, state.model, context, state.opts)

        assert {:error, %Parameter{}} =
                 state.provider.attach_stream(state.model, context, state.opts, nil)
      end

      test "accepts history ending with a user message", state do
        context = Context.append(state.context, Context.user("Complete the translation"))

        assert {:ok, %Req.Request{}} =
                 state.provider.prepare_request(:chat, state.model, context, state.opts)

        assert {:ok, %Finch.Request{}} =
                 state.provider.attach_stream(state.model, context, state.opts, nil)
      end

      test "accepts history ending with a tool result", state do
        context =
          Context.append(tool_context(), Context.tool_result("call_1", "translate", "Bonjour"))

        assert {:ok, %Req.Request{}} =
                 state.provider.prepare_request(:chat, state.model, context, state.opts)

        assert {:ok, %Finch.Request{}} =
                 state.provider.attach_stream(state.model, context, state.opts, nil)
      end

      test "validates explicit model specs for newer Gemini models", state do
        model = %{id: "gemini-3.8-flash", provider: state.model.provider}

        assert {:error, %Parameter{}} =
                 state.provider.prepare_request(:chat, model, state.context, [])
      end

      test "generate_text returns a local parameter error", state do
        assert {:error, %Parameter{}} = ReqLLM.generate_text(state.model, state.context)
      end

      test "generate_object returns a local parameter error", state do
        schema = [translation: [type: :string, required: true]]

        assert {:error, %Parameter{}} =
                 ReqLLM.generate_object(state.model, state.context, schema)
      end

      @tag :capture_log
      test "stream_text retains the parameter error from request preparation", state do
        assert {:error, {:http_streaming_failed, {:provider_build_failed, %Parameter{}}}} =
                 ReqLLM.stream_text(state.model, state.context)
      end

      test "stream_object returns a local parameter error", state do
        schema = [translation: [type: :string, required: true]]

        assert {:error, %Parameter{}} =
                 ReqLLM.stream_object(state.model, state.context, schema)
      end
    end
  end

  test "Vertex validation uses the provider model ID" do
    model = %LLMDB.Model{
      id: "custom-model",
      provider: :google_vertex,
      provider_model_id: "gemini-3.8-flash"
    }

    context = Context.new([Context.user("Translate hello"), Context.assistant("Translation:")])

    assert {:error, %Parameter{}} = GoogleVertex.prepare_request(:chat, model, context, [])
    assert {:error, %Parameter{}} = GoogleVertex.attach_stream(model, context, [], nil)
  end

  test "Vertex validation uses Gemini family metadata" do
    model = %LLMDB.Model{id: "custom-model", provider: :google_vertex, extra: %{family: "gemini"}}
    context = Context.new([Context.user("Translate hello"), Context.assistant("Translation:")])

    assert {:error, %Parameter{}} = GoogleVertex.prepare_request(:chat, model, context, [])
    assert {:error, %Parameter{}} = GoogleVertex.attach_stream(model, context, [], nil)
  end

  for model_id <- ["claude-haiku-4-5@20251001", "mistral-small-2503", "zai-org/glm-4.7-maas"] do
    test "Vertex keeps assistant prefill for #{model_id}" do
      model = ReqLLM.model!("google_vertex:" <> unquote(model_id))
      context = Context.new([Context.user("Translate hello"), Context.assistant("Translation:")])
      opts = [access_token: "test-token", project_id: "test-project", region: "us-central1"]

      assert {:ok, %Req.Request{}} = GoogleVertex.prepare_request(:chat, model, context, opts)
      assert {:ok, %Finch.Request{}} = GoogleVertex.attach_stream(model, context, opts, nil)
    end
  end

  defp tool_context do
    Context.new([
      Context.user("Translate hello"),
      Context.assistant("",
        tool_calls: [%{id: "call_1", name: "translate", arguments: %{"text" => "hello"}}]
      )
    ])
  end
end
