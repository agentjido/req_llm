defmodule ReqLLM.Providers.OpenAICodex.ResponsesLiteTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Providers.OpenAICodex.ResponsesLite

  describe "enabled?/1" do
    test "uses the bundled Codex model catalog for known Responses Lite models" do
      for id <- ~w(gpt-5.6-sol gpt-5.6-terra gpt-5.6-luna) do
        assert id |> model() |> ResponsesLite.enabled?()
      end

      refute "gpt-5.6" |> model() |> ResponsesLite.enabled?()
      refute "gpt-5.5" |> model() |> ResponsesLite.enabled?()
    end

    test "provider-specific model metadata overrides the bundled catalog" do
      refute "gpt-5.6-sol"
             |> model(%{openai_codex: %{use_responses_lite: false}})
             |> ResponsesLite.enabled?()

      assert "custom-codex-model"
             |> model(%{"openai_codex" => %{"use_responses_lite" => true}})
             |> ResponsesLite.enabled?()
    end
  end

  describe "apply_body/2" do
    test "applies the complete Responses Lite request contract" do
      body = %{
        "model" => "gpt-5.6-sol",
        "instructions" => "Be concise.",
        "input" => [
          %{
            "type" => "message",
            "role" => "user",
            "content" => [
              %{
                "type" => "input_image",
                "image_url" => "data:image/png;base64,abc",
                "detail" => "high"
              },
              %{"type" => "input_text", "text" => "Describe this image"}
            ]
          }
        ],
        "tools" => [
          %{
            "type" => "function",
            "name" => "lookup",
            "parameters" => %{"type" => "object"}
          }
        ],
        "parallel_tool_calls" => true,
        "previous_response_id" => "resp_previous",
        "reasoning" => %{"effort" => "high"}
      }

      transformed = ResponsesLite.apply_body(body, model("gpt-5.6-sol"))

      refute Map.has_key?(transformed, "instructions")
      refute Map.has_key?(transformed, "tools")
      refute Map.has_key?(transformed, "previous_response_id")
      assert transformed["parallel_tool_calls"] == false
      assert transformed["reasoning"] == %{"effort" => "high", "context" => "all_turns"}

      assert [additional_tools, developer_instructions, user_message] = transformed["input"]

      assert additional_tools == %{
               "type" => "additional_tools",
               "role" => "developer",
               "tools" => body["tools"]
             }

      assert developer_instructions == %{
               "type" => "message",
               "role" => "developer",
               "content" => [%{"type" => "input_text", "text" => "Be concise."}]
             }

      assert [%{"type" => "input_image"} = image, %{"type" => "input_text"}] =
               user_message["content"]

      refute Map.has_key?(image, "detail")
    end

    test "leaves non-Lite requests unchanged" do
      body = %{"instructions" => "Be concise.", "input" => [], "parallel_tool_calls" => true}

      assert ResponsesLite.apply_body(body, model("gpt-5.5")) == body
    end

    test "keeps client-executed tools and omits provider-hosted tools" do
      body = %{
        "tools" => [
          %{"type" => "web_search"},
          %{"type" => "image_generation"},
          %{"type" => :file_search},
          %{type: :code_interpreter},
          %{"type" => "function", "name" => "lookup"}
        ]
      }

      transformed = ResponsesLite.apply_body(body, model("gpt-5.6-sol"))

      assert [%{"type" => "additional_tools", "tools" => tools}] = transformed["input"]
      assert tools == [%{"type" => "function", "name" => "lookup"}]
    end

    test "replaces remote images and preserves data images without detail" do
      body = %{
        "input" => [
          %{
            "type" => "message",
            "role" => "user",
            "content" => [
              %{
                "type" => "input_image",
                "image_url" => "https://example.com/image.png",
                "detail" => "high"
              },
              %{
                "type" => "input_image",
                "image_url" => "data:image/png;base64,abc",
                "detail" => "original"
              }
            ]
          }
        ]
      }

      transformed = ResponsesLite.apply_body(body, model("gpt-5.6-sol"))
      [_additional_tools, user_message] = transformed["input"]

      assert [omission, data_image] = user_message["content"]

      assert omission == %{
               "type" => "input_text",
               "text" => "image content omitted because remote image URLs are not supported"
             }

      assert data_image == %{
               "type" => "input_image",
               "image_url" => "data:image/png;base64,abc"
             }
    end
  end

  defp model(id, extra \\ %{}) do
    ReqLLM.model!(%{provider: :openai_codex, id: id, extra: extra})
  end
end
