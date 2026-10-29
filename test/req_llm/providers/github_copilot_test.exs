defmodule ReqLLM.Providers.GitHubCopilotTest do
  use ReqLLM.ProviderCase, provider: ReqLLM.Providers.GitHubCopilot

  alias ReqLLM.Providers.GitHubCopilot

  import ExUnit.CaptureIO

  describe "provider contract" do
    test "provider schema defaults authentication to token-only mode" do
      assert GitHubCopilot.provider_schema().schema[:github_copilot_auth][:default] == :token
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
    @describetag :tmp_dir

    setup %{tmp_dir: tmp_dir} do
      env_keys = ["COPILOT_GITHUB_TOKEN", "GH_TOKEN", "GITHUB_TOKEN", "PATH"]
      original_env = Map.new(env_keys, &{&1, System.get_env(&1)})
      original_config = Application.fetch_env(:req_llm, :github_copilot_api_key)

      on_exit(fn ->
        Enum.each(original_env, fn
          {key, nil} -> System.delete_env(key)
          {key, value} -> System.put_env(key, value)
        end)

        case original_config do
          {:ok, value} -> Application.put_env(:req_llm, :github_copilot_api_key, value)
          :error -> Application.delete_env(:req_llm, :github_copilot_api_key)
        end
      end)

      Enum.each(env_keys, &System.delete_env/1)
      Application.delete_env(:req_llm, :github_copilot_api_key)
      System.put_env("PATH", tmp_dir)

      gh_path = Path.join(tmp_dir, "gh")

      File.write!(gh_path, """
      #!/bin/sh
      printf '%s\\n' "$*" > "$0.called"
      printf '  cli-token \\n'
      """)

      File.chmod!(gh_path, 0o700)

      {:ok, gh_path: gh_path}
    end

    test "resolves explicit api_key before environment tokens" do
      System.put_env("COPILOT_GITHUB_TOKEN", "environment-token")

      assert {:ok, "explicit-token", :api_key} =
               GitHubCopilot.resolve_token(api_key: "explicit-token")
    end

    test "resolves GH_TOKEN when Copilot token is absent" do
      System.put_env("GH_TOKEN", "gh-token")

      assert {:ok, "gh-token", :gh_token} =
               GitHubCopilot.resolve_token(github_copilot_auth: :token)
    end

    test "default mode returns an error without running gh", %{gh_path: gh_path} do
      assert {:error, message} = GitHubCopilot.resolve_token([])
      assert message =~ "Set :api_key"
      refute File.exists?(gh_path <> ".called")
    end

    test "token-only mode reports credential sources and CLI opt-in", %{gh_path: gh_path} do
      assert {:error, message} = GitHubCopilot.resolve_token(github_copilot_auth: :token)

      assert message =~ ":api_key"
      assert message =~ "config :req_llm, :github_copilot_api_key"
      assert message =~ "COPILOT_GITHUB_TOKEN"
      assert message =~ "GH_TOKEN"
      assert message =~ "GITHUB_TOKEN"
      assert message =~ "github_copilot_auth: :auto"
      assert message =~ ":gh"
      refute File.exists?(gh_path <> ".called")
    end

    test "auto mode falls back to gh auth token", %{gh_path: gh_path} do
      assert {:ok, "cli-token", :gh_cli} = GitHubCopilot.resolve_token(github_copilot_auth: :auto)
      assert File.read!(gh_path <> ".called") == "auth token\n"
    end

    test "auto mode prefers configured tokens over gh", %{gh_path: gh_path} do
      System.put_env("COPILOT_GITHUB_TOKEN", "environment-token")

      assert {:ok, "environment-token", :copilot_github_token} =
               GitHubCopilot.resolve_token(github_copilot_auth: :auto)

      refute File.exists?(gh_path <> ".called")
    end

    test "gh mode uses the CLI even when a token is configured" do
      assert {:ok, "cli-token", :gh_cli} =
               GitHubCopilot.resolve_token(api_key: "explicit-token", github_copilot_auth: :gh)
    end

    test "nested and string auth options allow explicit CLI opt-in" do
      for opts <- [
            [provider_options: [github_copilot_auth: :auto]],
            [provider_options: %{"github_copilot_auth" => "auto"}],
            [github_copilot_auth: "gh"]
          ] do
        assert {:ok, "cli-token", :gh_cli} = GitHubCopilot.resolve_token(opts)
      end
    end

    test "unrecognized auth modes use token-only mode", %{gh_path: gh_path} do
      assert {:error, message} = GitHubCopilot.resolve_token(github_copilot_auth: :unknown)
      assert message =~ "Set :api_key"
      refute File.exists?(gh_path <> ".called")
    end

    test "CLI opt-in reports an unavailable executable when gh is absent", %{gh_path: gh_path} do
      File.rm!(gh_path)
      assert System.find_executable("gh") == nil

      for mode <- [:auto, :gh] do
        assert {:error, message} = GitHubCopilot.resolve_token(github_copilot_auth: mode)
        assert message =~ "the `gh` executable is unavailable"
      end
    end

    test "CLI opt-in reports an empty token", %{gh_path: gh_path} do
      File.write!(gh_path, "#!/bin/sh\nprintf ' \\n'\n")

      assert {:error, "`gh auth token` returned an empty token"} =
               GitHubCopilot.resolve_token(github_copilot_auth: :auto)
    end

    test "CLI opt-in reports command failures", %{gh_path: gh_path} do
      File.write!(gh_path, "#!/bin/sh\nprintf 'not logged in\\n' >&2\nexit 1\n")

      assert {:error, message} = GitHubCopilot.resolve_token(github_copilot_auth: :auto)
      assert message =~ "`gh auth token` failed: not logged in"
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
end
