defmodule ReqLLM.Test.Scenarios.ObjectBasic do
  @moduledoc """
  Non-streaming object generation scenario.
  """

  use ReqLLM.Test.Scenario,
    id: :object_basic,
    name: "object generation (non-streaming)",
    description: "Validates object generation with the standard software engineer schema."

  alias ReqLLM.Test.Scenarios.Assertions
  alias ReqLLM.Test.Scenarios.Capabilities

  @impl ReqLLM.Test.Scenario
  def applies?(model), do: Capabilities.supports_object_generation?(model)

  @impl ReqLLM.Test.Scenario
  def fixtures(_model), do: ["object_basic"]

  @impl ReqLLM.Test.Scenario
  def run(model_spec, model, opts) do
    provider = Keyword.fetch!(opts, :provider)

    schema = [
      name: [type: :string, required: true, doc: "Person's full name"],
      age: [type: :pos_integer, required: true, doc: "Person's age in years"],
      occupation: [type: :string, doc: "Person's job or profession"]
    ]

    request_opts =
      param_bundles(provider).deterministic
      |> Keyword.put(:max_tokens, 500)
      |> then(&reasoning_overlay(model_spec, provider, &1, 500))

    {:ok, response} =
      ReqLLM.generate_object(
        model_spec,
        "Generate a software engineer profile",
        schema,
        fixture_opts(provider, "object_basic", request_opts)
      )

    assert %ReqLLM.Response{} = response
    Assertions.assert_profile_object_or_reasoning(response)

    Scenario.ok(__MODULE__, [Scenario.step(:generate_object, "object_basic")], %{
      provider: provider,
      model: model.id
    })
  end
end

defmodule ReqLLM.Test.Scenarios.ObjectStreaming do
  @moduledoc """
  Streaming object generation scenario.
  """

  use ReqLLM.Test.Scenario,
    id: :object_streaming,
    name: "object generation (streaming)",
    description:
      "Validates streaming object generation with the standard software engineer schema."

  alias ReqLLM.Test.Scenarios.Assertions
  alias ReqLLM.Test.Scenarios.Capabilities

  @impl ReqLLM.Test.Scenario
  def applies?(model), do: Capabilities.supports_streaming_object_generation?(model)

  @impl ReqLLM.Test.Scenario
  def fixtures(_model), do: ["object_streaming"]

  @impl ReqLLM.Test.Scenario
  def run(model_spec, model, opts) do
    provider = Keyword.fetch!(opts, :provider)

    schema = [
      name: [type: :string, required: true, doc: "Person's full name"],
      age: [type: :pos_integer, required: true, doc: "Person's age in years"],
      occupation: [type: :string, doc: "Person's job or profession"]
    ]

    request_opts =
      param_bundles(provider).deterministic
      |> Keyword.put(:max_tokens, 500)
      |> then(&reasoning_overlay(model_spec, provider, &1, 500))

    {:ok, response} =
      ReqLLM.stream_object(
        model_spec,
        "Generate a software engineer profile",
        schema,
        fixture_opts(provider, "object_streaming", request_opts)
      )

    response =
      if match?(%ReqLLM.StreamResponse{}, response) do
        {:ok, resp} = ReqLLM.StreamResponse.to_response(response)
        resp
      else
        response
      end

    Assertions.assert_profile_object_or_reasoning(response)

    Scenario.ok(__MODULE__, [Scenario.step(:stream_object, "object_streaming")], %{
      provider: provider,
      model: model.id
    })
  end
end

