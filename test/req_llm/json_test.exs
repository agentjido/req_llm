defmodule ReqLLM.JSONTest do
  use ExUnit.Case, async: false

  alias ReqLLM.JSON
  alias ReqLLM.JSON.OrderedObject
  alias ReqLLM.Test.JSONCodecStub

  defp with_codec(codec, fun) do
    previous = Application.get_env(:req_llm, :json_library)
    Application.put_env(:req_llm, :json_library, codec)

    try do
      fun.()
    after
      if previous do
        Application.put_env(:req_llm, :json_library, previous)
      else
        Application.delete_env(:req_llm, :json_library)
      end
    end
  end

  describe "json_library/0" do
    test "defaults to Jason" do
      Application.delete_env(:req_llm, :json_library)

      assert JSON.json_library() == Jason
    end

    test "returns the configured codec" do
      with_codec(JSONCodecStub, fn ->
        assert JSON.json_library() == JSONCodecStub
      end)
    end

    test "raises when the codec misses required callbacks" do
      with_codec(__MODULE__.Broken, fn ->
        assert_raise ArgumentError, ~r/Broken.*decode\/1/, fn ->
          JSON.decode("{}")
        end
      end)
    end

    test "raises for non-module values" do
      with_codec("Jason", fn ->
        assert_raise ArgumentError, ~r/expects a module/, fn ->
          JSON.json_library()
        end
      end)
    end
  end

  describe "encode and decode" do
    test "round-trips through the default codec" do
      Application.delete_env(:req_llm, :json_library)

      assert JSON.encode!(%{"a" => 1}) == ~s({"a":1})
      assert IO.iodata_to_binary(JSON.encode_to_iodata!(%{"a" => 1})) == ~s({"a":1})
      assert JSON.decode(~s({"a":1})) == {:ok, %{"a" => 1}}
      assert JSON.decode!(~s({"a":1})) == %{"a" => 1}
    end

    test "round-trips through the configured codec" do
      with_codec(JSONCodecStub, fn ->
        Application.put_env(:req_llm, :json_codec_stub_pid, self())
        on_exit(fn -> Application.delete_env(:req_llm, :json_codec_stub_pid) end)

        assert JSON.encode!(%{"a" => 1}) == ~s({"a":1})
        assert_received {:json_codec, :encode!, %{"a" => 1}}

        assert JSON.decode!(~s({"a":1})) == %{"a" => 1}
        assert_received {:json_codec, :decode!, ~s({"a":1})}
      end)
    end

    test "decode!/1 keeps raising Jason.DecodeError with the default codec" do
      Application.delete_env(:req_llm, :json_library)

      assert_raise Jason.DecodeError, fn -> JSON.decode!("{") end
    end

    test "decode!/1 raises a ReqLLM error for codecs without decode!/1" do
      with_codec(__MODULE__.NoBang, fn ->
        assert_raise ReqLLM.Error.Unknown.Unknown, fn -> JSON.decode!("}") end
      end)
    end
  end

  describe "decode_error_position/1" do
    test "reports the position of a Jason error" do
      {:error, error} = Jason.decode("{" <> String.duplicate(" ", 5))

      assert is_integer(JSON.decode_error_position(error))
    end

    test "uses the codec callback when it exports one" do
      with_codec(JSONCodecStub, fn ->
        {:error, error} = Jason.decode("{")

        assert JSON.decode_error_position(error) == 1
      end)
    end

    test "returns nil for unknown error shapes" do
      with_codec(__MODULE__.NoBang, fn ->
        assert JSON.decode_error_position(:bad_json) == nil
      end)
    end
  end

  describe "ordered objects" do
    test "Jason encodes them in order" do
      object = OrderedObject.new([{"b", 2}, {"a", 1}])

      assert Jason.encode!(object) == ~s({"b":2,"a":1})
    end

    test "the Elixir JSON module encodes them in order when available" do
      if Code.ensure_loaded?(JSON.Encoder) do
        object = OrderedObject.new([{"b", 2}, {"a", 1}])

        assert JSON.encode!(object) == ~s({"b":2,"a":1})
      end
    end

    test "request bodies keep property order with the default codec" do
      Application.delete_env(:req_llm, :json_library)

      body = %{
        "type" => "object",
        "properties" => %{
          "z" => %{"type" => "string"},
          "a" => %{"type" => "string"}
        },
        "propertyOrdering" => ["a", "z"]
      }

      encoded = body |> JSON.encode_request_body() |> IO.iodata_to_binary()

      assert encoded =~ ~s("properties":{"a":{"type":"string"},"z":{"type":"string"}})
      refute encoded =~ "propertyOrdering"
    end

    test "request bodies without ordering use the configured codec" do
      with_codec(JSONCodecStub, fn ->
        Application.put_env(:req_llm, :json_codec_stub_pid, self())
        on_exit(fn -> Application.delete_env(:req_llm, :json_codec_stub_pid) end)

        body = %{"a" => 1}
        assert IO.iodata_to_binary(JSON.encode_request_body(body)) == ~s({"a":1})
        assert_received {:json_codec, :encode_to_iodata!, %{"a" => 1}}
      end)
    end

    test "request bodies keep order through codecs that encode ordered objects" do
      with_codec(JSONCodecStub, fn ->
        Application.put_env(:req_llm, :json_codec_stub_pid, self())
        on_exit(fn -> Application.delete_env(:req_llm, :json_codec_stub_pid) end)

        body = %{
          "properties" => %{"b" => %{}, "a" => %{}},
          "propertyOrdering" => ["a", "b"]
        }

        encoded = body |> JSON.encode_request_body() |> IO.iodata_to_binary()

        assert encoded =~ ~s("properties":{"a":{},"b":{}})
        assert_received {:json_codec, :encode_to_iodata!, _body}
      end)
    end

    test "request bodies use the codec's ordered encoder when it exports one" do
      with_codec(__MODULE__.OrderedCodec, fn ->
        body = %{
          "properties" => %{"b" => %{}, "a" => %{}},
          "propertyOrdering" => ["a", "b"]
        }

        encoded = body |> JSON.encode_request_body() |> IO.iodata_to_binary()

        assert encoded =~ ~s("properties":{"a":{},"b":{}})
        assert Process.get(:ordered_codec_called) == true
      end)
    end

    test "to_jiffy_ordered/1 converts ordered objects recursively" do
      body = %{
        "properties" => OrderedObject.new([{"a", %{"type" => "string"}}]),
        "list" => [OrderedObject.new([{"b", 1}])]
      }

      assert JSON.to_jiffy_ordered(body) == %{
               "properties" => {[{"a", %{"type" => "string"}}]},
               "list" => [{[{"b", 1}]}]
             }
    end
  end

  describe "request_options/1" do
    test "returns a JSON body and custom decoders" do
      Application.delete_env(:req_llm, :json_library)

      options = JSON.request_options(%{"a" => 1})

      assert IO.iodata_to_binary(options[:body]) == ~s({"a":1})
      assert options[:headers] == [{"content-type", "application/json"}]
      assert Keyword.keys(options[:decoders]) == [:json, :json_api]
      assert options[:decoders][:json].(~s({"a":1})) == {:ok, %{"a" => 1}}
    end
  end

  defmodule Broken do
    def encode!(_term), do: "{}"
  end

  defmodule OrderedCodec do
    @behaviour ReqLLM.JSON.Codec

    def encode!(term), do: Jason.encode!(term)
    def encode_to_iodata!(term), do: Jason.encode_to_iodata!(term)
    def decode(json), do: Jason.decode(json)

    def encode_ordered_to_iodata!(term) do
      Process.put(:ordered_codec_called, true)
      Jason.encode_to_iodata!(term)
    end
  end

  defmodule NoBang do
    @behaviour ReqLLM.JSON.Codec

    def encode!(term), do: Jason.encode!(term)
    def encode_to_iodata!(term), do: Jason.encode_to_iodata!(term)
    def decode(json), do: Jason.decode(json)
  end
end
