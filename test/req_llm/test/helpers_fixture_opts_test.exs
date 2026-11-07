defmodule ReqLLM.Test.HelpersFixtureOptsTest do
  use ExUnit.Case, async: false

  alias ReqLLM.Test.Env
  alias ReqLLM.Test.Helpers

  setup do
    Env.isolate!(["REQ_LLM_FIXTURES_MODE"])
  end

  describe "fixture_opts/3 for :google_vertex" do
    test "adds a fixed project ID and a dummy access token in replay mode" do
      System.put_env("REQ_LLM_FIXTURES_MODE", "replay")

      opts = Helpers.fixture_opts(:google_vertex, "basic", max_tokens: 50)

      assert opts[:fixture] == "basic"
      assert opts[:max_tokens] == 50
      assert opts[:provider_options][:project_id] == "req-llm-fixture-project"
      assert opts[:provider_options][:access_token] == "req-llm-fixture-access-token"
    end

    test "keeps the provider options of the caller in replay mode" do
      System.put_env("REQ_LLM_FIXTURES_MODE", "replay")

      opts =
        Helpers.fixture_opts(:google_vertex, "labels_basic",
          provider_options: [labels: %{"team" => "engineering"}, project_id: "caller-project"]
        )

      assert opts[:provider_options][:labels] == %{"team" => "engineering"}
      assert opts[:provider_options][:project_id] == "caller-project"
      assert opts[:provider_options][:access_token] == "req-llm-fixture-access-token"
    end

    test "adds no credentials in record mode" do
      System.put_env("REQ_LLM_FIXTURES_MODE", "record")

      opts = Helpers.fixture_opts(:google_vertex, "basic", max_tokens: 50)

      assert opts[:fixture] == "basic"
      refute Keyword.has_key?(opts, :provider_options)
    end
  end

  test "fixture_opts/3 adds no Vertex credentials for other providers" do
    System.put_env("REQ_LLM_FIXTURES_MODE", "replay")

    opts = Helpers.fixture_opts(:openai, "basic", max_tokens: 50)

    assert opts[:fixture] == "basic"
    refute Keyword.has_key?(opts, :provider_options)
  end
end
