defmodule ReqLLM.ProviderCase do
  @moduledoc """
  Case template for provider-level testing.

  Provides a consistent test environment and common setup for testing
  ReqLLM provider implementations at the low-level Req plugin API level.

  ## Usage

      defmodule ReqLLM.Providers.MyProviderTest do
        use ReqLLM.ProviderCase, provider: ReqLLM.Providers.MyProvider
      end

  ## Automatic Setup

  - Sets appropriate API key environment variables
  - Imports helper functions for fixtures and assertions
  """

  use ExUnit.CaseTemplate

  import ExUnit.Assertions

  alias ReqLLM.Context

  using(opts) do
    provider = Keyword.get(opts, :provider)

    quote do
      use ExUnit.Case, async: false

      import ReqLLM.ProviderCase

      @provider unquote(provider)

      setup do
        if @provider do
          env_key = ReqLLM.ProviderCase.env_key_for(@provider)
          System.put_env(env_key, "test-key-12345")
        end

        :ok
      end
    end
  end

  @doc """
  Determines the environment variable key for a provider's API key.
  """
  def env_key_for(provider) do
    if function_exported?(provider, :default_env_key, 0) do
      provider.default_env_key()
    else
      provider_id = provider.provider_id()
      "#{provider_id |> Atom.to_string() |> String.upcase()}_API_KEY"
    end
  end

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
  """
  def model_fixture(model_string) do
    {:ok, model} = ReqLLM.model(model_string)
    model
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

  For tool call responses, text may be empty if tool calls are present.
  """
  def assert_text_content(%ReqLLM.Response{message: message} = response) do
    text = ReqLLM.Response.text(response)
    assert is_binary(text)

    has_tool_calls =
      message.content
      |> Enum.any?(fn part -> part.type == :tool_call end)

    if has_tool_calls do
      assert String.length(text) >= 0
    else
      assert String.length(text) > 0
    end

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
    assert context.messages != []

    last_message = List.last(context.messages)
    assert last_message.role == :assistant
    assert last_message == message

    response
  end

  def assert_context_advancement(%ReqLLM.Response{} = response) do
    assert %Context{} = response.context
    response
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
      ]
    }

    case provider do
      :google ->
        %{
          deterministic: base.deterministic ++ [reasoning_token_budget: 0],
          creative: base.creative ++ [reasoning_token_budget: 0],
          minimal: base.minimal ++ [reasoning_token_budget: 0]
        }

      _ ->
        base
    end
  end
end
