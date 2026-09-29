defmodule ReqLLM.CatalogGatewayTest do
  use ExUnit.Case, async: false

  alias ReqLLM.Providers.CatalogGateway

  @chat_contract %{
    supported: true,
    family: "openai_chat_compatible",
    wire_protocol: "openai_chat",
    path: "/chat/completions"
  }

  test "a registered provider module keeps priority over catalog execution metadata" do
    model = ReqLLM.model!(%{provider: :openai, id: "custom-chat"})

    assert {:ok, ReqLLM.Providers.OpenAI} = ReqLLM.ProviderDispatch.get(model, :chat)
  end

  test "an unregistered provider uses explicit OpenAI Chat Completions metadata" do
    assert :perplexity not in ReqLLM.Providers.list()
    model = model(:perplexity, %{@chat_contract | path: "/completions"})

    Req.Test.stub(__MODULE__.TextHTTP, fn conn ->
      assert conn.host == "custom.example.test"
      assert conn.request_path == "/v1/custom/completions"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer request-key"]
      assert conn.body_params["model"] == "wire-model"

      Req.Test.json(conn, %{
        "id" => "response-1",
        "model" => "wire-model",
        "choices" => [%{"message" => %{"role" => "assistant", "content" => "Hello"}}],
        "usage" => %{"prompt_tokens" => 3, "completion_tokens" => 1, "total_tokens" => 4}
      })
    end)

    assert {:ok, ReqLLM.Providers.CatalogGateway} =
             ReqLLM.ProviderDispatch.get(model, :chat)

    assert {:ok, response} =
             ReqLLM.generate_text(model, "Hi",
               api_key: "request-key",
               req_http_options: [plug: {Req.Test, __MODULE__.TextHTTP}]
             )

    assert ReqLLM.Response.text(response) == "Hello"
    assert response.model == "wire-model"
  end

  test "object requests need their own execution contract and use its endpoint" do
    model = model(:perplexity, @chat_contract)

    assert {:error, error} = ReqLLM.ProviderDispatch.get(model, :object)
    assert Exception.message(error) =~ "object execution contract"

    model = %{
      model
      | execution:
          Map.put(
            model.execution,
            :object,
            @chat_contract
            |> Map.put(:path, "/objects")
            |> Map.put(:provider_model_id, "object-wire-model")
          )
    }

    assert {:ok, _} = ReqLLM.ProviderDispatch.get(model, :object)

    assert {:ok, compiled_schema} =
             ReqLLM.Schema.compile(%{type: "object", properties: %{name: %{type: "string"}}})

    assert {:ok, request} =
             CatalogGateway.prepare_request(:object, model, "Give a name",
               api_key: "request-key",
               compiled_schema: compiled_schema
             )

    assert request.url.path == "/objects"
    assert request.options[:model] == "object-wire-model"

    Req.Test.stub(__MODULE__.ObjectHTTP, fn conn ->
      assert conn.host == "api.perplexity.ai"
      assert conn.request_path == "/objects"
      assert conn.body_params["model"] == "object-wire-model"

      Req.Test.json(conn, %{
        "id" => "response-object",
        "model" => "object-wire-model",
        "choices" => [
          %{
            "message" => %{
              "role" => "assistant",
              "tool_calls" => [
                %{
                  "id" => "call-1",
                  "type" => "function",
                  "function" => %{
                    "name" => "structured_output",
                    "arguments" => ~s({"name":"Ada"})
                  }
                }
              ]
            },
            "finish_reason" => "tool_calls"
          }
        ]
      })
    end)

    assert {:ok, response} =
             ReqLLM.generate_object(model, "Give a name", [name: [type: :string, required: true]],
               api_key: "request-key",
               req_http_options: [plug: {Req.Test, __MODULE__.ObjectHTTP}]
             )

    assert response.object == %{"name" => "Ada"}
  end

  test "stream requests use declared endpoint, model ID, and bearer key" do
    model = model(:friendli, @chat_contract)
    {:ok, context} = ReqLLM.Context.normalize("Hello", [])

    assert {:ok, request} =
             CatalogGateway.attach_stream(
               model,
               context,
               [api_key: "request-key", stream: true],
               nil
             )

    assert request.scheme == :https
    assert request.host == "custom.example.test"
    assert request.path == "/v1/custom/chat/completions"
    assert {"Authorization", "Bearer request-key"} in request.headers

    assert request.body |> IO.iodata_to_binary() |> Jason.decode!() |> Map.fetch!("model") ==
             "wire-model"
  end

  test "object streams keep the object endpoint and tool request" do
    model = model(:perplexity, @chat_contract)

    object_contract =
      Map.merge(@chat_contract, %{path: "/objects", provider_model_id: "object-wire"})

    model = %{model | execution: Map.put(model.execution, :object, object_contract)}
    {:ok, schema} = ReqLLM.Schema.compile(name: [type: :string, required: true])

    assert {:ok, prepared} =
             CatalogGateway.prepare_request(:object, model, "Give a name",
               api_key: "request-key",
               compiled_schema: schema
             )

    assert {:ok, request} =
             CatalogGateway.attach_stream(
               model,
               prepared.options[:context],
               prepared.options
               |> Map.to_list()
               |> Keyword.put(:stream, true)
               |> Keyword.put(:operation, :object),
               nil
             )

    body = request.body |> IO.iodata_to_binary() |> Jason.decode!()
    assert request.path == "/objects"
    assert body["model"] == "object-wire"
    assert body["tools"] |> Enum.at(0) |> get_in(["function", "name"]) == "structured_output"
  end

  test "telemetry and API errors keep the catalog provider ID" do
    model = model(:perplexity, @chat_contract)
    handler_id = "catalog-gateway-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach_many(
        handler_id,
        [[:req_llm, :request, :start], [:req_llm, :request, :exception]],
        fn event, _measurements, metadata, _config ->
          send(test_pid, {event, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    Req.Test.stub(__MODULE__.ErrorHTTP, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(401, Jason.encode!(%{"error" => %{"message" => "bad key"}}))
    end)

    assert {:error, error} =
             ReqLLM.generate_text(model, "Hi",
               api_key: "request-key",
               max_retries: 0,
               req_http_options: [plug: {Req.Test, __MODULE__.ErrorHTTP}]
             )

    assert Exception.message(error) =~ "Perplexity"
    assert_receive {[:req_llm, :request, :start], %{provider: :perplexity}}
    assert_receive {[:req_llm, :request, :exception], %{provider: :perplexity}}
  end

  test "unsupported contracts and missing provider runtime fail with clear errors" do
    model = model(:perplexity, %{@chat_contract | family: "openai_responses_compatible"})

    assert {:error, error} = ReqLLM.ProviderDispatch.get(model, :chat)
    assert Exception.message(error) =~ "openai_chat_compatible"

    orca = model(:orcarouter, @chat_contract)
    assert {:error, error} = ReqLLM.ProviderDispatch.get(orca, :chat)
    assert Exception.message(error) =~ "runtime metadata"

    catalog_only = %{model(:perplexity, @chat_contract) | catalog_only: true}
    assert {:error, error} = ReqLLM.ProviderDispatch.get(catalog_only, :chat)
    assert Exception.message(error) =~ "catalog only"
  end

  test "missing credentials name the declared environment variable" do
    model = model(:friendli, @chat_contract)
    previous = System.get_env("FRIENDLI_TOKEN")
    previous_config = Application.get_env(:req_llm, :friendli_api_key)

    on_exit(fn ->
      restore_env("FRIENDLI_TOKEN", previous)
      restore_config(:friendli_api_key, previous_config)
    end)

    System.delete_env("FRIENDLI_TOKEN")
    Application.delete_env(:req_llm, :friendli_api_key)

    assert {:error, error} = CatalogGateway.prepare_request(:chat, model, "Hi", [])
    assert Exception.message(error) =~ "FRIENDLI_TOKEN"

    System.put_env("FRIENDLI_TOKEN", "declared-env-key")
    assert {:ok, request} = CatalogGateway.prepare_request(:chat, model, "Hi", [])
    assert request.options[:auth] == {:bearer, "declared-env-key"}
  end

  defp model(provider, text_contract) do
    ReqLLM.model!(%{
      provider: provider,
      id: "catalog-model",
      capabilities: %{streaming: %{text: true}},
      execution: %{
        text:
          Map.merge(text_contract, %{
            provider_model_id: "wire-model",
            base_url: "https://custom.example.test/v1/custom"
          })
      }
    })
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  defp restore_config(key, nil), do: Application.delete_env(:req_llm, key)
  defp restore_config(key, value), do: Application.put_env(:req_llm, key, value)
end
