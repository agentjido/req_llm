defmodule ReqLLM.Providers.Google.HistoryCompatibilityTest do
  @moduledoc """
  Google context compatibility for role merging and assistant tool history.
  """

  use ReqLLM.ProviderCase, provider: ReqLLM.Providers.Google, async: true

  alias ReqLLM.Context
  alias ReqLLM.Providers.Google

  describe "error handling & robustness" do
    test "context validation allows multiple system messages" do
      context =
        Context.new([
          Context.system("System 1"),
          Context.system("System 2"),
          Context.user("Hello")
        ])

      assert ^context = Context.validate!(context)
    end
  end

  describe "consecutive role merging for parallel tool results" do
    test "encode_body merges multiple tool results into a single user entry" do
      {:ok, model} = ReqLLM.model("google:gemini-1.5-flash")

      context =
        Context.new([
          Context.user("What's the weather in SF and NYC?"),
          Context.assistant("",
            tool_calls: [
              %ReqLLM.ToolCall{
                id: "call_1",
                type: "function",
                function: %{name: "get_weather", arguments: ~s({"location":"SF"})}
              },
              %ReqLLM.ToolCall{
                id: "call_2",
                type: "function",
                function: %{name: "get_weather", arguments: ~s({"location":"NYC"})}
              }
            ]
          ),
          Context.tool_result("call_1", "get_weather", "72F sunny"),
          Context.tool_result("call_2", "get_weather", "58F cloudy")
        ])

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          operation: :chat
        ]
      }

      updated_request = Google.encode_body(mock_request)
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)
      contents = decoded["contents"]

      tool_result_entries =
        Enum.filter(contents, fn entry ->
          Enum.any?(entry["parts"], &Map.has_key?(&1, "functionResponse"))
        end)

      assert length(tool_result_entries) == 1,
             "Expected tool results merged into 1 entry, got #{length(tool_result_entries)}"

      [merged] = tool_result_entries
      fn_parts = Enum.filter(merged["parts"], &Map.has_key?(&1, "functionResponse"))
      assert length(fn_parts) == 2

      names = Enum.map(fn_parts, & &1["functionResponse"]["name"])
      assert "get_weather" in names
    end

    test "encode_body preserves non-consecutive same-role entries separately" do
      {:ok, model} = ReqLLM.model("google:gemini-1.5-flash")

      context =
        Context.new([
          Context.user("Hello"),
          Context.assistant("Hi there!"),
          Context.user("How are you?")
        ])

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          operation: :chat
        ]
      }

      updated_request = Google.encode_body(mock_request)
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)
      contents = decoded["contents"]

      user_entries = Enum.filter(contents, &(&1["role"] == "user"))
      assert length(user_entries) == 2
    end
  end

  describe "tool-only assistant history" do
    test "omits synthetic empty text while preserving signed calls, reasoning and results" do
      weather_call =
        "call_weather"
        |> ReqLLM.ToolCall.new("get_weather", ~s({"location":"SF"}))
        |> ReqLLM.ToolCall.put_metadata(%{thought_signature: "weather_signature"})

      time_call =
        "call_time"
        |> ReqLLM.ToolCall.new("get_time", ~s({"location":"NYC"}))
        |> ReqLLM.ToolCall.put_metadata(%{thought_signature: "time_signature"})

      call_parts = [
        %{
          "functionCall" => %{"name" => "get_weather", "args" => %{"location" => "SF"}},
          "thoughtSignature" => "weather_signature"
        },
        %{
          "functionCall" => %{"name" => "get_time", "args" => %{"location" => "NYC"}},
          "thoughtSignature" => "time_signature"
        }
      ]

      reasoning = %ReqLLM.Message.ReasoningDetails{
        text: "Check both cities.",
        signature: "reasoning_signature",
        encrypted?: true,
        provider: :google,
        format: "google-gemini-v1",
        index: 0,
        provider_data: %{"thought" => true}
      }

      for reasoning_details <- [nil, [reasoning]] do
        assistant = %ReqLLM.Message{
          role: :assistant,
          content: [],
          tool_calls: [weather_call, time_call],
          reasoning_details: reasoning_details
        }

        context =
          Context.new([
            Context.user("Check SF weather and NYC time."),
            assistant,
            Context.tool_result("call_weather", "get_weather", "sunny"),
            Context.tool_result("call_time", "get_time", "noon")
          ])

        thought_parts =
          if reasoning_details do
            [
              %{
                "text" => "Check both cities.",
                "thought" => true,
                "thoughtSignature" => "reasoning_signature"
              }
            ]
          else
            []
          end

        for body <- google_chat_bodies(context) do
          assert body["contents"] == [
                   %{
                     "role" => "user",
                     "parts" => [%{"text" => "Check SF weather and NYC time."}]
                   },
                   %{"role" => "model", "parts" => thought_parts ++ call_parts},
                   %{
                     "role" => "user",
                     "parts" => [
                       %{
                         "functionResponse" => %{
                           "name" => "get_weather",
                           "response" => %{"content" => "sunny"}
                         }
                       },
                       %{
                         "functionResponse" => %{
                           "name" => "get_time",
                           "response" => %{"content" => "noon"}
                         }
                       }
                     ]
                   }
                 ]
        end
      end
    end

    test "preserves visible text and real empty text parts alongside tool calls" do
      call =
        "call_1"
        |> ReqLLM.ToolCall.new("get_weather", ~s({"location":"SF"}))
        |> ReqLLM.ToolCall.put_metadata(%{thought_signature: "call_signature"})

      visible = ReqLLM.Message.ContentPart.text("Checking.")
      empty = ReqLLM.Message.ContentPart.text("")

      for {content, text_parts} <- [
            {"Checking.", [%{"text" => "Checking."}]},
            {[empty, visible], [%{"text" => ""}, %{"text" => "Checking."}]}
          ] do
        context = Context.new([Context.assistant(content, tool_calls: [call])])

        for body <- google_chat_bodies(context) do
          assert body["contents"] == [
                   %{
                     "role" => "model",
                     "parts" =>
                       text_parts ++
                         [
                           %{
                             "functionCall" => %{
                               "name" => "get_weather",
                               "args" => %{"location" => "SF"}
                             },
                             "thoughtSignature" => "call_signature"
                           }
                         ]
                   }
                 ]
        end
      end
    end

    test "preserves empty text for ordinary user and non-tool assistant messages" do
      context = Context.new([Context.user(""), Context.assistant([])])

      for body <- google_chat_bodies(context) do
        assert body["contents"] == [
                 %{"role" => "user", "parts" => [%{"text" => ""}]},
                 %{"role" => "model", "parts" => [%{"text" => ""}]}
               ]
      end
    end
  end

  defp google_chat_bodies(context) do
    model = ReqLLM.model!("google:gemini-2.5-flash")
    opts = [api_key: "test"]

    {:ok, request} = Google.prepare_request(:chat, model, context, opts)
    body = request |> Google.encode_body() |> ReqLLM.Test.Helpers.json_body()
    {:ok, stream_request} = Google.attach_stream(model, context, opts, nil)

    [body, Jason.decode!(stream_request.body)]
  end
end
