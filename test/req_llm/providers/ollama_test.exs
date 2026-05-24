defmodule ReqLLM.Providers.OllamaTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Providers.Ollama

  defp req_with_opts(opts) do
    %Req.Request{options: Map.new(opts)}
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
      result = Ollama.attach(request, nil, [])
      refute Map.has_key?(result.headers, "authorization")
    end
  end
end
