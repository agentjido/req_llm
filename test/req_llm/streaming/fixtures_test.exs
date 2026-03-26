defmodule ReqLLM.Streaming.FixturesTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Streaming.Fixtures
  alias ReqLLM.Streaming.Fixtures.HTTPContext

  describe "HTTPContext.from_finch_request/1" do
    test "omits default ports and preserves non-default ports" do
      default_https = Finch.build(:get, "https://api.example.com/v1/chat")
      custom_https = Finch.build(:get, "https://api.example.com:8443/v1/chat")
      default_http = Finch.build(:get, "http://api.example.com/v1/chat")
      custom_http = Finch.build(:get, "http://api.example.com:8080/v1/chat")

      assert HTTPContext.from_finch_request(default_https).url ==
               "https://api.example.com/v1/chat"

      assert HTTPContext.from_finch_request(custom_https).url ==
               "https://api.example.com:8443/v1/chat"

      assert HTTPContext.from_finch_request(default_http).url == "http://api.example.com/v1/chat"

      assert HTTPContext.from_finch_request(custom_http).url ==
               "http://api.example.com:8080/v1/chat"
    end

    test "normalizes binary, atom, and unknown methods" do
      assert HTTPContext.from_finch_request(
               Finch.build(:get, "https://api.example.com")
               |> Map.put(:method, "PUT")
             ).method ==
               :put

      assert HTTPContext.from_finch_request(
               Finch.build(:get, "https://api.example.com")
               |> Map.put(:method, "PATCH")
             ).method ==
               :patch

      assert HTTPContext.from_finch_request(
               Finch.build(:get, "https://api.example.com")
               |> Map.put(:method, "DELETE")
             ).method ==
               :delete

      assert HTTPContext.from_finch_request(
               Finch.build(:get, "https://api.example.com")
               |> Map.put(:method, "HEAD")
             ).method ==
               :head

      assert HTTPContext.from_finch_request(
               Finch.build(:get, "https://api.example.com")
               |> Map.put(:method, "OPTIONS")
             ).method ==
               :options

      assert HTTPContext.from_finch_request(
               Finch.build(:get, "https://api.example.com")
               |> Map.put(:method, :post)
             ).method ==
               :post

      assert HTTPContext.from_finch_request(
               Finch.build(:get, "https://api.example.com")
               |> Map.put(:method, 123)
             ).method ==
               :unknown
    end

    test "passes through unsupported header shapes unchanged" do
      context = HTTPContext.new("https://api.example.com", :post, :invalid_headers)
      assert context.req_headers == :invalid_headers
    end
  end

  describe "canonical_json_from_finch_request/1" do
    test "handles nil, invalid JSON, streaming, and unknown bodies" do
      assert Fixtures.canonical_json_from_finch_request(
               Finch.build(:post, "https://api.example.com")
               |> Map.put(:body, nil)
             ) ==
               %{}

      assert Fixtures.canonical_json_from_finch_request(
               Finch.build(:post, "https://api.example.com")
               |> Map.put(:body, "{\"oops\"")
             ) == %{
               raw_body: "{\"oops\""
             }

      assert Fixtures.canonical_json_from_finch_request(
               Finch.build(:post, "https://api.example.com")
               |> Map.put(:body, {:stream, Stream.iterate(0, &(&1 + 1))})
             ) == %{streaming_body: true}

      assert Fixtures.canonical_json_from_finch_request(
               Finch.build(:post, "https://api.example.com")
               |> Map.put(:body, %{unexpected: true})
             ) ==
               %{unknown_body: "%{unexpected: true}"}
    end
  end
end
