defmodule ReqLLM.Providers.CerebrasTest do
  @moduledoc """
  Provider-level tests for Cerebras implementation.
  """

  use ReqLLM.ProviderCase, provider: ReqLLM.Providers.Cerebras

  alias ReqLLM.Providers.Cerebras

  describe "body encoding" do
    test "encode_body preserves atom tool_choice values" do
      {:ok, model} = ReqLLM.model("cerebras:gpt-oss-120b")
      context = context_fixture()

      tool =
        ReqLLM.Tool.new!(
          name: "specific_tool",
          description: "A specific tool",
          parameter_schema: [
            value: [type: :string, required: true, doc: "A value parameter"]
          ],
          callback: fn _ -> {:ok, "result"} end
        )

      for tool_choice <- [:auto, :none, :required] do
        mock_request = %Req.Request{
          options: [
            context: context,
            model: model.model,
            stream: false,
            tools: [tool],
            tool_choice: tool_choice
          ]
        }

        updated_request = Cerebras.encode_body(mock_request)
        assert_no_duplicate_json_keys(updated_request.body)
        decoded = Jason.decode!(updated_request.body)

        assert is_list(decoded["tools"])
        assert decoded["tool_choice"] == to_string(tool_choice)
      end
    end

    test "encode_body preserves function-specific tool_choice" do
      {:ok, model} = ReqLLM.model("cerebras:gpt-oss-120b")
      context = context_fixture()

      tool =
        ReqLLM.Tool.new!(
          name: "specific_tool",
          description: "A specific tool",
          parameter_schema: [
            value: [type: :string, required: true, doc: "A value parameter"]
          ],
          callback: fn _ -> {:ok, "result"} end
        )

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          tools: [tool],
          tool_choice: %{type: "function", function: %{name: "specific_tool"}}
        ]
      }

      updated_request = Cerebras.encode_body(mock_request)
      assert_no_duplicate_json_keys(updated_request.body)
      decoded = Jason.decode!(updated_request.body)

      assert decoded["tool_choice"] == %{
               "type" => "function",
               "function" => %{"name" => "specific_tool"}
             }
    end

    test "encode_body includes parallel_tool_calls when provided" do
      {:ok, model} = ReqLLM.model("cerebras:gpt-oss-120b")
      context = context_fixture()

      tool =
        ReqLLM.Tool.new!(
          name: "specific_tool",
          description: "A specific tool",
          parameter_schema: [
            value: [type: :string, required: true, doc: "A value parameter"]
          ],
          callback: fn _ -> {:ok, "result"} end
        )

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          tools: [tool],
          parallel_tool_calls: false
        ]
      }

      updated_request = Cerebras.encode_body(mock_request)
      assert_no_duplicate_json_keys(updated_request.body)
      decoded = Jason.decode!(updated_request.body)

      assert decoded["parallel_tool_calls"] == false
    end
  end
end
