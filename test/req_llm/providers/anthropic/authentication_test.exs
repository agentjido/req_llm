defmodule ReqLLM.Providers.Anthropic.AuthenticationTest do
  @moduledoc """
  Tests Anthropic API-key authentication and subscription OAuth request shaping.
  """

  use ReqLLM.ProviderCase, provider: ReqLLM.Providers.Anthropic, async: true

  alias ReqLLM.Providers.Anthropic

  describe "request preparation & pipeline wiring" do
    test "attach configures authentication and pipeline" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")
      opts = [temperature: 0.5, max_tokens: 50]

      request = Req.new() |> Anthropic.attach(model, opts)

      # Verify authentication
      api_key_header = Enum.find(request.headers, fn {name, _} -> name == "x-api-key" end)
      assert api_key_header != nil

      version_header = Enum.find(request.headers, fn {name, _} -> name == "anthropic-version" end)
      assert version_header != nil

      # Verify pipeline steps
      request_steps = Keyword.keys(request.request_steps)
      response_steps = Keyword.keys(request.response_steps)

      assert :llm_encode_body in request_steps
      assert :llm_decode_response in response_steps
    end

    test "attach custom api_key option" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")
      custom_key = "custom_api_key_123"

      request =
        Req.new()
        |> Anthropic.attach(model, api_key: custom_key)

      assert request.options.api_key == custom_key
    end

    test "attach supports oauth access_token auth" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")
      oauth_token = "oauth-anthropic-token-123"

      request =
        Req.new()
        |> Anthropic.attach(model,
          provider_options: [auth_mode: :oauth, access_token: oauth_token]
        )

      assert request.headers["authorization"] == ["Bearer #{oauth_token}"]
      refute Map.has_key?(request.headers, "x-api-key")
      refute Map.has_key?(request.headers, "user-agent")
      refute Map.has_key?(request.headers, "x-app")
      refute Map.has_key?(request.headers, "anthropic-beta")
      refute Map.has_key?(request.options, :params)
    end

    test "attach supports Claude subscription OAuth compatibility" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")
      oauth_token = "oauth-anthropic-token-123"

      request =
        Req.new()
        |> Anthropic.attach(model,
          provider_options: [
            auth_mode: :oauth,
            access_token: oauth_token,
            with_claude_subscription: true
          ]
        )

      assert request.headers["authorization"] == ["Bearer #{oauth_token}"]
      refute Map.has_key?(request.headers, "x-api-key")
      assert request.headers["user-agent"] == ["claude-cli/2.1.282 (external, cli)"]
      assert request.headers["x-app"] == ["claude-code"]

      assert request.headers["anthropic-beta"] == [
               "oauth-2025-04-20,interleaved-thinking-2025-05-14"
             ]

      assert request.options[:params][:beta] == "true"
    end

    test "encode_body shapes oauth requests for Claude subscription tokens" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      context =
        ReqLLM.Context.new([
          ReqLLM.Context.system("You are helpful."),
          ReqLLM.Context.user("Hello from oauth")
        ])

      request =
        Req.new()
        |> Req.Request.register_options([:context, :model])
        |> Req.Request.merge_options(context: context, model: model.model)
        |> Req.Request.put_private(:req_llm_claude_subscription?, true)

      updated_request = Anthropic.encode_body(request)
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      [billing_block, identity_block, original_system_block] = decoded["system"]

      assert String.starts_with?(
               billing_block["text"],
               "x-anthropic-billing-header: cc_version=2.1.282."
             )

      assert String.contains?(billing_block["text"], "cc_entrypoint=sdk-cli;")
      assert String.contains?(billing_block["text"], "cch=")
      refute Map.has_key?(billing_block, "cache_control")

      assert identity_block["text"] ==
               "You are a Claude agent, built on Anthropic's Claude Agent SDK."

      assert original_system_block["text"] == "You are helpful."
    end

    test "attach combines Claude subscription and manual beta headers" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      request =
        Req.new()
        |> Anthropic.attach(model,
          anthropic_beta: ["top-level-beta"],
          provider_options: [
            auth_mode: :oauth,
            access_token: "oauth-anthropic-token-123",
            with_claude_subscription: true,
            anthropic_beta: ["provider-beta", "interleaved-thinking-2025-05-14"]
          ]
        )

      features = req_beta_features(request)

      assert "top-level-beta" in features
      assert "provider-beta" in features
      assert "oauth-2025-04-20" in features
      assert "interleaved-thinking-2025-05-14" in features
      assert Enum.count(features, &(&1 == "interleaved-thinking-2025-05-14")) == 1
    end

    test "prepare_request applies Claude subscription OAuth shaping end to end" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      context =
        ReqLLM.Context.new([
          ReqLLM.Context.system("You are helpful."),
          ReqLLM.Context.user("Hello from prepared oauth")
        ])

      {:ok, request} =
        Anthropic.prepare_request(:chat, model, context,
          with_claude_subscription: true,
          anthropic_beta: ["top-level-beta"],
          provider_options: [
            auth_mode: :oauth,
            access_token: "oauth-prepared-token"
          ],
          max_tokens: 64
        )

      assert request.headers["authorization"] == ["Bearer oauth-prepared-token"]
      refute Map.has_key?(request.headers, "x-api-key")
      assert request.headers["user-agent"] == ["claude-cli/2.1.282 (external, cli)"]
      assert request.headers["x-app"] == ["claude-code"]
      assert request.options[:params][:beta] == "true"

      features = req_beta_features(request)

      assert "top-level-beta" in features
      assert "oauth-2025-04-20" in features
      assert "interleaved-thinking-2025-05-14" in features

      decoded = request |> Anthropic.encode_body() |> ReqLLM.Test.Helpers.json_body()

      assert decoded["model"] == "claude-sonnet-4-5-20250929"
      assert decoded["max_tokens"] == 64

      [billing_block, identity_block, original_system_block] = decoded["system"]

      assert String.starts_with?(
               billing_block["text"],
               "x-anthropic-billing-header: cc_version=2.1.282."
             )

      assert identity_block["text"] ==
               "You are a Claude agent, built on Anthropic's Claude Agent SDK."

      assert original_system_block["text"] == "You are helpful."
    end

    test "attach_stream shapes oauth requests" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      context =
        ReqLLM.Context.new([
          ReqLLM.Context.system("You are helpful."),
          ReqLLM.Context.user("Hello from streaming oauth")
        ])

      {:ok, finch_request} =
        Anthropic.attach_stream(
          model,
          context,
          [
            anthropic_beta: ["stream-top-level-beta"],
            provider_options: [
              auth_mode: :oauth,
              access_token: "oauth-stream-token",
              with_claude_subscription: true
            ]
          ],
          nil
        )

      headers = Map.new(finch_request.headers)
      decoded = Jason.decode!(finch_request.body)
      query = URI.decode_query(finch_request.query)

      assert headers["authorization"] == "Bearer oauth-stream-token"
      refute Map.has_key?(headers, "x-api-key")
      assert headers["user-agent"] == "claude-cli/2.1.282 (external, cli)"
      assert headers["x-app"] == "claude-code"
      assert query["beta"] == "true"

      features = beta_features(headers["anthropic-beta"])

      assert "stream-top-level-beta" in features
      assert "oauth-2025-04-20" in features
      assert "interleaved-thinking-2025-05-14" in features

      assert String.starts_with?(
               List.first(decoded["system"])["text"],
               "x-anthropic-billing-header:"
             )
    end
  end

  defp req_beta_features(%Req.Request{} = request) do
    request.headers["anthropic-beta"]
    |> List.first()
    |> beta_features()
  end

  defp beta_features(header) when is_binary(header), do: String.split(header, ",")
end
