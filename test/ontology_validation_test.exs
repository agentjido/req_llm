# test/ontology_validation_test.exs
# Purpose: Test SHACL constraint validation (Q phase)

defmodule ReqLLM.OntologyValidationTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Ontology.Validator
  alias ReqLLM.Ontology.Emitter

  describe "validate_response/1" do
    test "valid response passes validation" do
      response = %{
        id: "resp_123",
        finish_reason: :stop,
        context: %{
          messages: [
            %{role: :user, parts: [%{type: :text, text: "Hello"}]}
          ]
        },
        message: %{
          role: :assistant,
          parts: [%{type: :text, text: "Hi there!"}]
        },
        usage: %{
          input_tokens: 10,
          output_tokens: 5
        }
      }

      assert :ok = Validator.validate_response(response)
    end

    test "response missing context fails validation" do
      response = %{
        id: "resp_123",
        finish_reason: :stop,
        message: %{role: :assistant, parts: [%{type: :text, text: "Hi"}]}
      }

      assert {:error, errors} = Validator.validate_response(response)
      assert "Response must have context" in errors
    end

    test "response missing message fails validation" do
      response = %{
        id: "resp_123",
        finish_reason: :stop,
        context: %{messages: [%{role: :user, parts: [%{text: "Hello"}]}]}
      }

      assert {:error, errors} = Validator.validate_response(response)
      assert "Response must have message" in errors
    end

    test "response with invalid finish_reason fails validation" do
      response = %{
        id: "resp_123",
        finish_reason: :invalid_reason,
        context: %{messages: [%{role: :user, parts: [%{text: "Hello"}]}]},
        message: %{role: :assistant, parts: [%{text: "Hi"}]}
      }

      assert {:error, errors} = Validator.validate_response(response)
      assert Enum.any?(errors, &String.contains?(&1, "finishReason"))
    end
  end

  describe "validate_context/1" do
    test "valid context passes validation" do
      context = %{
        messages: [
          %{role: :user, parts: [%{type: :text, text: "Hello"}]},
          %{role: :assistant, parts: [%{type: :text, text: "Hi"}]}
        ]
      }

      assert :ok = Validator.validate_context(context)
    end

    test "context with no messages fails validation" do
      context = %{messages: []}

      assert {:error, errors} = Validator.validate_context(context)
      assert "Context must have at least one message" in errors
    end

    test "context with invalid message fails validation" do
      context = %{
        messages: [
          %{role: :user, parts: []}  # Invalid: no parts
        ]
      }

      assert {:error, errors} = Validator.validate_context(context)
      assert Enum.any?(errors, &String.contains?(&1, "must have at least one content part"))
    end
  end

  describe "validate_message/1" do
    test "valid message passes validation" do
      message = %{
        role: :user,
        parts: [%{type: :text, text: "Hello, world!"}]
      }

      assert :ok = Validator.validate_message(message)
    end

    test "message missing role fails validation" do
      message = %{
        parts: [%{type: :text, text: "Hello"}]
      }

      assert {:error, errors} = Validator.validate_message(message)
      assert "Message must have role" in errors
    end

    test "message with invalid role fails validation" do
      message = %{
        role: :invalid_role,
        parts: [%{type: :text, text: "Hello"}]
      }

      assert {:error, errors} = Validator.validate_message(message)
      assert Enum.any?(errors, &String.contains?(&1, "role must be one of"))
    end

    test "message missing parts fails validation" do
      message = %{
        role: :user,
        parts: []
      }

      assert {:error, errors} = Validator.validate_message(message)
      assert "Message must have at least one content part" in errors
    end

    test "message with negative position fails validation" do
      message = %{
        role: :user,
        position: -1,
        parts: [%{type: :text, text: "Hello"}]
      }

      assert {:error, errors} = Validator.validate_message(message)
      assert Enum.any?(errors, &String.contains?(&1, "position"))
    end
  end

  describe "validate_part/1 - TextPart" do
    test "valid text part passes validation" do
      part = %{type: :text, text: "Hello, world!"}

      assert :ok = Validator.validate_part(part)
    end

    test "text part missing text fails validation" do
      part = %{type: :text}

      assert {:error, errors} = Validator.validate_part(part)
      assert "TextPart must have non-empty text" in errors
    end

    test "text part with empty text fails validation" do
      part = %{type: :text, text: ""}

      assert {:error, errors} = Validator.validate_part(part)
      assert "TextPart must have non-empty text" in errors
    end
  end

  describe "validate_part/1 - ImageURLPart" do
    test "valid image url part passes validation" do
      part = %{type: :image_url, url: "https://example.com/image.png"}

      assert :ok = Validator.validate_part(part)
    end

    test "image url part missing url fails validation" do
      part = %{type: :image_url}

      assert {:error, errors} = Validator.validate_part(part)
      assert "ImageURLPart must have url" in errors
    end
  end

  describe "validate_part/1 - ImagePart" do
    test "valid image part passes validation" do
      part = %{
        type: :image,
        media_type: "image/png",
        payload: "base64encodeddata"
      }

      assert :ok = Validator.validate_part(part)
    end

    test "image part missing mediaType fails validation" do
      part = %{type: :image, payload: "data"}

      assert {:error, errors} = Validator.validate_part(part)
      assert "ImagePart must have mediaType" in errors
    end

    test "image part with non-image mediaType fails validation" do
      part = %{type: :image, media_type: "text/plain", payload: "data"}

      assert {:error, errors} = Validator.validate_part(part)
      assert Enum.any?(errors, &String.contains?(&1, "must start with 'image/'"))
    end

    test "image part missing payload fails validation" do
      part = %{type: :image, media_type: "image/png"}

      assert {:error, errors} = Validator.validate_part(part)
      assert "ImagePart must have payload" in errors
    end
  end

  describe "validate_part/1 - ToolCallPart" do
    test "valid tool call part passes validation" do
      part = %{
        type: :tool_call,
        tool_name: "get_weather",
        arguments_json: ~s({"location": "NYC"})
      }

      assert :ok = Validator.validate_part(part)
    end

    test "tool call part missing toolName fails validation" do
      part = %{type: :tool_call, arguments_json: "{}"}

      assert {:error, errors} = Validator.validate_part(part)
      assert Enum.any?(errors, &String.contains?(&1, "toolName"))
    end

    test "tool call part missing argumentsJson fails validation" do
      part = %{type: :tool_call, tool_name: "get_weather"}

      assert {:error, errors} = Validator.validate_part(part)
      assert Enum.any?(errors, &String.contains?(&1, "argumentsJson"))
    end
  end

  describe "validate_part/1 - ToolResultPart" do
    test "valid tool result part passes validation" do
      part = %{
        type: :tool_result,
        tool_call_id: "call_123",
        result_json: ~s({"temp": 72})
      }

      assert :ok = Validator.validate_part(part)
    end

    test "tool result part missing toolCallId fails validation" do
      part = %{type: :tool_result, result_json: "{}"}

      assert {:error, errors} = Validator.validate_part(part)
      assert Enum.any?(errors, &String.contains?(&1, "toolCallId"))
    end

    test "tool result part missing resultJson fails validation" do
      part = %{type: :tool_result, tool_call_id: "call_123"}

      assert {:error, errors} = Validator.validate_part(part)
      assert Enum.any?(errors, &String.contains?(&1, "resultJson"))
    end
  end

  describe "validate_usage/1" do
    test "valid usage passes validation" do
      usage = %{
        input_tokens: 100,
        output_tokens: 50,
        reasoning_tokens: 10,
        total_tokens: 160,
        input_cost: 0.001,
        output_cost: 0.002,
        total_cost: 0.003
      }

      assert :ok = Validator.validate_usage(usage)
    end

    test "usage with negative input_tokens fails validation" do
      usage = %{input_tokens: -10}

      assert {:error, errors} = Validator.validate_usage(usage)
      assert Enum.any?(errors, &String.contains?(&1, "inputTokens"))
    end

    test "usage with negative costs fails validation" do
      usage = %{
        input_tokens: 10,
        input_cost: -0.001
      }

      assert {:error, errors} = Validator.validate_usage(usage)
      assert Enum.any?(errors, &String.contains?(&1, "inputCost"))
    end

    test "usage with non-integer tokens fails validation" do
      usage = %{input_tokens: 10.5}

      assert {:error, errors} = Validator.validate_usage(usage)
      assert Enum.any?(errors, &String.contains?(&1, "inputTokens"))
    end
  end

  describe "integration with Emitter" do
    test "emitted valid response passes validation" do
      response = %{
        id: "resp_123",
        finish_reason: :stop,
        context: %{
          messages: [
            %{role: :user, parts: [%{type: :text, text: "Hello"}]},
            %{role: :assistant, parts: [%{type: :text, text: "Hi there!"}]}
          ]
        },
        message: %{
          role: :assistant,
          parts: [%{type: :text, text: "Hi there!"}]
        },
        usage: %{
          input_tokens: 10,
          output_tokens: 5,
          total_tokens: 15
        }
      }

      # Emit to JSON-LD
      jsonld = Emitter.emit_response(response, inline_context?: false)

      # Should be able to validate the original structure
      assert :ok = Validator.validate_response(response)
    end

    test "emitted tool call message passes validation" do
      message = %{
        role: :assistant,
        parts: [
          %{
            type: :tool_call,
            tool_name: "get_weather",
            arguments_json: ~s({"location": "San Francisco"})
          }
        ]
      }

      jsonld = Emitter.emit_message(message, strip: false)

      assert :ok = Validator.validate_message(message)
    end
  end

  describe "round-trip validation" do
    test "complex response validates after round-trip through emitter" do
      response = %{
        id: "resp_complex",
        finish_reason: :tool_calls,
        context: %{
          external_id: "session_456",
          messages: [
            %{
              role: :user,
              position: 0,
              parts: [
                %{type: :text, text: "What's the weather?"},
                %{type: :image_url, url: "https://example.com/map.png"}
              ]
            },
            %{
              role: :assistant,
              position: 1,
              parts: [
                %{
                  type: :tool_call,
                  tool_name: "get_weather",
                  arguments_json: ~s({"location": "NYC"})
                }
              ]
            }
          ]
        },
        message: %{
          role: :assistant,
          parts: [
            %{
              type: :tool_call,
              tool_name: "get_weather",
              arguments_json: ~s({"location": "NYC"})
            }
          ]
        },
        usage: %{
          input_tokens: 150,
          output_tokens: 25,
          reasoning_tokens: 5,
          total_tokens: 180,
          input_cost: 0.0015,
          output_cost: 0.0005,
          total_cost: 0.0020
        }
      }

      # Validate before emission
      assert :ok = Validator.validate_response(response)

      # Emit to JSON-LD
      jsonld = Emitter.emit_response(response, inline_context?: false)

      # Ensure JSON-LD was created
      assert is_map(jsonld)
      assert jsonld["@type"] == "Response"
    end
  end
end
