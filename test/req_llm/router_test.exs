defmodule ReqLLM.RouterTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Router
  alias ReqLLM.Router.Request

  defmodule StaticRouter do
    @behaviour Router

    defstruct [:model_spec]

    @impl true
    def resolve(%__MODULE__{model_spec: model_spec}, %Request{}), do: ReqLLM.model(model_spec)
  end

  defmodule InspectingRouter do
    @behaviour Router

    defstruct [:test_pid]

    @impl true
    def resolve(%__MODULE__{test_pid: test_pid}, %Request{} = request) do
      send(test_pid, {:resolve, request})
      {:error, :stopped_after_routing}
    end
  end

  defmodule InvalidResultRouter do
    @behaviour Router

    defstruct []

    @impl true
    def resolve(%__MODULE__{}, %Request{}), do: {:ok, "openai:gpt-4o-mini"}
  end

  defmodule CallbackOnly do
    defstruct []

    def resolve(%__MODULE__{}, %Request{}), do: ReqLLM.model("openai:gpt-4o-mini")
  end

  test "an application struct implements the router behaviour directly" do
    router = %StaticRouter{model_spec: "openai:gpt-4o-mini"}
    assert Router.implementation?(router)
    refute Router.implementation?(%CallbackOnly{})
    refute Router.implementation?("openai:gpt-4o-mini")

    assert {:ok, request} = Request.new(:generate_text, :chat, "Hello")

    assert {:ok, %LLMDB.Model{provider: :openai, id: "gpt-4o-mini"}} =
             Router.resolve(router, request)
  end

  test "router callbacks must return a concrete LLMDB model" do
    assert {:ok, request} = Request.new(:generate_text, :chat, "Hello")

    assert {:error, error} = Router.resolve(%InvalidResultRouter{}, request)
    assert error.tag == :invalid_router_result
    assert Exception.message(error) =~ "must return {:ok, %LLMDB.Model{}}"

    assert {:error, error} = Router.resolve(%CallbackOnly{}, request)
    assert error.tag == :invalid_router
  end

  test "request normalizes context and exposes only stable routing data" do
    tool =
      ReqLLM.Tool.new!(
        name: "lookup",
        description: "Looks up a value",
        parameter_schema: [],
        callback: fn _arguments -> {:ok, "value"} end
      )

    assert {:ok, request} =
             Request.new(:stream_text, :chat, "Hello",
               system_prompt: "Be brief",
               tools: [tool],
               reasoning_effort: :high,
               routing_context: %{tenant: "acme"},
               api_key: "secret"
             )

    assert %ReqLLM.Context{} = request.context
    assert Enum.map(request.context.messages, & &1.role) == [:system, :user]
    assert request.context.tools == [tool]
    assert request.routing_context == %{tenant: "acme"}

    assert request.requirements == %{
             streaming?: true,
             structured_output?: false,
             tools?: true,
             reasoning_effort: :high
           }

    refute Map.has_key?(Map.from_struct(request), :opts)
    refute inspect(request) =~ "secret"
  end

  test "routing_context must be a map" do
    assert {:error, error} =
             Request.new(:generate_text, :chat, "Hello", routing_context: [:not, :a, :map])

    assert error.tag == :invalid_routing_context
  end

  test "generate_text continues through the existing provider path after routing" do
    router = %StaticRouter{model_spec: "openai:gpt-4o-mini"}

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
               routing_context: %{request_class: :interactive},
               req_http_options: [plug: {Req.Test, __MODULE__.TextHTTP}]
             )

    assert response.model == "gpt-4o-mini"
  end

  test "all generation forms send a normalized request to the router" do
    router = %InspectingRouter{test_pid: self()}

    assert {:error, :stopped_after_routing} =
             ReqLLM.generate_text(router, "text prompt",
               reasoning_effort: :medium,
               routing_context: %{speed: :fast}
             )

    assert_receive {:resolve,
                    %Request{
                      surface: :generate_text,
                      operation: :chat,
                      context: %ReqLLM.Context{},
                      routing_context: %{speed: :fast},
                      requirements: %{
                        streaming?: false,
                        structured_output?: false,
                        reasoning_effort: :medium
                      }
                    }}

    assert {:error, :stopped_after_routing} = ReqLLM.stream_text(router, "stream prompt")

    assert_receive {:resolve,
                    %Request{
                      surface: :stream_text,
                      operation: :chat,
                      requirements: %{streaming?: true, structured_output?: false}
                    }}

    schema = [name: [type: :string, required: true]]

    assert {:error, :stopped_after_routing} =
             ReqLLM.generate_object(router, "object prompt", schema)

    assert_receive {:resolve,
                    %Request{
                      surface: :generate_object,
                      operation: :object,
                      requirements: %{streaming?: false, structured_output?: true}
                    }}

    assert {:error, :stopped_after_routing} =
             ReqLLM.stream_object(router, "stream object prompt", schema)

    assert_receive {:resolve,
                    %Request{
                      surface: :stream_object,
                      operation: :object,
                      requirements: %{streaming?: true, structured_output?: true}
                    }}

    output = ReqLLM.Output.object(schema)

    assert {:error, :stopped_after_routing} =
             ReqLLM.generate_text(router, "output prompt", output: output)

    assert_receive {:resolve,
                    %Request{
                      surface: :generate_text,
                      operation: :object,
                      requirements: %{streaming?: false, structured_output?: true}
                    }}
  end
end
