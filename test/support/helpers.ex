defmodule ReqLLM.Test.Helpers do
  @moduledoc """
  Shared test fixtures and normalization assertions for ReqLLM tests.

  Provides:
  - Fixture helpers for contexts, models, and OpenAI-format JSON
  - Normalization assertions for responses, streams, and usage
  - Validation of all normalization guarantees from guides/normalization.md
  """

  import ExUnit.Assertions

  alias ReqLLM.{Context, Message, Model, Response, StreamChunk}

  @doc """
  Create a basic context fixture for testing.
  """
  def context_fixture do
    Context.new([
      Context.system("You are a helpful assistant."),
      Context.user("Hello, how are you?")
    ])
  end

  @doc """
  Create a model fixture from a model specification string.

  ## Examples

      iex> model_fixture("anthropic:claude-3-5-sonnet")
      %Model{provider: :anthropic, model: "claude-3-5-sonnet"}

  """
  def model_fixture(model_spec) when is_binary(model_spec) do
    Model.from!(model_spec)
  end

  @doc """
  Create an OpenAI-format JSON response fixture for unit tests.

  Compatible with OpenAI, Groq, and other OpenAI-compatible providers.

  ## Options

  - `:id` - Response ID (default: "chatcmpl-test123")
  - `:model` - Model name (default: "llama-3.1-8b-instant")
  - `:content` - Assistant message content (default: "Hello! I'm doing well, thank you.")
  - `:finish_reason` - Finish reason (default: "stop")
  - `:input_tokens` - Input token count (default: 10)
  - `:output_tokens` - Output token count (default: 8)
  - `:total_tokens` - Total token count (default: 18)

  """
  def openai_format_json_fixture(opts \\ []) do
    %{
      "id" => Keyword.get(opts, :id, "chatcmpl-test123"),
      "object" => "chat.completion",
      "created" => 1_234_567_890,
      "model" => Keyword.get(opts, :model, "llama-3.1-8b-instant"),
      "choices" => [
        %{
          "index" => 0,
          "message" => %{
            "role" => "assistant",
            "content" => Keyword.get(opts, :content, "Hello! I'm doing well, thank you.")
          },
          "finish_reason" => Keyword.get(opts, :finish_reason, "stop")
        }
      ],
      "usage" => %{
        "prompt_tokens" => Keyword.get(opts, :input_tokens, 10),
        "completion_tokens" => Keyword.get(opts, :output_tokens, 8),
        "total_tokens" => Keyword.get(opts, :total_tokens, 18)
      }
    }
  end

  @doc """
  Assert that a response meets all normalization guarantees.

  Verifies:
  1. Response structure (%ReqLLM.Response{}, id/model are binary)
  2. Message normalization (role: :assistant, text returns binary)
  3. Finish reason is atom (:stop | :length | :tool_calls | :content_filter)
  4. Usage normalization (atom keys, integer values, optional cost floats)
  5. Context advancement (messages list grown, last is assistant)

  """
  def assert_normalized_response(%Response{} = response) do
    assert_response_structure(response)
    assert_message_normalized(response)
    assert_finish_reason_normalized(response)
    assert_usage_normalized(response.usage)
    assert_context_advanced(response)
    response
  end

  @doc """
  Assert that a streaming response meets all normalization guarantees.

  Verifies:
  1. Stream structure (stream? == true, stream is %Stream{})
  2. Chunk types (all StreamChunk, proper type atoms)
  3. Content presence (at least one text chunk)
  4. Materialization works and passes assert_normalized_response

  """
  def assert_normalized_stream(%Response{stream?: true} = response) do
    assert_stream_structure(response)

    chunks = Enum.to_list(response.stream)
    assert_chunk_types(chunks)
    assert_content_presence(chunks)

    materialized = Response.join_stream(response)
    assert_normalized_response(materialized)

    response
  end

  def assert_normalized_stream(%Response{stream?: false}) do
    flunk("Expected streaming response but got stream? == false")
  end

  @doc """
  Assert that usage data is properly normalized.

  Verifies:
  - Keys are atoms: :input_tokens, :output_tokens, :total_tokens
  - All values are non-negative integers
  - Optional: :cached_input, :reasoning (integers)
  - Optional: :input_cost, :output_cost, :total_cost (floats)

  """
  def assert_usage_normalized(nil), do: :ok

  def assert_usage_normalized(usage) when is_map(usage) do
    assert is_integer(usage.input_tokens) and usage.input_tokens >= 0,
           "usage.input_tokens must be non-negative integer, got: #{inspect(usage.input_tokens)}"

    assert is_integer(usage.output_tokens) and usage.output_tokens >= 0,
           "usage.output_tokens must be non-negative integer, got: #{inspect(usage.output_tokens)}"

    assert is_integer(usage.total_tokens) and usage.total_tokens >= 0,
           "usage.total_tokens must be non-negative integer, got: #{inspect(usage.total_tokens)}"

    if Map.has_key?(usage, :cached_input) do
      assert is_integer(usage.cached_input) and usage.cached_input >= 0,
             "usage.cached_input must be non-negative integer, got: #{inspect(usage.cached_input)}"
    end

    if Map.has_key?(usage, :reasoning) do
      assert is_integer(usage.reasoning) and usage.reasoning >= 0,
             "usage.reasoning must be non-negative integer, got: #{inspect(usage.reasoning)}"
    end

    if Map.has_key?(usage, :input_cost) do
      assert is_float(usage.input_cost) and usage.input_cost >= 0,
             "usage.input_cost must be non-negative float, got: #{inspect(usage.input_cost)}"
    end

    if Map.has_key?(usage, :output_cost) do
      assert is_float(usage.output_cost) and usage.output_cost >= 0,
             "usage.output_cost must be non-negative float, got: #{inspect(usage.output_cost)}"
    end

    if Map.has_key?(usage, :total_cost) do
      assert is_float(usage.total_cost) and usage.total_cost >= 0,
             "usage.total_cost must be non-negative float, got: #{inspect(usage.total_cost)}"
    end

    :ok
  end

  defp assert_response_structure(response) do
    assert %Response{} = response, "Response must be %ReqLLM.Response{} struct"

    assert is_binary(response.id) and byte_size(response.id) > 0,
           "response.id must be non-empty binary, got: #{inspect(response.id)}"

    assert is_binary(response.model) and byte_size(response.model) > 0,
           "response.model must be non-empty binary, got: #{inspect(response.model)}"

    assert %Context{} = response.context

    if response.usage do
      assert is_map(response.usage)

      for key <- [:input_tokens, :output_tokens, :total_tokens] do
        if Map.has_key?(response.usage, key) do
          assert is_integer(response.usage[key])
        end
      end
    end

    response
  end

  defp assert_message_normalized(response) do
    assert %Message{role: :assistant} = response.message,
           "response.message.role must be :assistant, got: #{inspect(response.message.role)}"

    text = Response.text(response)

    assert is_binary(text) or is_nil(text),
           "Response.text/1 must return binary or nil, got: #{inspect(text)}"

    if is_nil(text) or text == "" do
      tool_calls = Response.tool_calls(response)

      assert not Enum.empty?(tool_calls),
             "Response text can only be empty if tool_call content parts exist"
    end
  end

  defp assert_finish_reason_normalized(response) do
    valid_reasons = [:stop, :length, :tool_calls, :content_filter, :error, nil]

    assert response.finish_reason in valid_reasons,
           "finish_reason must be atom in #{inspect(valid_reasons)}, got: #{inspect(response.finish_reason)}"
  end

  defp assert_context_advanced(response) do
    assert length(response.context.messages) >= 1,
           "response.context must contain at least one message"

    last_message = List.last(response.context.messages)

    assert last_message == response.message,
           "Last message in context must match response.message"

    assert last_message.role == :assistant,
           "Last message role must be :assistant, got: #{inspect(last_message.role)}"
  end

  defp assert_stream_structure(response) do
    assert response.stream? == true,
           "response.stream? must be true for streaming responses"

    assert match?(%Stream{}, response.stream),
           "response.stream must be %Stream{}, got: #{inspect(response.stream)}"
  end

  defp assert_chunk_types(chunks) do
    valid_types = [:role, :content, :text, :tool_call, :meta, :thinking]

    Enum.each(chunks, fn chunk ->
      assert %StreamChunk{} = chunk,
             "All chunks must be %StreamChunk{}, got: #{inspect(chunk)}"

      assert chunk.type in valid_types,
             "chunk.type must be in #{inspect(valid_types)}, got: #{inspect(chunk.type)}"
    end)
  end

  defp assert_content_presence(chunks) do
    content_chunks =
      Enum.filter(chunks, fn chunk ->
        chunk.type in [:content, :text] and chunk.text != nil and chunk.text != ""
      end)

    assert not Enum.empty?(content_chunks),
           "Stream must contain at least one non-empty text/content chunk"
  end

  @doc """
  Create fixture options by adding the :fixture key with test name only.

  Path is automatically derived from the model. Provider parameter kept for API compatibility.

  ## Examples

      iex> fixture_opts(:anthropic, "basic", [temperature: 0.0])
      [temperature: 0.0, fixture: "basic"]
  """
  def fixture_opts(_provider, name, extra_opts \\ []) do
    Keyword.put(extra_opts, :fixture, name)
  end

  @doc """
  Standard parameter bundles for consistent testing across providers.
  """
  def param_bundles(provider \\ :default) do
    base = %{
      deterministic: [
        temperature: 0.0,
        max_tokens: 50,
        seed: 42
      ],
      creative: [
        temperature: 0.9,
        max_tokens: 100,
        top_p: 0.8
      ],
      minimal: [
        temperature: 0.5,
        max_tokens: 50
      ],
      tool_test_tokens: 150,
      reasoning_effort: "low",
      reasoning_prompts: %{
        basic: "Solve 12*7 and show your internal thinking (brief).",
        streaming_system: "You are a careful, step-by-step reasoner.",
        streaming_user: "Briefly think through your approach, then answer: What is 15*3?"
      },
      validate_cached_tokens: false
    }

    case provider do
      :google ->
        %{
          deterministic: base.deterministic ++ [provider_options: [google_thinking_budget: 0]],
          creative: base.creative ++ [provider_options: [google_thinking_budget: 0]],
          minimal: base.minimal ++ [provider_options: [google_thinking_budget: 0]],
          tool_test_tokens: base.tool_test_tokens,
          reasoning_effort: base.reasoning_effort,
          reasoning_prompts: base.reasoning_prompts,
          validate_cached_tokens: false
        }

      :anthropic ->
        %{
          deterministic: base.deterministic,
          creative: [temperature: 0.9, max_tokens: 100],
          minimal: base.minimal,
          tool_test_tokens: base.tool_test_tokens,
          reasoning_effort: base.reasoning_effort,
          reasoning_prompts: base.reasoning_prompts,
          validate_cached_tokens: false
        }

      :xai ->
        %{
          deterministic: base.deterministic,
          creative: base.creative,
          minimal: base.minimal,
          tool_test_tokens: 500,
          reasoning_effort: "low",
          reasoning_prompts: %{
            basic: "Calculate 15 times 3. Think step-by-step.",
            streaming_system: "You are a helpful math tutor.",
            streaming_user: "What is 8 plus 7? Show your reasoning."
          },
          validate_cached_tokens: false
        }

      :openai ->
        %{
          deterministic: base.deterministic,
          creative: base.creative,
          minimal: base.minimal,
          tool_test_tokens: base.tool_test_tokens,
          reasoning_effort: base.reasoning_effort,
          reasoning_prompts: base.reasoning_prompts,
          validate_cached_tokens: true
        }

      :groq ->
        %{
          deterministic: base.deterministic,
          creative: base.creative,
          minimal: base.minimal,
          tool_test_tokens: base.tool_test_tokens,
          reasoning_effort: "default",
          reasoning_prompts: base.reasoning_prompts,
          validate_cached_tokens: false
        }

      _ ->
        base
    end
  end

  @doc """
  Assert that a response has the expected basic structure and context merging.

  Verifies:
  - Response structure is valid
  - Text content is present
  - Context advancement (original messages + new assistant message)
  """
  def assert_basic_response({:ok, %Response{} = response}) do
    response
    |> assert_response_structure()
    |> assert_text_content()
    |> assert_context_advancement()
  end

  def assert_basic_response(other) do
    flunk("Expected {:ok, %ReqLLM.Response{}}, got: #{inspect(other)}")
  end

  @doc """
  Assert text response length is within expected range.
  """
  def assert_text_length(response, min_length) do
    text = Response.text(response) || ""
    thinking = Response.thinking(response) || ""
    combined_length = String.length(text) + String.length(thinking)

    assert combined_length >= min_length,
           "Expected text or thinking length >= #{min_length}, got #{combined_length} (text: #{String.length(text)}, thinking: #{String.length(thinking)})"

    response
  end

  defp assert_text_content(%Response{message: nil} = response) do
    flunk("Expected response with message, got nil message")
    response
  end

  defp assert_text_content(%Response{message: message} = response) do
    text = Response.text(response) || ""
    thinking = Response.thinking(response) || ""

    assert is_binary(text)
    assert is_binary(thinking)

    has_tool_calls =
      message.content
      |> Enum.any?(fn part -> part.type == :tool_call end)

    combined_length = String.length(text) + String.length(thinking)

    if has_tool_calls do
      assert combined_length >= 0
    else
      assert combined_length > 0,
             "Expected text or thinking content, got text=#{inspect(text)}, thinking=#{inspect(thinking)}"
    end

    response
  end

  defp assert_context_advancement(%Response{context: context, message: message} = response)
       when not is_nil(message) do
    assert length(context.messages) >= 1

    last_message = List.last(context.messages)
    assert last_message.role == :assistant
    assert last_message == message

    response
  end

  defp assert_context_advancement(%Response{} = response) do
    assert %Context{} = response.context
    response
  end

  @doc """
  Assert that a response contains at least one tool call in the message content.

  Verifies:
  - At least one content part has type :tool_call
  - Tool call has tool_name
  - Tool call has input (arguments map)
  """
  def assert_has_tool_call(response) do
    tool_call_content =
      Enum.find(response.message.content, fn content ->
        content.type == :tool_call
      end)

    assert tool_call_content, "Expected to find at least one tool_call in message content"
    assert tool_call_content.tool_name
    assert tool_call_content.input
    assert is_map(tool_call_content.input)

    response
  end
end