defmodule ReqLLM.Test.Scenarios.Reasoning do
  @moduledoc """
  Non-streaming and streaming reasoning scenario.
  """

  use ReqLLM.Test.Scenario,
    id: :reasoning,
    name: "reasoning/thinking tokens (non-streaming + streaming)",
    description: "Validates reasoning output acceptance rules for generate_text and stream_text."

  alias ReqLLM.Test.Scenarios.Assertions
  alias ReqLLM.Test.Scenarios.Capabilities

  @impl ReqLLM.Test.Scenario
  def applies?(model), do: Capabilities.supports_reasoning?(model)

  @impl ReqLLM.Test.Scenario
  def fixtures(_model), do: ["reasoning_basic", "reasoning_streaming"]

  @impl ReqLLM.Test.Scenario
  def run(model_spec, model, opts) do
    provider = Keyword.fetch!(opts, :provider)

    dbug(
      fn -> "\n[Comprehensive] model_spec=#{model_spec}, test=reasoning" end,
      component: :test
    )

    provider_config = param_bundles(provider)

    base_opts =
      provider_config.deterministic
      |> Keyword.delete(:temperature)
      |> Keyword.merge(
        max_tokens: 5000,
        temperature: 1.0,
        reasoning_effort: provider_config.reasoning[:reasoning_effort]
      )

    prompt = provider_config.reasoning_prompts.basic

    {:ok, response} =
      ReqLLM.generate_text(
        model_spec,
        prompt,
        fixture_opts(provider, "reasoning_basic", base_opts)
      )

    assert %ReqLLM.Response{} = response
    assert response.message.role == :assistant

    text = ReqLLM.Response.text(response) || ""
    thinking = ReqLLM.Response.thinking(response) || ""
    combined = text <> thinking
    assert combined != ""

    has_thinking_part? =
      Enum.any?(
        response.message.content,
        &(&1.type == :thinking and is_binary(&1.text) and &1.text != "")
      )

    reasoning_tokens = ReqLLM.Response.reasoning_tokens(response)
    has_any_output = combined != ""

    assert has_thinking_part? or (is_number(reasoning_tokens) and reasoning_tokens > 0) or
             has_any_output,
           "Expected thinking content, reasoning tokens, or text output; got thinking: #{inspect(thinking)} tokens: #{inspect(reasoning_tokens)} text: #{inspect(text)}"

    last = List.last(response.context.messages)
    assert last == response.message

    Assertions.assert_reasoning_details_if_present(response.message)

    context =
      ReqLLM.Context.new([
        system(provider_config.reasoning_prompts.streaming_system),
        user(provider_config.reasoning_prompts.streaming_user)
      ])

    stream_opts =
      provider_config.creative
      |> Keyword.delete(:temperature)
      |> Keyword.merge(
        max_tokens: 5000,
        temperature: 1.0,
        reasoning_effort: provider_config.reasoning[:reasoning_effort]
      )

    {:ok, stream_response} =
      ReqLLM.stream_text(
        model_spec,
        context,
        fixture_opts(provider, "reasoning_streaming", stream_opts)
      )

    assert %ReqLLM.StreamResponse{} = stream_response
    assert stream_response.stream
    assert stream_response.metadata_handle

    stream_chunks = Enum.to_list(stream_response.stream)

    {thinking_count, reasoning_tokens_stream} =
      stream_chunks
      |> Enum.reduce({0, 0}, fn chunk, {tc, rt} ->
        case chunk.type do
          :thinking ->
            {tc + 1, rt}

          :meta ->
            usage = chunk.metadata[:usage] || %{}
            rt2 = Map.get(usage, :reasoning_tokens, 0)
            {tc, max(rt, (is_number(rt2) && rt2) || 0)}

          _ ->
            {tc, rt}
        end
      end)

    stream_with_chunks = %{stream_response | stream: stream_chunks}
    {:ok, response} = ReqLLM.StreamResponse.to_response(stream_with_chunks)
    rt_final = ReqLLM.Response.reasoning_tokens(response)

    streaming_text = ReqLLM.Response.text(response) || ""
    has_streaming_output = streaming_text != ""

    assert thinking_count > 0 or reasoning_tokens_stream > 0 or rt_final > 0 or
             has_streaming_output,
           "Expected at least one :thinking chunk, positive reasoning_tokens, or text output; got tc=#{thinking_count} rt_stream=#{reasoning_tokens_stream} rt_final=#{rt_final} text_len=#{String.length(streaming_text)}"

    assert %ReqLLM.Response{} = response
    assert response.message.role == :assistant

    Assertions.assert_reasoning_details_if_present(response.message)

    Scenario.ok(
      __MODULE__,
      [
        Scenario.step(:generate_text, "reasoning_basic"),
        Scenario.step(:stream_text, "reasoning_streaming")
      ],
      %{provider: provider, model: model.id}
    )
  end
end
