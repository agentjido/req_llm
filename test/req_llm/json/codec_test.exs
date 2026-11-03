defmodule ReqLLM.JSON.CodecTest do
  use ExUnit.Case, async: false

  alias ReqLLM.JSON.Codec

  defmodule UpcaseCodec do
    def encode(%{"fail" => true}), do: {:error, :unsupported}
    def encode(%{"raise" => true}), do: raise(ArgumentError, "unsupported")
    def encode(term), do: {:ok, ["{\"via\":", Jason.encode!(term), "}"]}

    def decode("bad"), do: {:error, :invalid}
    def decode(json), do: {:ok, {:decoded, json}}
  end

  setup do
    previous = Application.get_env(:req_llm, :json_library)
    on_exit(fn -> restore(previous) end)
  end

  test "defaults to Jason" do
    Application.delete_env(:req_llm, :json_library)

    assert Codec.library() == Jason
    assert Codec.encode!(%{"a" => 1}) == ~s({"a":1})
    assert Codec.decode(~s({"a":1})) == {:ok, %{"a" => 1}}
  end

  test "uses Jason while the configured library can't be loaded" do
    Application.put_env(:req_llm, :json_library, NotCompiledYet.JSON)

    assert Codec.library() == Jason
    assert Codec.decode(~s({"a":1})) == {:ok, %{"a" => 1}}
  end

  describe "with a configured library" do
    setup do
      Application.put_env(:req_llm, :json_library, UpcaseCodec)
    end

    test "encodes through the library as a binary" do
      assert Codec.encode(%{"a" => 1}) == {:ok, ~s({"via":{"a":1}})}
      assert Codec.encode!(%{"a" => 1}) == ~s({"via":{"a":1}})
      assert Codec.encode_to_iodata!(%{"a" => 1}) == ~s({"via":{"a":1}})
    end

    test "falls back to Jason for encodes the library rejects" do
      assert Codec.encode!(%{"fail" => true}) == ~s({"fail":true})
      assert Codec.encode!(%{"raise" => true}) == ~s({"raise":true})
    end

    test "sends calls with options to Jason" do
      assert Codec.encode!(%{"a" => 1}, pretty: true) == "{\n  \"a\": 1\n}"
      assert Codec.decode(~s({"a":1}), keys: :atoms) == {:ok, %{a: 1}}
    end

    test "decodes iodata through the library" do
      assert Codec.decode(["{", "}"]) == {:ok, {:decoded, "{}"}}
      assert Codec.decode("bad") == {:error, :invalid}
    end

    test "decode! raises Jason.DecodeError when the library rejects input" do
      assert_raise Jason.DecodeError, fn -> Codec.decode!("bad") end
    end

    test "ReqLLM.JSON.decode goes through the library" do
      assert ReqLLM.JSON.decode("{}") == {:ok, {:decoded, "{}"}}
    end
  end

  defp restore(nil), do: Application.delete_env(:req_llm, :json_library)
  defp restore(library), do: Application.put_env(:req_llm, :json_library, library)
end
