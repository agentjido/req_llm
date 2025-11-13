defmodule ReqLLM.Providers.GoogleRoleFixTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Context
  alias ReqLLM.Providers.Google

  describe "role conversion for Gemini" do
    test "converts assistant role to model in encoded messages" do
      # Create a context with assistant messages
      context =
        Context.new([
          Context.user("Hello"),
          Context.assistant("Hi there! How can I help you?"),
          Context.user("What's 2+2?"),
          Context.assistant("2+2 equals 4")
        ])

      # Create a mock request with the context
      request = %Req.Request{
        options: %{
          context: context,
          id: "gemini-1.5-flash"
        }
      }

      # Call the encode_body function to get the Gemini-formatted body
      updated_request = Google.encode_body(request)
      body = Jason.decode!(updated_request.body)

      # Check that the contents have the correct roles
      contents = body["contents"]

      # Verify we have the expected messages
      assert length(contents) == 4

      # Check each message's role
      assert Enum.at(contents, 0)["role"] == "user"

      assert Enum.at(contents, 1)["role"] == "model",
             "Assistant role should be converted to 'model'"

      assert Enum.at(contents, 2)["role"] == "user"

      assert Enum.at(contents, 3)["role"] == "model",
             "Assistant role should be converted to 'model'"

      # Ensure no 'assistant' role remains
      refute Enum.any?(contents, fn msg -> msg["role"] == "assistant" end),
             "No 'assistant' role should remain in Gemini format"
    end

    test "handles system messages separately" do
      context =
        Context.new([
          Context.system("You are a helpful assistant"),
          Context.user("Hello"),
          Context.assistant("Hi there!")
        ])

      request = %Req.Request{
        options: %{
          context: context,
          id: "gemini-1.5-flash"
        }
      }

      updated_request = Google.encode_body(request)
      body = Jason.decode!(updated_request.body)

      # System instruction should be separate
      assert body["systemInstruction"]["parts"] == [%{"text" => "You are a helpful assistant"}]

      # Contents should only have user and model messages
      contents = body["contents"]
      assert length(contents) == 2
      assert Enum.at(contents, 0)["role"] == "user"
      assert Enum.at(contents, 1)["role"] == "model"
    end

    test "handles messages with different content formats" do
      # Test with string content and list content
      messages = [
        %{"role" => "user", "content" => "Hello"},
        %{"role" => "assistant", "content" => [%{"type" => "text", "text" => "Hi!"}]},
        %{"role" => "user", "content" => "How are you?"},
        %{"role" => "assistant", "content" => "I'm doing well, thanks!"}
      ]

      request = %Req.Request{
        options: %{
          messages: messages,
          id: "gemini-1.5-flash"
        }
      }

      updated_request = Google.encode_body(request)
      body = Jason.decode!(updated_request.body)

      contents = body["contents"]

      # All assistant messages should be converted to model
      assert Enum.at(contents, 1)["role"] == "model"
      assert Enum.at(contents, 3)["role"] == "model"

      # Content should be preserved
      assert Enum.at(contents, 1)["parts"] == [%{"text" => "Hi!"}]
      assert Enum.at(contents, 3)["parts"] == [%{"text" => "I'm doing well, thanks!"}]
    end
  end
end
