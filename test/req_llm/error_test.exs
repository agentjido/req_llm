defmodule ReqLLM.ErrorTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Error

  # Shared test helpers
  defp assert_error_fields(error, expected_fields) do
    assert error.__exception__ == true

    for {field, value} <- expected_fields do
      assert Map.get(error, field) == value
    end
  end

  defp assert_message_format(error_module, error, expected_message) do
    assert error_module.message(error) == expected_message
  end

  describe "error class hierarchy" do
    test "error classes identify correctly" do
      for class <- [Error.Invalid, Error.API, Error.Validation, Error.Unknown] do
        assert class.error_class?()
      end
    end
  end

  describe "basic error types" do
    # Table-driven test for simple error types with single field
    simple_errors = [
      {Error.Invalid.Parameter, :parameter, "model", "Invalid parameter: model"},
      {Error.Invalid.Provider, :provider, "nonexistent", "Unknown provider: nonexistent"},
      {Error.Invalid.NotImplemented, :feature, "streaming", "streaming not implemented"},
      {Error.Invalid.Schema, :reason, "missing property", "Invalid schema: missing property"},
      {Error.Invalid.Role, :role, :invalid_role,
       "Invalid role: :invalid_role. Must be :user, :assistant, :system, or :tool"}
    ]

    for {error_module, field, value, expected_message} <- simple_errors do
      test "#{inspect(error_module)} creates error and formats message" do
        error = unquote(error_module).exception([{unquote(field), unquote(value)}])
        assert_error_fields(error, [{unquote(field), unquote(value)}])
        assert_message_format(unquote(error_module), error, unquote(expected_message))
      end
    end
  end

  describe "API request errors" do
    test "API.Request formats with and without status" do
      # With status
      error = Error.API.Request.exception(reason: "timeout", status: 408)
      assert_message_format(Error.API.Request, error, "API request failed (408): timeout")

      # Without status
      error = Error.API.Request.exception(reason: "network error", status: nil)
      assert_message_format(Error.API.Request, error, "API request failed: network error")
    end

    test "API.Response formats with and without status" do
      # With status
      error = Error.API.Response.exception(reason: "invalid json", status: 200)

      assert_message_format(
        Error.API.Response,
        error,
        "Provider response error (200): invalid json"
      )

      # Without status
      error = Error.API.Response.exception(reason: "parse error", status: nil)
      assert_message_format(Error.API.Response, error, "Provider response error: parse error")
    end
  end

  describe "message-related errors" do
    test "Invalid.Message formats with and without index" do
      # With index
      error = Error.Invalid.Message.exception(reason: "empty content", index: 2)
      assert_message_format(Error.Invalid.Message, error, "Message at index 2: empty content")

      # Without index
      error = Error.Invalid.Message.exception(reason: "invalid format", index: nil)
      assert_message_format(Error.Invalid.Message, error, "invalid format")
    end

    test "Invalid.MessageList formats message with received value" do
      received = "not a list"
      error = Error.Invalid.MessageList.exception(reason: "test", received: received)

      assert_message_format(
        Error.Invalid.MessageList,
        error,
        "Expected a list of messages, got: \"not a list\""
      )

      # Test with nil received
      error = Error.Invalid.MessageList.exception(reason: "test")

      assert_message_format(
        Error.Invalid.MessageList,
        error,
        "Expected a list of messages, got: nil"
      )
    end

    test "Invalid.Content formats message with received value" do
      received = %{invalid: "content"}
      error = Error.Invalid.Content.exception(reason: "test", received: received)

      expected =
        "Content must be a string or list of ContentPart structs, got: %{invalid: \"content\"}"

      assert_message_format(Error.Invalid.Content, error, expected)

      # Test with nil received
      error = Error.Invalid.Content.exception(reason: "test")
      expected_nil = "Content must be a string or list of ContentPart structs, got: nil"
      assert_message_format(Error.Invalid.Content, error, expected_nil)
    end
  end

  describe "complex API errors" do
    test "API.SchemaValidation message formatting" do
      # Custom message
      error = Error.API.SchemaValidation.exception(message: "Custom schema error")
      assert_message_format(Error.API.SchemaValidation, error, "Custom schema error")

      # With path and errors
      error =
        Error.API.SchemaValidation.exception(
          errors: ["Required field missing", "Invalid type"],
          json_path: "$.user.name"
        )

      assert_message_format(
        Error.API.SchemaValidation,
        error,
        "Schema validation failed at $.user.name: Required field missing, Invalid type"
      )

      # Errors only
      error = Error.API.SchemaValidation.exception(errors: ["Error 1", "Error 2", "Error 3"])

      assert_message_format(
        Error.API.SchemaValidation,
        error,
        "Schema validation failed: Error 1, Error 2, Error 3"
      )

      # Error truncation (>3 errors)
      error =
        Error.API.SchemaValidation.exception(errors: ["Error 1", "Error 2", "Error 3", "Error 4"])

      message = Error.API.SchemaValidation.message(error)
      assert message == "Schema validation failed: Error 1, Error 2, Error 3"
      refute String.contains?(message, "Error 4")

      # Fallback message
      error = Error.API.SchemaValidation.exception([])
      assert_message_format(Error.API.SchemaValidation, error, "Schema validation failed")
    end

    test "API.JSONDecode message formatting" do
      # Custom message
      error = Error.API.JSONDecode.exception(message: "Invalid JSON syntax")
      assert_message_format(Error.API.JSONDecode, error, "JSON decode error: Invalid JSON syntax")

      # With position and partial
      error = Error.API.JSONDecode.exception(partial: "{ \"incomplete\": \"json", position: 23)

      assert_message_format(
        Error.API.JSONDecode,
        error,
        "JSON decode error at position 23. Partial: { \"incomplete\": \"json..."
      )

      # Partial only
      error = Error.API.JSONDecode.exception(partial: "{ \"incomplete\": \"json")

      assert_message_format(
        Error.API.JSONDecode,
        error,
        "JSON decode error. Partial: { \"incomplete\": \"json..."
      )

      # Long partial truncation
      long_partial = String.duplicate("a", 100)
      error = Error.API.JSONDecode.exception(partial: long_partial)
      message = Error.API.JSONDecode.message(error)
      assert String.contains?(message, String.slice(long_partial, 0, 50))
      assert String.ends_with?(message, "...")

      # Fallback message
      error = Error.API.JSONDecode.exception([])
      assert_message_format(Error.API.JSONDecode, error, "JSON decode error")
    end
  end

  describe "validation and unknown errors" do
    test "Validation.Error creation and formatting" do
      error =
        Error.Validation.Error.exception(
          tag: :invalid_model,
          reason: "Model not found",
          context: [id: "test"]
        )

      assert %Error.Validation.Error{} = error

      assert_error_fields(error,
        tag: :invalid_model,
        reason: "Model not found",
        context: [id: "test"]
      )

      assert_message_format(Error.Validation.Error, error, "Model not found")
    end

    test "Unknown.Unknown error formatting" do
      original_error = %RuntimeError{message: "something went wrong"}
      error = Error.Unknown.Unknown.exception(error: original_error)

      assert_message_format(
        Error.Unknown.Unknown,
        error,
        "Unknown error: #{inspect(original_error)}"
      )
    end
  end

  describe "validation_error/3 helper" do
    test "creates validation error with context" do
      error = Error.validation_error(:invalid_model_spec, "Bad model", id: "test")
      assert %Error.Validation.Error{} = error

      assert_error_fields(error,
        tag: :invalid_model_spec,
        reason: "Bad model",
        context: [id: "test"]
      )
    end

    test "creates validation error with default empty context" do
      error = Error.validation_error(:test_error, "Test reason")
      assert_error_fields(error, tag: :test_error, reason: "Test reason", context: [])
    end
  end

  describe "Splode integration" do
    # Table-driven test for error class verification
    error_classes = [
      {Error.Invalid.Parameter, :invalid, [parameter: "test"]},
      {Error.API.Request, :api, [reason: "test"]},
      {Error.Validation.Error, :validation, [tag: :test, reason: "test"]},
      {Error.Unknown.Unknown, :unknown, [error: "test"]}
    ]

    test "error classes have correct class identifiers and exception behavior" do
      for {error_module, expected_class, fields} <- unquote(Macro.escape(error_classes)) do
        error = error_module.exception(fields)
        assert error.class == expected_class
        assert error.__exception__ == true
        assert is_binary(Exception.message(error))
      end
    end

    test "all error types implement proper exception behavior" do
      errors = [
        Error.Invalid.Parameter.exception(parameter: "test"),
        Error.Invalid.Provider.exception(provider: "test"),
        Error.Invalid.NotImplemented.exception(feature: "test"),
        Error.Invalid.Schema.exception(reason: "test"),
        Error.Invalid.Message.exception(reason: "test"),
        Error.Invalid.MessageList.exception(reason: "test"),
        Error.Invalid.Content.exception(reason: "test"),
        Error.Invalid.Role.exception(role: :invalid),
        Error.API.Request.exception(reason: "test"),
        Error.API.Response.exception(reason: "test"),
        Error.API.SchemaValidation.exception(message: "test"),
        Error.API.JSONDecode.exception(message: "test"),
        Error.Validation.Error.exception(tag: :test, reason: "test"),
        Error.Unknown.Unknown.exception(error: "test")
      ]

      for error <- errors do
        assert error.__exception__ == true
        assert is_binary(Exception.message(error))
        assert is_atom(error.class)
      end
    end

    test "errors can be raised" do
      error = Error.Invalid.Parameter.exception(parameter: "test")

      assert_raise Error.Invalid.Parameter, "Invalid parameter: test", fn ->
        raise error
      end
    end
  end
end
