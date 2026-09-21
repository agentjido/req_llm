defmodule ReqLLM.RouterTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Router
  alias ReqLLM.Router.Trie

  defmodule TrieRouter do
    @behaviour Router

    @impl true
    def resolve(%Router{options: trie}, operation, input, opts) do
      request = %{operation: operation, input: input, opts: opts}

      with {:ok, [model_spec | _rest]} <- Trie.route(trie, Atom.to_string(operation), request) do
        {:ok, model_spec}
      end
    end
  end

  defmodule InspectingRouter do
    @behaviour Router

    @impl true
    def resolve(%Router{options: test_pid}, operation, input, opts) do
      send(test_pid, {:resolve, operation, input, opts})
      {:error, :stopped_after_routing}
    end
  end

  defmodule StaticRouter do
    @behaviour Router

    @impl true
    def resolve(%Router{options: model_spec}, _operation, _input, _opts),
      do: {:ok, model_spec}
  end

  defmodule InvalidRouter do
    @behaviour Router

    @impl true
    def resolve(_router, _operation, _input, _opts), do: :invalid
  end

  test "router resolves a guarded trie target to an LLMDB model" do
    trie =
      Trie.new!([
        {"chat", &(&1.input == "hard"), "openai:gpt-4o", 10},
        {"chat", "openai:gpt-4o-mini"}
      ])

    router = Router.new!(TrieRouter, trie)

    assert {:ok, %LLMDB.Model{provider: :openai, id: "gpt-4o"}} =
             Router.resolve(router, :chat, "hard", [])

    assert {:ok, %LLMDB.Model{provider: :openai, id: "gpt-4o-mini"}} =
             Router.resolve(router, :chat, "easy", [])
  end

  test "router requires a resolve/4 callback" do
    assert {:error, error} = Router.new(String)
    assert Exception.message(error) =~ "router module must export resolve/4"
  end

  test "router rejects invalid callback return values" do
    router = Router.new!(InvalidRouter)

    assert {:error, error} = Router.resolve(router, :chat, "hello", [])
    assert Exception.message(error) =~ "must return {:ok, model_spec} or {:error, reason}"
  end

  test "generate_text continues through the existing provider path after routing" do
    router = Router.new!(StaticRouter, "openai:gpt-4o-mini")

    Req.Test.stub(__MODULE__.TextHTTP, fn conn ->
      assert conn.body_params["model"] == "gpt-4o-mini"

      Req.Test.json(conn, %{
        "id" => "response-1",
        "model" => "gpt-4o-mini",
        "choices" => [%{"message" => %{"role" => "assistant", "content" => "Hello"}}],
        "usage" => %{"prompt_tokens" => 2, "completion_tokens" => 1, "total_tokens" => 3}
      })
    end)

    assert {:ok, response} =
             ReqLLM.generate_text(router, "Hi",
               api_key: "test-key",
               req_http_options: [plug: {Req.Test, __MODULE__.TextHTTP}]
             )

    assert response.model == "gpt-4o-mini"
  end

  test "all generation forms route before static model resolution" do
    router = Router.new!(InspectingRouter, self())

    assert {:error, :stopped_after_routing} = ReqLLM.generate_text(router, "text prompt")
    assert_receive {:resolve, :chat, "text prompt", []}

    assert {:error, :stopped_after_routing} = ReqLLM.stream_text(router, "stream prompt")
    assert_receive {:resolve, :chat, "stream prompt", []}

    schema = [name: [type: :string, required: true]]

    assert {:error, :stopped_after_routing} =
             ReqLLM.generate_object(router, "object prompt", schema)

    assert_receive {:resolve, :object, "object prompt", []}

    assert {:error, :stopped_after_routing} =
             ReqLLM.stream_object(router, "stream object prompt", schema)

    assert_receive {:resolve, :object, "stream object prompt", []}
  end
end
