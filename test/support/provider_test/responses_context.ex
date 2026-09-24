defmodule ReqLLM.ProviderTest.ResponsesContext do
  @moduledoc """
  Responses API reasoning-summary, reasoning-context and compaction coverage.

  Shared by the OpenAI and Azure OpenAI coverage suites. The model defaults to
  the provider's `gpt-5.4` entry and can be overridden with
  `REQ_LLM_RESPONSES_MODEL` (a bare model id) when recording against another
  deployment.
  """

  defmacro __using__(opts) do
    provider = Keyword.fetch!(opts, :provider)

    quote bind_quoted: [provider: provider] do
      use ExUnit.Case, async: false

      import ReqLLM.Test.Helpers

      alias ReqLLM.Context
      alias ReqLLM.Message.ContentPart
      alias ReqLLM.ProviderTest.ResponsesContext
      alias ReqLLM.Response
      alias ReqLLM.Test.CompatibilityScenario

      @moduletag :coverage
      @moduletag provider: to_string(provider)
      @moduletag timeout: 240_000

      @provider provider
      @model_id ResponsesContext.model_id()
      @model_spec "#{provider}:#{@model_id}"

      setup_all do
        LLMDB.load(allow: :all, custom: Application.get_env(:llm_db, :custom, %{}))
        :ok
      end

      @tag CompatibilityScenario.tag!(:reasoning_summary)
      @tag model: @model_id
      test "reasoning summaries are requested and decoded" do
        {:ok, response} =
          ReqLLM.generate_text(
            @model_spec,
            ResponsesContext.reasoning_prompt(),
            ResponsesContext.opts(@provider, :reasoning_summary, 0,
              provider_options: [reasoning_summary: :auto, store: false]
            )
          )

        assert Response.text(response) != ""
        assert response.provider_meta["reasoning"]["summary"] in ["auto", "concise", "detailed"]
        assert [%ReqLLM.Message.ReasoningDetails{} | _] = response.message.reasoning_details

        ResponsesContext.assert_summary_parts(response)
      end

      @tag CompatibilityScenario.tag!(:reasoning_summary)
      @tag model: @model_id
      test "reasoning summaries stream as thinking chunks with part boundaries" do
        {:ok, stream_response} =
          ReqLLM.stream_text(
            @model_spec,
            ResponsesContext.reasoning_prompt(),
            ResponsesContext.opts(@provider, :reasoning_summary, 1,
              stream: true,
              provider_options: [reasoning_summary: :auto, store: false]
            )
          )

        chunks = Enum.to_list(stream_response.stream)
        thinking = Enum.filter(chunks, &(&1.type == :thinking))
        boundaries = Enum.filter(chunks, &match?(%{metadata: %{reasoning_summary_part: _}}, &1))

        {:ok, response} = ReqLLM.StreamResponse.to_response(%{stream_response | stream: chunks})
        assert Response.text(response) != ""

        if thinking != [] do
          assert Enum.all?(thinking, &is_integer(&1.metadata[:summary_index]))
          assert Enum.all?(thinking, &is_binary(&1.metadata[:item_id]))
          assert Enum.any?(boundaries, &(&1.metadata.reasoning_summary_part.status == :done))
          assert Response.thinking(response) != ""
        end
      end

      @tag CompatibilityScenario.tag!(:reasoning_context)
      @tag model: @model_id
      test "reasoning context is honored across replayed turns" do
        {:ok, first} =
          ReqLLM.generate_text(
            @model_spec,
            "Pick a two-digit prime and explain in one sentence why it is prime.",
            ResponsesContext.opts(@provider, :reasoning_context, 0,
              provider_options: [reasoning_context: :current_turn, store: false]
            )
          )

        assert first.provider_meta["reasoning"]["context"] == "current_turn"

        follow_up =
          Context.append(
            first.context,
            Context.user("Now double it and reply with the number only.")
          )

        {:ok, second} =
          ReqLLM.generate_text(
            @model_spec,
            follow_up,
            ResponsesContext.opts(@provider, :reasoning_context, 1,
              provider_options: [reasoning_context: :all_turns, store: false]
            )
          )

        assert Response.text(second) != ""
        assert second.provider_meta["reasoning"]["context"] == "all_turns"
      end

      @tag CompatibilityScenario.tag!(:compaction_manual)
      @tag model: @model_id
      test "compacts a replayed context and continues from the compaction item" do
        {:ok, first} =
          ReqLLM.generate_text(
            @model_spec,
            "Create a simple landing page for a dog cafe. Keep it under 200 words.",
            ResponsesContext.opts(@provider, :compaction_manual, 0,
              provider_options: [store: false]
            )
          )

        assert Response.text(first) != ""

        {:ok, compacted} =
          ReqLLM.compact_context(
            @model_spec,
            first.context,
            ResponsesContext.opts(@provider, :compaction_manual, 1, [])
          )

        ResponsesContext.assert_compacted(compacted)

        next =
          Context.append(compacted.context, Context.user("Add a booking form. Reply briefly."))

        {:ok, follow_up} =
          ReqLLM.generate_text(
            @model_spec,
            next,
            ResponsesContext.opts(@provider, :compaction_manual, 2,
              provider_options: [store: false]
            )
          )

        assert Response.text(follow_up) != ""
      end

      @tag CompatibilityScenario.tag!(:compaction_previous_response)
      @tag model: @model_id
      test "compacts a stored response by id" do
        {:ok, first} =
          ReqLLM.generate_text(
            @model_spec,
            "What is the approximate land area of France? One sentence.",
            ResponsesContext.opts(@provider, :compaction_previous_response, 0, [])
          )

        assert is_binary(first.id) and first.id != ""

        {:ok, compacted} =
          ReqLLM.compact_context(
            @model_spec,
            nil,
            ResponsesContext.opts(@provider, :compaction_previous_response, 1,
              previous_response_id: first.id
            )
          )

        ResponsesContext.assert_compacted(compacted)
      end

      @tag CompatibilityScenario.tag!(:compaction_server_side)
      @tag model: @model_id
      test "server-side compaction is accepted on ordinary requests" do
        {:ok, response} =
          ReqLLM.generate_text(
            @model_spec,
            ResponsesContext.long_prompt(),
            ResponsesContext.opts(@provider, :compaction_server_side, 0,
              provider_options: [
                store: false,
                context_management: [%{type: "compaction", compact_threshold: 1000}]
              ]
            )
          )

        assert Response.text(response) != ""
        ResponsesContext.assert_compaction_blocks_replayable(response)
      end

      @tag CompatibilityScenario.tag!(:compaction_server_side)
      @tag model: @model_id
      test "server-side compaction is accepted on streaming requests" do
        {:ok, stream_response} =
          ReqLLM.stream_text(
            @model_spec,
            ResponsesContext.long_prompt(),
            ResponsesContext.opts(@provider, :compaction_server_side, 1,
              stream: true,
              provider_options: [
                store: false,
                context_management: [%{type: "compaction", compact_threshold: 1000}]
              ]
            )
          )

        chunks = Enum.to_list(stream_response.stream)
        {:ok, response} = ReqLLM.StreamResponse.to_response(%{stream_response | stream: chunks})

        assert Response.text(response) != ""
        ResponsesContext.assert_compaction_blocks_replayable(response)

        Enum.each(chunks, fn
          %{type: :content_part, content_part: %ContentPart{type: :provider_block} = part} ->
            assert ReqLLM.Compaction.compaction_part?(part)

          _chunk ->
            :ok
        end)
      end
    end
  end

  import ExUnit.Assertions

  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Response

  @azure_fixture_base_url "https://fixture.openai.azure.com/openai/v1"

  @doc false
  def model_id, do: System.get_env("REQ_LLM_RESPONSES_MODEL") || "gpt-5.4"

  @doc false
  def reasoning_prompt do
    "Three friends split a 47 euro bill so that Ana pays twice what Ben pays and Cleo pays 5 euros more than Ben. How much does each pay? Show the amounts."
  end

  @doc false
  def long_prompt do
    "Summarize the following notes in three sentences. " <>
      String.duplicate(
        "The kitchen team reviewed the weekly menu, adjusted supplier orders, and planned staff shifts. ",
        40
      )
  end

  @doc false
  def opts(provider, scenario, index, extra) do
    common = [
      reasoning_effort: :low,
      max_tokens: 1_024,
      max_retries: 0,
      receive_timeout: 120_000
    ]

    merged =
      common
      |> Keyword.merge(provider_opts(provider))
      |> Keyword.merge(extra)

    ReqLLM.Test.Helpers.fixture_opts(
      ReqLLM.Test.CompatibilityScenario.fixture!(scenario, index),
      merged
    )
  end

  @doc false
  def provider_opts(:azure) do
    opts =
      case ReqLLM.Test.Env.fixtures_mode() do
        :record -> []
        :replay -> [api_key: "fixture-api-key", base_url: @azure_fixture_base_url]
      end

    case System.get_env("AZURE_RESPONSES_DEPLOYMENT") do
      nil -> opts
      deployment -> Keyword.put(opts, :deployment, deployment)
    end
  end

  def provider_opts(_provider), do: []

  @doc false
  def assert_summary_parts(%Response{} = response) do
    details = response.message.reasoning_details || []
    summaries = Enum.flat_map(details, &List.wrap(&1.provider_data["summary"]))

    if summaries != [] do
      assert Enum.all?(summaries, &(&1["type"] == "summary_text" and is_binary(&1["text"])))
      assert Response.thinking(response) != ""
    end
  end

  @doc false
  def assert_compacted(%Response{} = response) do
    assert [message] = response.context.messages
    assert message.role == :assistant
    assert ReqLLM.Compaction.compaction_message?(message)
    assert Enum.all?(message.content, &ReqLLM.Compaction.compaction_part?/1)
    assert message.tool_calls in [nil, []]
    assert message.reasoning_details in [nil, []]
    refute Map.has_key?(message.metadata, :response_id)
    refute Map.has_key?(message.metadata, :phase)
    assert is_binary(message.metadata[:compaction_response_id])

    assert Enum.any?(Response.provider_items(response), fn
             %ContentPart{type: :provider_block, data: %{"type" => "compaction"} = block} ->
               is_binary(block["encrypted_content"])

             _ ->
               false
           end)
  end

  @doc false
  def assert_compaction_blocks_replayable(%Response{} = response) do
    Enum.each(response.message.content, fn
      %ContentPart{type: :provider_block} = part ->
        assert ReqLLM.Compaction.compaction_part?(part)
        assert part.metadata.provider in [:openai, :azure]
        assert is_binary(part.data["encrypted_content"])

      _part ->
        :ok
    end)
  end
end
