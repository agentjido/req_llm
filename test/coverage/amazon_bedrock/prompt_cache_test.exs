defmodule ReqLLM.Coverage.AmazonBedrock.PromptCacheTest do
  @moduledoc """
  Record with REQ_LLM_FIXTURES_MODE=record and AWS_REGION=us-east-1.
  """
  use ExUnit.Case, async: false

  import ReqLLM.Test.Helpers

  alias ReqLLM.Context
  alias ReqLLM.Message.ContentPart

  @moduletag :coverage
  @moduletag provider: "amazon_bedrock"
  @moduletag timeout: 180_000

  @claude "amazon_bedrock:global.anthropic.claude-haiku-4-5-20251001-v1:0"
  @nova %{provider: :amazon_bedrock, id: "us.amazon.nova-pro-v1:0"}
  @padding String.duplicate("Stable reference sentence for the prompt cache fixture. ", 450)

  setup_all do
    LLMDB.load(allow: :all, custom: %{})
    :ok
  end

  test "explicit cache_control checkpoint on Converse" do
    context =
      Context.new([
        Context.system([
          ContentPart.text("Answer in two words.\n" <> @padding, %{
            cache_control: %{type: "ephemeral"}
          }),
          ContentPart.text("Today is a test day.")
        ]),
        Context.user("Say hi.")
      ])

    {:ok, response} =
      ReqLLM.generate_text(
        @claude,
        context,
        fixture_opts("prompt_cache_explicit",
          max_tokens: 32,
          temperature: 0.0,
          provider_options: [use_converse: true]
        )
      )

    assert response.usage.cache_creation_tokens > 0 or response.usage.cached_tokens > 0
    assert is_list(response.provider_meta.cache_details)
  end

  test "1h checkpoints on Converse" do
    context =
      Context.new([Context.system("Answer in two words.\n" <> @padding), Context.user("Say hi.")])

    {:ok, response} =
      ReqLLM.generate_text(
        @claude,
        context,
        fixture_opts("prompt_cache_1h",
          max_tokens: 32,
          temperature: 0.0,
          provider_options: [use_converse: true, prompt_cache: true, prompt_cache_ttl: "1h"]
        )
      )

    assert response.usage.cache_creation_tokens > 0 or response.usage.cached_tokens > 0
    assert [%{"ttl" => "1h"} | _] = response.provider_meta.cache_details
  end

  test "streaming Converse reports cache usage" do
    context =
      Context.new([Context.system("Answer in two words.\n" <> @padding), Context.user("Say hi.")])

    {:ok, response} =
      ReqLLM.stream_text(
        @claude,
        context,
        fixture_opts("prompt_cache_streaming",
          max_tokens: 32,
          temperature: 0.0,
          provider_options: [use_converse: true, prompt_cache: true]
        )
      )

    {:ok, response} = ReqLLM.StreamResponse.to_response(response)

    assert ReqLLM.Response.text(response) =~ ~r/\S/
    assert response.usage.cache_creation_tokens > 0 or response.usage.cached_tokens > 0
    assert response.usage.input_includes_cached == false
  end

  test "Nova with tools skips the tools checkpoint" do
    context =
      Context.new([Context.system("Answer briefly.\n" <> @padding), Context.user("Say hi.")])

    tool =
      ReqLLM.tool(
        name: "ping",
        description: "Ping",
        parameter_schema: [],
        callback: fn _ -> {:ok, "pong"} end
      )

    {:ok, response} =
      ReqLLM.generate_text(
        @nova,
        context,
        fixture_opts("prompt_cache_tools",
          max_tokens: 32,
          temperature: 0.0,
          tools: [tool],
          provider_options: [prompt_cache: true, cache_messages: true]
        )
      )

    assert response.usage.cache_creation_tokens > 0 or response.usage.cached_tokens > 0
  end
end
