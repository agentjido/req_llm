defmodule ReqLLM.Test.Scenarios.Basic do
  @moduledoc """
  Basic non-streaming text generation scenario.
  """

  use ReqLLM.Test.Scenario,
    id: :basic,
    name: "basic generate_text (non-streaming)",
    description: "Validates a deterministic non-streaming text response."

  @impl ReqLLM.Test.Scenario
  def run(model_spec, model, opts) do
    provider = Keyword.fetch!(opts, :provider)

    dbug(
      fn -> "\n[Comprehensive] model_spec=#{model_spec}, test=basic_generate" end,
      component: :test
    )

    request_opts =
      reasoning_overlay(
        model_spec,
        param_bundles().deterministic,
        2000
      )

    ReqLLM.generate_text(
      model_spec,
      "Hello world!",
      fixture_opts("basic", request_opts)
    )
    |> assert_basic_response()

    Scenario.ok(__MODULE__, [Scenario.step(:generate_text, "basic")], %{
      provider: provider,
      model: model.id
    })
  end
end

defmodule ReqLLM.Test.Scenarios.Streaming do
  @moduledoc """
  Streaming text generation scenario.
  """

  use ReqLLM.Test.Scenario,
    id: :streaming,
    name: "stream_text with system context and creative params",
    description: "Validates streaming response shape, content, finish reason, and usage."

  alias ReqLLM.Test.Scenarios.Assertions

  @impl ReqLLM.Test.Scenario
  def run(model_spec, model, opts) do
    provider = Keyword.fetch!(opts, :provider)

    dbug(
      fn -> "\n[Comprehensive] model_spec=#{model_spec}, test=streaming" end,
      component: :test
    )

    context =
      ReqLLM.Context.new([
        system("You are a helpful, creative assistant."),
        user("Say hello in one short, imaginative sentence.")
      ])

    request_opts =
      reasoning_overlay(model_spec, provider, param_bundles(provider).creative, 2000)

    {:ok, stream_response} =
      ReqLLM.stream_text(
        model_spec,
        context,
        fixture_opts(provider, "streaming", request_opts)
      )

    assert %ReqLLM.StreamResponse{} = stream_response
    assert stream_response.stream
    assert stream_response.metadata_handle

    {:ok, response} = ReqLLM.StreamResponse.to_response(stream_response)

    finish_reason = ReqLLM.StreamResponse.finish_reason(stream_response)

    assert %ReqLLM.Response{} = response

    text = ReqLLM.Response.text(response) || ""
    thinking = ReqLLM.Response.thinking(response) || ""
    combined = text <> thinking

    assert combined != "",
           "Expected text or thinking content, got empty (text: #{inspect(text)}, thinking: #{inspect(thinking)})"

    assert response.message.role == :assistant

    refute is_nil(finish_reason)

    Assertions.assert_streaming_usage(response.usage)

    Scenario.ok(__MODULE__, [Scenario.step(:stream_text, "streaming")], %{
      provider: provider,
      model: model.id
    })
  end
end

defmodule ReqLLM.Test.Scenarios.TokenLimit do
  @moduledoc """
  Token limit constraint scenario.
  """

  use ReqLLM.Test.Scenario,
    id: :token_limit,
    name: "token limit constraints",
    description: "Validates constrained generation and length handling."

  @impl ReqLLM.Test.Scenario
  def run(model_spec, model, opts) do
    provider = Keyword.fetch!(opts, :provider)

    request_opts =
      param_bundles(provider).minimal
      |> Keyword.put(:max_tokens, 100)
      |> then(&reasoning_overlay(model_spec, provider, &1, 3000))

    case ReqLLM.generate_text(
           model_spec,
           "Write a very long story about dragons and adventures",
           fixture_opts(provider, "token_limit", request_opts)
         ) do
      {:ok, response} ->
        assert_basic_response({:ok, response})

        content = combined_content(response)

        if truncated?(response) do
          rt = ReqLLM.Response.reasoning_tokens(response)
          assert is_number(rt) and rt >= 0

          if content != "" do
            assert String.length(content) > 0,
                   "Truncated response should have some content or reasoning tokens"
          end
        else
          assert_text_length(response, 150)
        end

      other ->
        flunk("Expected {:ok, %ReqLLM.Response{}}, got: #{inspect(other)}")
    end

    Scenario.ok(__MODULE__, [Scenario.step(:generate_text, "token_limit")], %{
      provider: provider,
      model: model.id
    })
  end
