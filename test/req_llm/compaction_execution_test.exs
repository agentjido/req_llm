defmodule ReqLLM.CompactionExecutionTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Context
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Response
  alias ReqLLM.Test.WorkflowHTTP

  @moduletag contract: :public_api
  @model %{provider: :compaction_execution_test, id: "custom-compactor"}

  defmodule Provider do
    use ReqLLM.Provider,
      id: :compaction_execution_test,
      default_base_url: "https://compaction.example"

    @impl true
    def prepare_request(operation, model, input, opts) do
      Keyword.fetch!(opts, :prepare).(operation, model, input, opts)
    end
  end

  setup_all do
    ReqLLM.Providers.register!(Provider)
    on_exit(fn -> ReqLLM.Providers.unregister(:compaction_execution_test) end)
  end

  test "normalizes input and finalizes the returned replay window without changing callback options" do
    owner = self()
    schema = NimbleOptions.new!(value: [type: :string])

    replay = %{
      provider: :openai,
      items: [%{"type" => "compaction", "encrypted_content" => "opaque"}]
    }

    message = %Message{
      role: :assistant,
      content: [ContentPart.text("retained")],
      metadata: %{response_id: "cmp_1", responses_replay: replay}
    }

    response = %Response{
      model: "custom-compactor",
      id: "cmp_1",
      message: message,
      context: Context.new([Context.user("old"), message]),
      usage: %{input_tokens: 12, output_tokens: 3},
      provider_meta: %{retained: true}
    }

    prepare = fn :compact, %LLMDB.Model{id: "custom-compactor"}, context, opts ->
      send(owner, {:prepared, context, opts})
      {:ok, WorkflowHTTP.request(%Req.Response{status: 201, body: response})}
    end

    assert {:ok, compacted} =
             ReqLLM.compact_context(@model, "Hello",
               prepare: prepare,
               operation: :chat,
               schema: schema,
               req_http_options: %{receive_timeout: 1234},
               duplicate: :first,
               duplicate: :second
             )

    assert_receive {:prepared, %Context{messages: [%Message{role: :user, content: [part]}]}, opts}
    assert part == ContentPart.text("Hello")
    assert opts[:operation] == :compact
    assert opts[:schema] == schema
    assert opts[:req_http_options] == %{receive_timeout: 1234}
    assert Keyword.get_values(opts, :duplicate) == [:first, :second]
    refute_received {:prepared, _, _}

    expected_message = %{
      message
      | metadata: %{compaction_response_id: "cmp_1", responses_replay: replay}
    }

    assert compacted == %{
             response
             | message: expected_message,
               context: Context.new([expected_message])
           }
  end

  test "keeps a decoded Response without a message unchanged" do
    response = %Response{
      model: "custom-compactor",
      id: "cmp_empty",
      context: Context.new([]),
      message: nil
    }

    prepare = fn :compact, _model, _input, _opts ->
      {:ok, WorkflowHTTP.request(%Req.Response{status: 200, body: response})}
    end

    assert ReqLLM.compact_context(@model, nil, previous_response_id: "stored", prepare: prepare) ==
             {:ok, response}
  end

  for status <- [200, 422] do
    @status status

    test "retains the compaction request error for a #{@status} non-Response body" do
      body = %{"error" => "not a decoded response"}

      prepare = fn :compact, _model, _input, _opts ->
        {:ok, WorkflowHTTP.request(%Req.Response{status: @status, body: body})}
      end

      assert {:error, %ReqLLM.Error.API.Request{} = error} =
               ReqLLM.compact_context(@model, "Hello", prepare: prepare)

      assert error.status == @status
      assert error.reason == "HTTP #{@status}: compaction request failed"
      assert error.response_body == body

      assert Exception.message(error) ==
               "API request failed (#{@status}): HTTP #{@status}: compaction request failed"
    end
  end

  test "passes preparation and transport errors through unchanged" do
    for error <- [{:compaction_rejected, :context}, %Req.TransportError{reason: :closed}] do
      prepare = fn :compact, _model, _input, _opts ->
        case error do
          %Req.TransportError{} -> {:ok, WorkflowHTTP.request(error)}
          _ -> {:error, error}
        end
      end

      assert ReqLLM.compact_context(@model, "Hello", prepare: prepare) == {:error, error}
    end
  end

  test "enforces the original total timeout after provider preparation" do
    owner = self()

    prepare = fn :compact, _model, _input, _opts ->
      Process.sleep(30)

      {:ok,
       WorkflowHTTP.request(fn request ->
         send(owner, :unexpected_compaction_request)

         {request,
          %Req.Response{
            status: 200,
            body: %Response{model: "custom-compactor", id: "cmp_late", context: Context.new([])}
          }}
       end)}
    end

    assert {:error, %ReqLLM.Error.API.Timeout{kind: :total, timeout: 20}} =
             ReqLLM.compact_context(@model, "Hello", prepare: prepare, total_timeout: 20)

    refute_received :unexpected_compaction_request
  end

  test "enforces total_timeout while the request is running" do
    prepare = fn :compact, _model, _input, _opts ->
      {:ok,
       WorkflowHTTP.request(fn request ->
         receive do
           :finish_request ->
             {request,
              %Req.Response{
                status: 200,
                body: %Response{
                  model: "custom-compactor",
                  id: "cmp_late",
                  context: Context.new([])
                }
              }}
         end
       end)}
    end

    assert {:error, %ReqLLM.Error.API.Timeout{kind: :total, timeout: 50}} =
             ReqLLM.compact_context(@model, "Hello", prepare: prepare, total_timeout: 50)
  end
end
