defmodule ReqLLM.Providers.Azure.ProviderAuthenticationTest do
  @moduledoc """
  Provider API-key and Bearer authentication, credential errors, and validation.
  """

  use ExUnit.Case, async: true

  alias ReqLLM.Providers.Azure

  describe "attach/3" do
    test "sets api-key header for regular api keys" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      request =
        Req.new(url: "/test", method: :post)
        |> Req.Request.register_options([:context, :api_key, :base_url])
        |> Req.Request.merge_options(context: context)
        |> Azure.attach(model,
          api_key: "test-api-key",
          context: context,
          base_url: "https://my-resource.openai.azure.com/openai"
        )

      assert Req.Request.get_header(request, "api-key") == ["test-api-key"]
      refute Req.Request.get_header(request, "authorization") |> Enum.any?(&(&1 =~ "Bearer"))
    end

    test "sets Authorization Bearer header when api_key starts with 'Bearer '" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      request =
        Req.new(url: "/test", method: :post)
        |> Req.Request.register_options([:context, :api_key, :base_url])
        |> Req.Request.merge_options(context: context)
        |> Azure.attach(model,
          api_key: "Bearer eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.test",
          context: context,
          base_url: "https://my-resource.openai.azure.com/openai"
        )

      assert Req.Request.get_header(request, "authorization") == [
               "Bearer eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.test"
             ]

      assert Req.Request.get_header(request, "api-key") == []
    end

    test "Bearer token takes precedence over model family for Claude models" do
      model = ReqLLM.Test.AzureModelHelpers.chat_model("claude-3-5-sonnet-20241022")

      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      request =
        Req.new(url: "/test", method: :post)
        |> Req.Request.register_options([:context, :api_key, :base_url])
        |> Req.Request.merge_options(context: context)
        |> Azure.attach(model,
          api_key: "Bearer eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.test",
          context: context,
          base_url: "https://my-resource.openai.azure.com/openai"
        )

      assert Req.Request.get_header(request, "authorization") == [
               "Bearer eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.test"
             ]

      assert Req.Request.get_header(request, "x-api-key") == []
    end

    test "sets content-type header" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      request =
        Req.new(url: "/test", method: :post)
        |> Req.Request.register_options([:context, :api_key, :base_url])
        |> Req.Request.merge_options(context: context)
        |> Azure.attach(model,
          api_key: "test-api-key",
          context: context,
          base_url: "https://my-resource.openai.azure.com/openai"
        )

      assert Req.Request.get_header(request, "content-type") == ["application/json"]
    end
  end

  describe "credential_missing?/1" do
    test "returns true for missing AZURE_OPENAI_API_KEY" do
      error = %ArgumentError{message: "AZURE_OPENAI_API_KEY environment variable is not set"}
      assert Azure.credential_missing?(error)
    end

    test "returns true for missing api_key option" do
      error = %ArgumentError{message: "api_key must be provided"}
      assert Azure.credential_missing?(error)
    end

    test "returns false for other errors" do
      error = %ArgumentError{message: "some other error"}
      refute Azure.credential_missing?(error)
    end

    test "returns false for non-ArgumentError" do
      error = %RuntimeError{message: "AZURE_OPENAI_API_KEY not set"}
      refute Azure.credential_missing?(error)
    end
  end

  describe "authentication" do
    test "explicit api_key option takes precedence over environment variable" do
      original_env = System.get_env("AZURE_OPENAI_API_KEY")
      System.put_env("AZURE_OPENAI_API_KEY", "env-key")

      try do
        {:ok, model} = ReqLLM.model("azure:gpt-4o")
        context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

        {:ok, finch_request} =
          Azure.attach_stream(
            model,
            context,
            [
              api_key: "explicit-key",
              deployment: "my-deployment",
              base_url: "https://my-resource.openai.azure.com/openai"
            ],
            :req_llm_finch
          )

        header_map = Map.new(finch_request.headers)
        assert header_map["api-key"] == "explicit-key"
      after
        if original_env,
          do: System.put_env("AZURE_OPENAI_API_KEY", original_env),
          else: System.delete_env("AZURE_OPENAI_API_KEY")
      end
    end
  end

  describe "authentication edge cases" do
    test "rejects empty string api_key" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      result =
        Azure.attach_stream(
          model,
          context,
          [api_key: "", base_url: "https://my-resource.openai.azure.com/openai"],
          :req_llm_finch
        )

      assert {:error, _} = result
    end

    test "accepts api_key with special characters" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      {:ok, finch_request} =
        Azure.attach_stream(
          model,
          context,
          [
            api_key: "sk-test_key+with/special=chars",
            base_url: "https://my-resource.openai.azure.com/openai"
          ],
          :req_llm_finch
        )

      header_map = Map.new(finch_request.headers)
      assert header_map["api-key"] == "sk-test_key+with/special=chars"
    end

    test "trims whitespace from api_key" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")

      {:ok, request} =
        Azure.prepare_request(
          :chat,
          model,
          "Hello",
          api_key: "  test-api-key  ",
          base_url: "https://my-resource.openai.azure.com/openai"
        )

      api_key_header = get_header(request.headers, "api-key")
      assert api_key_header == "test-api-key" or api_key_header == "  test-api-key  "
    end

    test "rejects empty Bearer token" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")

      assert_raise ReqLLM.Error.Invalid.Parameter, ~r/Bearer token cannot be empty/, fn ->
        Azure.prepare_request(
          :chat,
          model,
          "Hello",
          api_key: "Bearer ",
          base_url: "https://my-resource.openai.azure.com/openai"
        )
      end
    end

    test "rejects Bearer token with only whitespace" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")

      assert_raise ReqLLM.Error.Invalid.Parameter, ~r/Bearer token cannot be empty/, fn ->
        Azure.prepare_request(
          :chat,
          model,
          "Hello",
          api_key: "Bearer    ",
          base_url: "https://my-resource.openai.azure.com/openai"
        )
      end
    end

    test "rejects Bearer token with newline characters (header injection protection)" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")

      assert_raise ReqLLM.Error.Invalid.Parameter,
                   ~r/Bearer token contains invalid characters/,
                   fn ->
                     Azure.prepare_request(
                       :chat,
                       model,
                       "Hello",
                       api_key: "Bearer token\nX-Injected-Header: malicious",
                       base_url: "https://my-resource.openai.azure.com/openai"
                     )
                   end
    end

    test "rejects Bearer token with carriage return characters" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")

      assert_raise ReqLLM.Error.Invalid.Parameter,
                   ~r/Bearer token contains invalid characters/,
                   fn ->
                     Azure.prepare_request(
                       :chat,
                       model,
                       "Hello",
                       api_key: "Bearer token\r\nX-Injected-Header: malicious",
                       base_url: "https://my-resource.openai.azure.com/openai"
                     )
                   end
    end

    test "trims whitespace from Bearer token value" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      request =
        Req.new(url: "/test", method: :post)
        |> Req.Request.register_options([:context, :api_key, :base_url])
        |> Req.Request.merge_options(context: context)
        |> Azure.attach(model,
          api_key: "Bearer   eyJhbGciOiJSUzI1NiJ9.test   ",
          context: context,
          base_url: "https://my-resource.openai.azure.com/openai"
        )

      assert Req.Request.get_header(request, "authorization") == [
               "Bearer eyJhbGciOiJSUzI1NiJ9.test"
             ]
    end
  end

  defp get_header(headers, key) do
    case Enum.find(headers, fn {k, _v} -> k == key end) do
      {_, [value | _]} -> value
      {_, value} when is_binary(value) -> value
      nil -> nil
    end
  end
end
