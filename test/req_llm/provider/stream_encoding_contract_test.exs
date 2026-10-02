defmodule ReqLLM.Provider.StreamEncodingContractTest do
  use ExUnit.Case, async: true

  alias ReqLLM.{Context, Message, Tool}
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Provider.{Defaults, Options}

  defmodule EncoderFailure do
    use ReqLLM.Provider,
      id: :issue1068_encoder,
      default_base_url: "https://example.invalid/v1",
      default_env_key: "ISSUE1068_UNUSED_KEY"

    def encode_body(_request), do: raise(ArgumentError, "ISSUE1068_ENCODER_FAILURE")
  end

  defp tool(name, callback) do
    Tool.new!(name: name, description: "Review probe", parameter_schema: [], callback: callback)
  end

  defp stream_result(result) do
    {:ok, result.()}
  rescue
    error -> {:raised, error.__struct__}
  catch
    :exit, reason -> {:exit, reason}
  end

  defp buffered_body(provider, model, context, opts) do
    request = %Req.Request{
      method: :post,
      url: URI.parse("https://example.invalid"),
      options: Map.new([model: model.id, context: context] ++ opts),
      private: %{req_llm_model: model}
    }

    request
    |> provider.encode_body()
    |> Req.Steps.encode_body()
    |> Map.fetch!(:body)
    |> Jason.decode!()
  end

  test "encoder rejection returns an error without reducing request content" do
    model = %LLMDB.Model{provider: :issue1068_encoder, id: "probe"}

    context =
      Context.new([
        %Message{
          role: :user,
          content: [
            ContentPart.text("probe"),
            ContentPart.video_url("https://example.invalid/video.mp4")
          ]
        }
      ])

    assert {:error, error} =
             Defaults.default_attach_stream(
               EncoderFailure,
               model,
               context,
               [api_key: "probe", tools: [tool("probe_tool", fn _ -> {:ok, :ok} end)]],
               ReqLLM.Finch
             )

    assert Exception.message(error) =~ "ISSUE1068_ENCODER_FAILURE"
    model = %{model | provider: :cerebras}

    assert {:error, error} =
             ReqLLM.Providers.Cerebras.attach_stream(
               model,
               context,
               [api_key: "probe"],
               ReqLLM.Finch
             )

    assert Exception.message(error) =~ "Video URLs are not supported"
  end

  test "Cerebras strict model metadata is preserved in streaming encoding" do
    model = %LLMDB.Model{
      provider: :cerebras,
      id: "probe",
      capabilities: %{tools: %{strict: true}}
    }

    context = Context.new([Context.user("probe")])
    opts = [api_key: "probe", tools: [tool("probe_tool", fn _ -> {:ok, :ok} end)]]
    buffered = buffered_body(ReqLLM.Providers.Cerebras, model, context, opts)
    assert buffered["tools"] |> hd() |> get_in(["function", "strict"]) == true

    assert {:ok, request} =
             ReqLLM.Providers.Cerebras.attach_stream(model, context, opts, ReqLLM.Finch)

    streaming = Jason.decode!(request.body)
    assert streaming["tools"] == buffered["tools"]
  end

  test "provider streaming uses the generated default processing path" do
    providers = [
      ReqLLM.Providers.Groq,
      ReqLLM.Providers.Mistral,
      ReqLLM.Providers.Minimax,
      ReqLLM.Providers.ZaiCodingPlan
    ]

    cases = [
      [api_key: "probe"],
      [
        api_key: "probe",
        base_url: "https://example.invalid/custom",
        temperature: 0.2,
        req_http_options: [headers: [{"x-probe", "1"}]]
      ],
      [api_key: "probe", temperature: :invalid]
    ]

    for provider <- providers, opts <- cases do
      model = %LLMDB.Model{provider: provider.provider_id(), id: "probe"}
      context = Context.new([Context.user("probe")])

      current =
        stream_result(fn -> provider.attach_stream(model, context, opts, ReqLLM.Finch) end)

      default =
        stream_result(fn ->
          processed =
            Options.process_stream!(provider, opts[:operation] || :chat, model, context, opts)

          Defaults.default_attach_stream(provider, model, context, processed, ReqLLM.Finch)
        end)

      assert current == default
    end
  end

  test "strict and non-strict models have identical buffered and streaming schemas" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "name" => %{"type" => "string", "minLength" => 2},
        "count" => %{"type" => "integer", "minimum" => 1}
      }
    }

    tool =
      Tool.new!(
        name: "schema_tool",
        description: "Schema",
        parameter_schema: schema,
        callback: fn _ -> {:ok, :ok} end
      )

    context = Context.new([Context.user("probe")])

    for strict <- [true, false] do
      model = %LLMDB.Model{
        provider: :cerebras,
        id: "probe",
        capabilities: %{tools: %{strict: strict}}
      }

      opts = [api_key: "probe", tools: [tool]]
      buffered = buffered_body(ReqLLM.Providers.Cerebras, model, context, opts)

      assert {:ok, request} =
               ReqLLM.Providers.Cerebras.attach_stream(model, context, opts, ReqLLM.Finch)

      assert Jason.decode!(request.body)["tools"] == buffered["tools"]
      function = hd(buffered["tools"])["function"]

      if strict do
        assert function["strict"]
        assert function["parameters"]["properties"]["count"]["minimum"] == 1
      else
        refute function["strict"]
        refute function["parameters"]["properties"]["count"]["minimum"]
      end
    end
  end

  defmodule ModelEncoder do
    use ReqLLM.Provider,
      id: :model_encoder,
      default_base_url: "https://example.invalid",
      default_env_key: "UNUSED_TEST_KEY"

    def encode_body(request) do
      model = request.private.req_llm_model

      %{
        request
        | body: Jason.encode!(%{model_metadata: model.id, stream: request.options.stream})
      }
    end
  end

  test "custom encoders receive the supplied model" do
    model = %LLMDB.Model{provider: :model_encoder, id: "explicit-model"}

    assert {:ok, request} =
             ModelEncoder.attach_stream(model, Context.new([]), [api_key: "probe"], ReqLLM.Finch)

    assert Jason.decode!(request.body) == %{
             "model_metadata" => "explicit-model",
             "stream" => true
           }
  end

  test "valid streaming requests retain images, tools, tool results, and provider options" do
    tool = tool("probe_tool", fn _ -> {:ok, :ok} end)

    context =
      Context.new([
        %Message{
          role: :user,
          content: [
            ContentPart.text("probe"),
            ContentPart.image_url("https://example.invalid/image.png")
          ]
        },
        Context.assistant("", tool_calls: [{"probe_tool", %{}, id: "call_1"}]),
        Context.tool_result_message("probe_tool", "call_1", "result")
      ])

    model = %LLMDB.Model{provider: :mistral, id: "probe"}
    opts = [api_key: "probe", tools: [tool], provider_options: [random_seed: 123]]

    assert {:ok, request} =
             ReqLLM.Providers.Mistral.attach_stream(model, context, opts, ReqLLM.Finch)

    body = Jason.decode!(request.body)
    assert body["random_seed"] == 123
    assert length(body["tools"]) == 1
    assert Enum.any?(hd(body["messages"])["content"], &(&1["type"] == "image_url"))
    assert List.last(body["messages"])["tool_call_id"] == "call_1"
  end
end