end

defmodule ReqLLM.Test.Scenarios.Usage do
  @moduledoc """
  Usage and cost normalization scenario.
  """

  use ReqLLM.Test.Scenario,
    id: :usage,
    name: "usage metrics and cost calculations",
    description: "Validates usage metrics, cached tokens, reasoning tokens, and costs."

  alias ReqLLM.Test.Scenarios.Assertions

  @impl ReqLLM.Test.Scenario
  def run(model_spec, model, opts) do
    provider = Keyword.fetch!(opts, :provider)

    dbug(
      fn -> "\n[Comprehensive] model_spec=#{model_spec}, test=usage" end,
      component: :test
    )

    max_tokens =
      case model do
        %{capabilities: %{reasoning: true}} -> 500
        %{model: "gpt-4.1" <> _} -> 16
        %{extra: %{wire: %{protocol: "openai_responses"}}} -> 200
        _ -> 10
      end

    {:ok, response} =
      ReqLLM.generate_text(
        model_spec,
        "Hi there!",
        fixture_opts(
          "usage",
          Keyword.put(param_bundles().deterministic, :max_tokens, max_tokens)
        )
      )

    assert %ReqLLM.Response{} = response

    text = ReqLLM.Response.text(response) || ""
    reasoning_tokens = response.usage.reasoning_tokens || 0

    assert text != "" or reasoning_tokens > 0,
           "Expected either text content or reasoning tokens, got neither"

    assert is_map(response.usage)

    assert is_number(response.usage.input_tokens) and response.usage.input_tokens > 0
    assert is_number(response.usage.output_tokens) and response.usage.output_tokens >= 0
    assert is_number(response.usage.total_tokens) and response.usage.total_tokens > 0
    assert is_number(response.usage.cached_tokens) and response.usage.cached_tokens >= 0

    assert is_number(response.usage.reasoning_tokens) and
             response.usage.reasoning_tokens >= 0

    case model do
      %LLMDB.Model{cost: cost_map} when is_map(cost_map) ->
        Assertions.assert_usage_cost_fields(response.usage, true)

      _ ->
        Assertions.assert_usage_cost_fields(response.usage, false)
    end

    Scenario.ok(__MODULE__, [Scenario.step(:generate_text, "usage")], %{
      provider: provider,
      model: model.id
    })
  end
end

defmodule ReqLLM.Test.Scenarios.ContextAppend do
  @moduledoc """
  Conversation context append scenario.
  """

  use ReqLLM.Test.Scenario,
    id: :context_append,
    name: "context append continues conversation",
    description: "Validates that generated responses can advance an existing context."

  @impl ReqLLM.Test.Scenario
  def fixtures(_model), do: ["context_append_1", "context_append_2"]

  @impl ReqLLM.Test.Scenario
  def run(model_spec, model, opts) do
    provider = Keyword.fetch!(opts, :provider)

    ctx = ReqLLM.Context.new([user("Respond with a single word 'Hi'.")])

    request_opts =
      param_bundles().deterministic
      |> Keyword.put(:max_tokens, 1024)

    {:ok, resp1} =
      ReqLLM.generate_text(
        model_spec,
        ctx,
        fixture_opts(provider, "context_append_1", request_opts)
      )

    ctx2 = ReqLLM.Context.append(resp1.context, user("Hi again"))

    {:ok, resp2} =
      ReqLLM.generate_text(
        model_spec,
        ctx2,
        fixture_opts(provider, "context_append_2", request_opts)
      )

    text = ReqLLM.Response.text(resp2) || ""
    reasoning_tokens = Map.get(resp2.usage || %{}, :reasoning_tokens, 0)

    assert text != "" or reasoning_tokens > 0
    assert length(resp2.context.messages) >= 4
    assert List.last(resp2.context.messages) == resp2.message
    assert resp2.message.role == :assistant

    Scenario.ok(
      __MODULE__,
      [
        Scenario.step(:first_turn, "context_append_1"),
        Scenario.step(:second_turn, "context_append_2")
      ],
      %{provider: provider, model: model.id}
    )
  end
end
