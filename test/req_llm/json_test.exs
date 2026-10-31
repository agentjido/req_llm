defmodule ReqLLM.JSONTest do
  use ExUnit.Case, async: false

  defmodule Codec do
    @behaviour ReqLLM.JSON.Codec

    @impl true
    def decode!(json), do: Jason.decode!(json)

    @impl true
    def encode!(term), do: "\n" <> Jason.encode!(term)

    @impl true
    def encode_to_iodata!(term), do: ["\n", Jason.encode_to_iodata!(term)]
  end

  setup do
    previous = Application.fetch_env(:req_llm, :json_library)

    on_exit(fn ->
      case previous do
        {:ok, library} -> Application.put_env(:req_llm, :json_library, library)
        :error -> Application.delete_env(:req_llm, :json_library)
      end
    end)

    :ok
  end

  test "uses Jason by default" do
    Application.delete_env(:req_llm, :json_library)

    assert ReqLLM.JSON.json_library() == Jason
    assert ReqLLM.JSON.decode!(ReqLLM.JSON.encode!(%{"ok" => true})) == %{"ok" => true}
  end

  test "uses the configured Phoenix-style JSON library" do
    Application.put_env(:req_llm, :json_library, Codec)

    assert ReqLLM.JSON.json_library() == Codec
    assert ReqLLM.JSON.encode!(%{ok: true}) =~ "\n{"
    assert ReqLLM.JSON.encode_to_iodata!(%{ok: true}) |> IO.iodata_to_binary() =~ "\n{"
    assert ReqLLM.JSON.decode!(~s({"ok":true})) == %{"ok" => true}
  end

  test "rejects a library that does not implement the contract" do
    Application.put_env(:req_llm, :json_library, String)

    assert_raise ArgumentError, ~r/missing decode!\/1, encode!\/1, encode_to_iodata!\/1/, fn ->
      ReqLLM.JSON.json_library()
    end
  end

  test "materializes Req JSON with the configured library and decoder" do
    Application.put_env(:req_llm, :json_library, Codec)
    request = Req.new(json: %{hello: "world"})

    materialized = ReqLLM.JSON.materialize_request(request)

    assert materialized.body == ~s(\n{"hello":"world"})
    refute Map.has_key?(materialized.options, :json)

    assert materialized.options[:decoders][:json].(~s({"answer":42})) ==
             {:ok, %{"answer" => 42}}
  end

  test "keeps the existing Req path for Jason" do
    Application.delete_env(:req_llm, :json_library)
    request = Req.new(json: %{hello: "world"})

    assert ReqLLM.JSON.materialize_request(request) == request
  end

  test "uses the configured library while repairing model output" do
    Application.put_env(:req_llm, :json_library, Codec)

    assert ReqLLM.JSON.decode(~s({"answer":42,})) == {:ok, %{"answer" => 42}}
  end
end
