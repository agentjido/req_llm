defmodule ReqLLM.Providers.OllamaTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Providers.Ollama

  defp ollama_model do
    %LLMDB.Model{
      id: "qwen2.5-coder:14b",
      model: "qwen2.5-coder:14b",
      provider: :ollama,
      capabilities: %{chat: true, tools: %{enabled: true}},
      limits: %{context: 32_768, output: 4096}
    }
  end

  defp req_with_opts(opts) do
    %Req.Request{options: Map.new(opts)}
  end

  defp materialize_body_through_request_steps(%Req.Request{} = request) do
    skip = [:run_finch, :put_plug, :cache, :llm_telemetry_start]

    Enum.reduce(request.request_steps, request, fn {name, step}, acc ->
      if name in skip do
        acc
      else
        case step.(acc) do
          %Req.Request{} = req -> req
          {%Req.Request{} = req, _resp_or_err} -> req
        end
      end
    end)
  end

  defp simple_context do
    %ReqLLM.Context{
      messages: [
        %ReqLLM.Message{
          role: :user,
          content: [%ReqLLM.Message.ContentPart{type: :text, text: "hello"}]
        }
      ]
    }
  end

  describe "build_body/1" do
    test "omits :options key when no num_ctx given" do
      request = req_with_opts(model: "llama3", context: simple_context())
      body = Ollama.build_body(request)
      refute Map.has_key?(body, :options)
    end

    test "injects options.num_ctx when num_ctx is given" do
      request = req_with_opts(model: "llama3", context: simple_context(), num_ctx: 4096)
      body = Ollama.build_body(request)
      assert body.options == %{num_ctx: 4096}
    end

    test "injects keep_alive at body top-level when given" do
      request = req_with_opts(model: "llama3", context: simple_context(), keep_alive: "30m")
      body = Ollama.build_body(request)
      assert body.keep_alive == "30m"
    end
  end

  describe "attach/3" do
    test "sets no authorization header" do
      request = Req.new(url: "http://localhost:11434/v1/chat/completions")
      result = Ollama.attach(request, ollama_model(), [])
      refute Map.has_key?(result.headers, "authorization")
    end

    test "keeps standard response pipeline steps" do
      result = Ollama.attach(Req.new(), ollama_model(), [])

      request_steps = Keyword.keys(result.request_steps)
      response_steps = Keyword.keys(result.response_steps)

      assert :llm_encode_body in request_steps
      assert :llm_decode_response in response_steps
      assert :llm_usage in response_steps
      assert :llm_telemetry_stop in response_steps
      assert result.private[:req_llm_model].provider == :ollama
    end
  end

  describe "prepare_request/4" do
    test "object requests use Ollama json_schema response format" do
      {:ok, compiled_schema} =
        ReqLLM.Schema.compile(answer: [type: :string, required: true])

      {:ok, request} =
        Ollama.prepare_request(:object, ollama_model(), "Return ok",
          compiled_schema: compiled_schema
        )

      encoded = Ollama.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(encoded)

      assert body["response_format"]["type"] == "json_schema"
      assert body["response_format"]["json_schema"]["name"] == "structured_output"

      assert body["response_format"]["json_schema"]["schema"]["properties"]["answer"]["type"] ==
               "string"

      refute Map.has_key?(body, "tools")
      refute Map.has_key?(body, "tool_choice")
    end
  end

  describe "request body materialization" do
    test "llm_encode_body runs before Req's encode_body so the body is materialized" do
      {:ok, request} = Ollama.prepare_request(:chat, ollama_model(), "ping", [])

      step_keys = Keyword.keys(request.request_steps)

      assert Enum.find_index(step_keys, &(&1 == :llm_encode_body)) <
               Enum.find_index(step_keys, &(&1 == :encode_body)),
             "llm_encode_body must precede Req's encode_body, got: #{inspect(step_keys)}"
    end

    test "outgoing request carries a non-empty JSON body with model + messages" do
      {:ok, request} = Ollama.prepare_request(:chat, ollama_model(), "ping", [])

      materialized = materialize_body_through_request_steps(request)

      body = materialized.body
      assert is_binary(body) or is_list(body)
      body_string = IO.iodata_to_binary(body)
      refute body_string == "", "outgoing request body must not be empty"

      decoded = Jason.decode!(body_string)
      assert decoded["model"] == "qwen2.5-coder:14b"
      assert is_list(decoded["messages"])
      assert decoded["messages"] != []
    end
  end

  describe "attach_stream/4" do
    test "builds auth-free streaming request without Ollama API key" do
      original_key = System.get_env("OLLAMA_API_KEY")
      System.delete_env("OLLAMA_API_KEY")

      try do
        assert {:ok, request} =
                 Ollama.attach_stream(ollama_model(), simple_context(), [], ReqLLM.Finch)

        headers = Map.new(request.headers)

        assert request.method == "POST"
        assert request.scheme == :http
        assert request.host == "localhost"
        assert request.path == "/v1/chat/completions"
        assert headers["Accept"] == "text/event-stream"
        refute Map.has_key?(headers, "Authorization")
      after
        if original_key, do: System.put_env("OLLAMA_API_KEY", original_key)
      end
    end

    test "carries a non-empty JSON body with model + messages (regression: empty-body bug)" do
      assert {:ok, request} =
               Ollama.attach_stream(ollama_model(), simple_context(), [], ReqLLM.Finch)

      assert is_binary(request.body) or is_list(request.body)
      body_string = IO.iodata_to_binary(request.body)
      refute body_string == "", "streaming request body must not be empty"

      decoded = Jason.decode!(body_string)
      assert decoded["model"] == "qwen2.5-coder:14b"
      assert decoded["stream"] == true
      assert is_list(decoded["messages"])
      assert decoded["messages"] != []
    end
  end
end
