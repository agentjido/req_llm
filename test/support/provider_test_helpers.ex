defmodule ReqLLM.ProviderTestHelpers do
  @moduledoc """
  Test helpers for provider-level testing.

  Provides fixtures, mocking utilities, and assertion helpers
  for testing provider implementations directly.
  """

  import ExUnit.Assertions

  alias ReqLLM.{Context, Model}

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
  Create an OpenAI-format JSON response fixture.

  Compatible with OpenAI, Groq, and other OpenAI-compatible providers.
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
  Create SSE (Server-Sent Events) fixture for streaming tests.
  """
  def sse_fixture(chunks) when is_list(chunks) do
    chunks
    |> Enum.map_join(&"data: #{Jason.encode!(&1)}\n\n")
    |> Kernel.<>("data: [DONE]\n\n")
  end

  @doc """
  Create an OpenAI-format tool call fixture for object generation tests.
  """
  def openai_format_tool_call_fixture(
        name \\ "structured_output",
        arguments \\ %{"name" => "Alice"}
      ) do
    %{
      "id" => "call_123",
      "type" => "function",
      "function" => %{
        "name" => name,
        "arguments" => Jason.encode!(arguments)
      }
    }
  end

  @doc """
  Execute a provider call with Req.Test mocking.
  """
  def with_req_mock(provider_module, response_fixture, test_fn) do
    Req.Test.stub(provider_module, fn conn ->
      assert conn.request_path == "/chat/completions"
      assert conn.method == "POST"

      case response_fixture do
        %{} = json_response -> Req.Test.json(conn, json_response)
        text when is_binary(text) -> Req.Test.text(conn, text)
      end
    end)

    # Make sure we use the test adapter
    original_env = System.get_env("LIVE")
    System.delete_env("LIVE")

    try do
      test_fn.()
    after
      if original_env, do: System.put_env("LIVE", original_env)
    end
  end

  @doc """
  Assert that a Response struct has the expected basic structure.
  """
  def assert_response_structure(%ReqLLM.Response{} = response) do
    assert is_binary(response.id)
    assert is_binary(response.model)
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

  def assert_response_structure(other) do
    flunk("Expected %ReqLLM.Response{}, got: #{inspect(other)}")
  end

  @doc """
  Assert that response text content is present and valid.
  """
  def assert_text_content(%ReqLLM.Response{} = response) do
    text = ReqLLM.Response.text(response)
    assert is_binary(text)
    assert String.length(text) > 0
    response
  end

  @doc """
  Assert that a response has the expected basic structure and context merging.

  Verifies:
  - Response structure is valid
  - Text content is present  
  - Context advancement (original messages + new assistant message)
  """
  def assert_basic_response({:ok, %ReqLLM.Response{} = response}) do
    response
    |> assert_response_structure()
    |> assert_text_content()
    |> assert_context_advancement()
  end

  def assert_basic_response(other) do
    flunk("Expected {:ok, %ReqLLM.Response{}}, got: #{inspect(other)}")
  end

  @doc """
  Assert that the response context contains the original messages plus assistant response.
  """
  def assert_context_advancement(%ReqLLM.Response{context: context, message: message} = response)
      when not is_nil(message) do
    # Context should have at least one message (the assistant response)
    assert length(context.messages) >= 1

    # The last message should be the assistant response
    last_message = List.last(context.messages)
    assert last_message.role == :assistant
    assert last_message == message

    response
  end

  def assert_context_advancement(%ReqLLM.Response{} = response) do
    # If no message, context should still be valid
    assert %Context{} = response.context
    response
  end

  @doc """
  Assert that response text is shorter than the given maximum length.
  """
  def assert_text_length(%ReqLLM.Response{} = response, max_length) do
    text = ReqLLM.Response.text(response)
    assert String.length(text) <= max_length
    response
  end

  @doc """
  Create a model fixture for testing.
  """
  def model_fixture(model_string) do
    Model.from!(model_string)
  end

  @doc """
  Generate fixture options for provider testing.
  """
  def fixture_opts(provider, fixture_name, params) do
    Keyword.merge([fixture: "#{provider}_#{fixture_name}"], params)
  end

  @doc """
  Standard parameter bundles for consistent testing across providers.
  """
  def param_bundles do
    %{
      deterministic: [
        temperature: 0.0,
        max_tokens: 10,
        seed: 42
      ],
      creative: [
        temperature: 0.9,
        max_tokens: 50,
        top_p: 0.8
      ],
      minimal: [
        temperature: 0.5,
        max_tokens: 5
      ]
    }
  end
end
