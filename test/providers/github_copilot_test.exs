defmodule ReqLLM.Providers.GitHubCopilotTest do
  use ReqLLM.ProviderCase, provider: ReqLLM.Providers.GitHubCopilot

  alias ReqLLM.Providers.GitHubCopilot

  import ExUnit.CaptureIO

  describe "provider contract" do
    test "provider identity and configuration" do
      assert GitHubCopilot.provider_id() == :github_copilot
      assert GitHubCopilot.base_url() == "https://api.githubcopilot.com"
      assert GitHubCopilot.default_env_key() == "COPILOT_GITHUB_TOKEN"
      assert GitHubCopilot.display_name() == "GitHub Copilot"
    end

    test "provider schema separation from core options" do
      schema_keys = GitHubCopilot.provider_schema().schema |> Keyword.keys()
      core_keys = ReqLLM.Provider.Options.generation_schema().schema |> Keyword.keys()

      overlap = MapSet.intersection(MapSet.new(schema_keys), MapSet.new(core_keys))

      assert MapSet.size(overlap) == 0,
             "Schema overlap detected: #{inspect(MapSet.to_list(overlap))}"
    end

    test "model string fallback resolves Copilot models without catalog warnings" do
      test_pid = self()

      warning =
        capture_io(:stderr, fn ->
          send(test_pid, {:model_result, ReqLLM.model("github_copilot:gpt-4o-mini")})
        end)

      assert_received {:model_result,
                       {:ok, %LLMDB.Model{provider: :github_copilot, id: "gpt-4o-mini"}}}

      assert warning == ""
    end
  end

  describe "authentication" do
    test "resolves explicit api_key before environment tokens" do
      assert {:ok, "explicit-token", :api_key} =
               GitHubCopilot.resolve_token(api_key: "explicit-token")
    end

    test "resolves GH_TOKEN when Copilot token is absent" do
      with_env("COPILOT_GITHUB_TOKEN", nil, fn ->
        with_env("GH_TOKEN", "gh-token", fn ->
          assert {:ok, "gh-token", :gh_token} =
                   GitHubCopilot.resolve_token(github_copilot_auth: :token)
        end)
      end)
    end

    test "token-only mode reports configured credential sources" do
      with_env("COPILOT_GITHUB_TOKEN", nil, fn ->
        with_env("GH_TOKEN", nil, fn ->
          with_env("GITHUB_TOKEN", nil, fn ->
            assert {:error, message} =
                     GitHubCopilot.resolve_token(github_copilot_auth: :token)

            assert message =~ "COPILOT_GITHUB_TOKEN"
            assert message =~ "GH_TOKEN"
            assert message =~ "GITHUB_TOKEN"
          end)
        end)
      end)
    end
  end

  describe "request preparation and streaming" do
    test "prepare_request creates a Chat Completions request with Copilot headers" do
      model = ReqLLM.model!(%{provider: :github_copilot, id: "gpt-4o-mini"})

      {:ok, request} =
        GitHubCopilot.prepare_request(:chat, model, "Hello",
          api_key: "test-token",
          provider_options: [github_copilot_integration_id: "req-llm-test"]
        )

      assert %Req.Request{} = request
      assert request.url.path == "/chat/completions"
      assert request.method == :post
      assert request.options[:auth] == {:bearer, "test-token"}
      assert request.options[:model] == "gpt-4o-mini"
      assert header_value(request.headers, "authorization") == "Bearer test-token"
      assert header_value(request.headers, "copilot-integration-id") == "req-llm-test"
    end

    test "attach_stream builds an OpenAI-compatible Copilot streaming request" do
      model = ReqLLM.model!(%{provider: :github_copilot, id: "gpt-4o-mini"})
      context = context_fixture()

      {:ok, request} =
        GitHubCopilot.attach_stream(
          model,
          context,
          [
            api_key: "test-token",
            max_tokens: 40,
            github_copilot_integration_id: "req-llm-stream-test"
          ],
          nil
        )

      assert request.method == "POST"
      assert request.path == "/chat/completions"
      assert request.host == "api.githubcopilot.com"
      assert {"Authorization", "Bearer test-token"} in request.headers
      assert {"Copilot-Integration-Id", "req-llm-stream-test"} in request.headers
      assert {"Accept", "text/event-stream"} in request.headers

      body = ReqLLM.Test.Helpers.json_body(request)
      assert body["model"] == "gpt-4o-mini"
      assert body["stream"] == true
      assert body["stream_options"] == %{"include_usage" => true}
      assert body["max_tokens"] == 40
    end

    test "build_body translates forced tool choice to OpenAI function shape" do
      model = ReqLLM.model!(%{provider: :github_copilot, id: "gpt-4o-mini"})

      tool =
        ReqLLM.tool(
          name: "add",
          description: "Add two integers",
          parameter_schema: [
            a: [type: :integer, required: true],
            b: [type: :integer, required: true]
          ],
          callback: fn _args -> {:ok, 5} end
        )

      {:ok, request} =
        GitHubCopilot.prepare_request(:chat, model, "Use add for 2 + 3",
          api_key: "test-token",
          tools: [tool],
          tool_choice: %{type: "tool", name: "add"}
        )

      body = GitHubCopilot.build_body(request)

      assert body[:tool_choice] == %{type: "function", function: %{name: "add"}}
    end

    test "custom base_url is preserved for Copilot-compatible deployments" do
      model =
        ReqLLM.model!(%{
          provider: :github_copilot,
          id: "gpt-4o-mini",
          base_url: "https://api.individual.githubcopilot.com"
        })

      {:ok, request} =
        GitHubCopilot.attach_stream(model, context_fixture(), [api_key: "test-token"], nil)

      assert request.host == "api.individual.githubcopilot.com"
    end
  end

  defp header_value(headers, name) do
    {_, value} =
      Enum.find(headers, fn {header_name, _value} ->
        String.downcase(header_name) == name
      end)

    case value do
      [single] -> single
      other -> other
    end
  end

  defp with_env(key, value, fun) do
    old_value = System.get_env(key)

    if is_nil(value) do
      System.delete_env(key)
    else
      System.put_env(key, value)
    end

    try do
      fun.()
    after
      if is_nil(old_value) do
        System.delete_env(key)
      else
        System.put_env(key, old_value)
      end
    end
  end
end
