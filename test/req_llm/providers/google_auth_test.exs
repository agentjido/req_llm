defmodule ReqLLM.Providers.GoogleAuthTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Providers.Google

  @moduletag provider: :google

  for {operation, model_id, input, endpoint} <- [
        {:chat, "gemini-2.5-flash", "Hello", "generateContent"},
        {:object, "gemini-2.5-flash", "Hello", "generateContent"},
        {:embedding, "gemini-embedding-001", "Hello", "embedContent"},
        {:embedding, "gemini-embedding-001", ["Hello", "World"], "batchEmbedContents"},
        {:image, "gemini-2.5-flash-image", "A cat", "generateContent"},
        {:image, "imagen-4.0-generate-001", "A cat", "predict"}
      ],
      mode <- [:default, true, false] do
    test "#{operation} #{model_id} #{endpoint} authentication with #{mode}" do
      model_id = unquote(model_id)
      mode = unquote(mode)
      {:ok, schema} = ReqLLM.Schema.compile(name: [type: :string, required: true])

      opts = [
        api_key: "google-auth-secret",
        compiled_schema: schema,
        base_url: "https://proxy.example.com/v1beta",
        req_http_options: [headers: [{"x-custom-header", "preserved"}]]
      ]

      opts =
        if mode == :default,
          do: opts,
          else: Keyword.put(opts, :provider_options, google_auth_header: mode)

      assert {:ok, request} =
               Google.prepare_request(
                 unquote(operation),
                 "google:#{model_id}",
                 unquote(input),
                 opts
               )

      assert request.url.path == "/models/#{model_id}:#{unquote(endpoint)}"
      assert request.options[:base_url] == "https://proxy.example.com/v1beta"
      assert Req.Request.get_header(request, "x-custom-header") == ["preserved"]

      if mode == false do
        assert request.options[:params][:key] == "google-auth-secret"
        assert Req.Request.get_header(request, "x-goog-api-key") == []
      else
        refute Keyword.has_key?(request.options[:params] || [], :key)
        assert Req.Request.get_header(request, "x-goog-api-key") == ["google-auth-secret"]
      end
    end
  end
end
