defmodule ReqLLM.GenerationTest do
  use ExUnit.Case, async: true

  alias ReqLLM.{Context, Generation, Response}

  describe "generate_text/3 core functionality with fixtures" do
    test "accepts string input format" do
      {:ok, response} =
        Generation.generate_text(
          "openai:gpt-4o-mini",
          "Hello",
          fixture: "openai_basic"
        )

      assert %Response{} = response
      # Model might have version suffix
      assert response.model =~ "gpt-4o-mini"
      assert is_binary(Response.text(response))
      assert String.length(Response.text(response)) > 0
    end

    test "accepts Context input format" do
      context = Context.new([Context.user("Hello world")])

      {:ok, response} =
        Generation.generate_text(
          "openai:gpt-4o-mini",
          context,
          fixture: "openai_basic"
        )

      assert %Response{} = response
    end

    test "accepts message list input format" do
      messages = [
        %{role: "user", content: "Hello"},
        %{role: "assistant", content: "Hi there!"}
      ]

      {:ok, response} =
        Generation.generate_text(
          "openai:gpt-4o-mini",
          messages,
          fixture: "openai_basic"
        )

      assert %Response{} = response
    end

    test "handles system prompt option" do
      {:ok, response} =
        Generation.generate_text(
          "openai:gpt-4o-mini",
          "Hello",
          system_prompt: "Be helpful",
          fixture: "openai_system_msg"
        )

      assert %Response{} = response
      # System prompt gets added to context, which we can verify indirectly
      # system + user at minimum
      assert length(response.context.messages) >= 2
    end
  end

  describe "generate_text/3 error cases" do
    test "returns error for invalid model spec" do
      {:error, error} = Generation.generate_text("invalid:model", "Hello")

      assert %ReqLLM.Error.Validation.Error{} = error
      assert error.reason =~ "Unsupported provider"
    end

    test "returns error for invalid role in message list" do
      messages = [
        %{role: "invalid_role", content: "Hello"}
      ]

      {:error, error} = Generation.generate_text("openai:gpt-4o-mini", messages)

      # Should get a Role error
      assert %ReqLLM.Error.Invalid.Role{} = error
      assert error.role == "invalid_role"
    end

    test "returns validation error for invalid options" do
      {:error, error} =
        Generation.generate_text(
          "openai:gpt-4o-mini",
          "Hello",
          temperature: "invalid"
        )

      # The error gets wrapped in Unknown, so we need to check the wrapped error
      assert %ReqLLM.Error.Unknown.Unknown{} = error
      assert %NimbleOptions.ValidationError{} = error.error
    end

    test "handles warnings correctly with on_unsupported: :error" do
      # Use OpenAI o1 model which doesn't support temperature
      {:error, error} =
        Generation.generate_text(
          "openai:o1-mini",
          "Hello",
          temperature: 0.7,
          on_unsupported: :error
        )

      # Should get error due to unsupported temperature parameter
      assert is_struct(error)
    end
  end

  describe "generate_text!/3" do
    test "returns text on success" do
      result =
        Generation.generate_text!(
          "openai:gpt-4o-mini",
          "Hello",
          fixture: "openai_basic"
        )

      assert is_binary(result)
      assert String.length(result) > 0
    end

    test "raises on error" do
      assert_raise ReqLLM.Error.Validation.Error, fn ->
        Generation.generate_text!("invalid:model", "Hello")
      end
    end
  end

  describe "stream_text/3 core functionality" do
    test "returns streaming response with fixture" do
      {:ok, response} =
        Generation.stream_text(
          "openai:gpt-4o-mini",
          "Tell me a story",
          fixture: "openai_streaming_test"
        )

      assert %Response{} = response
      assert response.stream? == true
      assert is_struct(response.stream, Stream)

      # Verify the stream contains expected chunks
      chunks = Enum.to_list(response.stream)

      content_chunks = Enum.filter(chunks, &(&1.type == :content))
      meta_chunks = Enum.filter(chunks, &(&1.type == :meta))

      assert length(content_chunks) == 2
      assert Enum.map(content_chunks, & &1.text) == ["Hello", "!"]

      assert length(meta_chunks) == 1
      assert hd(meta_chunks).metadata[:finish_reason] == "stop"
    end
  end

  describe "stream_text/3 error cases" do
    test "returns error for invalid model spec" do
      {:error, error} = Generation.stream_text("invalid:model", "Hello")

      assert %ReqLLM.Error.Validation.Error{} = error
      assert error.reason =~ "Unsupported provider"
    end
  end

  describe "stream_text!/3" do
    test "returns stream on success" do
      result =
        Generation.stream_text!(
          "openai:gpt-4o-mini",
          "Hello",
          fixture: "openai_streaming_test"
        )

      assert is_struct(result, Stream)
    end

    test "raises on error" do
      assert_raise ReqLLM.Error.Validation.Error, fn ->
        Generation.stream_text!("invalid:model", "Hello")
      end
    end
  end

  describe "option validation and translation" do
    test "validates base schema options" do
      schema = Generation.schema()

      {:ok, validated} =
        NimbleOptions.validate([temperature: 0.7, max_tokens: 100], schema)

      assert validated[:temperature] == 0.7
      assert validated[:max_tokens] == 100
    end

    test "includes on_unsupported option in schema" do
      schema = Generation.schema()
      on_unsupported_spec = Keyword.get(schema.schema, :on_unsupported)

      assert on_unsupported_spec != nil
      assert on_unsupported_spec[:type] == {:in, [:warn, :error, :ignore]}
      assert on_unsupported_spec[:default] == :warn
    end

    test "provider schema composition works" do
      provider_schema =
        ReqLLM.Provider.Options.compose_schema(
          Generation.schema(),
          ReqLLM.Providers.OpenAI
        )

      # Should include both base and provider options
      assert provider_schema.schema[:temperature] != nil
      assert provider_schema.schema[:provider_options] != nil
    end
  end

  describe "options and generation parameters" do
    test "accepts generation options without errors" do
      # Test that options are validated and passed through without HTTP calls
      {:ok, response} =
        Generation.generate_text(
          "openai:gpt-4o-mini",
          "Hello",
          temperature: 0.8,
          max_tokens: 50,
          top_p: 0.9,
          fixture: "openai_creative"
        )

      assert %Response{} = response
    end

    test "handles provider-specific options" do
      {:ok, response} =
        Generation.generate_text(
          "openai:gpt-4o-mini",
          "Hello",
          frequency_penalty: 0.1,
          fixture: "penalty_params"
        )

      assert %Response{} = response
    end
  end

  describe "generate_text/3 with req_http_options" do
    test "correctly passes http options to Req" do
      # We pass an intentionally invalid option to Req. If `req_http_options` are being passed correctly,
      # Req's internal validation will raise an ArgumentError. This confirms the options are being passed
      # all the way to `Req.new/1` without making a real network request.
      assert_raise ArgumentError, ~r/got unsupported atom method :invalid_method/, fn ->
        Generation.generate_text("openai:gpt-4o-mini", "Hello",
          req_http_options: [method: :invalid_method]
        )
      end
    end
  end
end
