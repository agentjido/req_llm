defmodule ReqLLM.Providers.Google.GroundingToolsTest do
  use ExUnit.Case, async: true

  alias ReqLLM.{Context, StreamResponse, StreamServer, Tool}
  alias ReqLLM.Providers.Google
  alias ReqLLM.Test.Helpers

  @grounding [google_grounding: %{enable: true}]
  @parts [
    %{"text" => "I need a location.", "thought" => true, "thoughtSignature" => "plan"},
    %{
      "toolCall" => %{
        "toolType" => "GOOGLE_SEARCH_WEB",
        "id" => "search-1",
        "args" => %{"queries" => ["northernmost US city"]}
      },
      "thoughtSignature" => "search"
    },
    %{
      "toolResponse" => %{
        "toolType" => "GOOGLE_SEARCH_WEB",
        "id" => "search-1",
        "response" => %{"search_suggestions" => "Utqiagvik"}
      },
      "thoughtSignature" => "result"
    },
    %{"text" => "I found the city.", "thoughtSignature" => "text"},
    %{
      "functionCall" => %{
        "id" => "weather-1",
        "name" => "weather",
        "args" => %{"city" => "Utqiagvik"}
      },
      "thoughtSignature" => "function"
    }
  ]

  setup do
    {:ok, tool} =
      Tool.new(
        name: "weather",
        description: "Get the weather",
        parameter_schema: [city: [type: :string, required: true]],
        callback: fn _args -> {:ok, %{temperature: 22}} end
      )

    %{
      model: LLMDB.Model.new!(%{provider: :google, id: "gemini-3-pro-preview"}),
      context: Context.new([Context.user("Find the northernmost US city and get its weather.")]),
      opts: [api_key: "test", provider_options: @grounding, tools: [tool]]
    }
  end

  test "combines grounding and function tools in buffered and streaming requests", setup do
    %{model: model, context: context, opts: opts} = setup

    for body <- request_bodies(model, context, opts) do
      assert [
               %{"google_search" => %{}},
               %{"functionDeclarations" => [%{"name" => "weather"}]}
             ] = body["tools"]

      assert body["toolConfig"]["includeServerSideToolInvocations"]
    end

    for body <- request_bodies(model, context, Keyword.put(opts, :tool_choice, :auto)) do
      assert body["toolConfig"] == %{
               "includeServerSideToolInvocations" => true,
               "functionCallingConfig" => %{"mode" => "VALIDATED"}
             }
    end

    older = LLMDB.Model.new!(%{provider: :google, id: "gemini-2.5-flash"})

    for {model, opts} <- [
          {older, opts},
          {model, Keyword.delete(opts, :tools)},
          {model, Keyword.delete(opts, :provider_options)},
          {model, Keyword.put(opts, :tool_choice, :none)}
        ],
        body <- request_bodies(model, context, opts) do
      refute get_in(body, ["toolConfig", "includeServerSideToolInvocations"])
    end
  end

  test "replays ordered Gemini parts and the native call ID after buffered and streamed turns",
       setup do
    assert_round_trip(setup, @parts)
  end

  test "replays the native call ID when Gemini calls the local function first", setup do
    assert_round_trip(setup, [List.last(@parts)])
  end

  defp assert_round_trip(%{model: model, context: context, opts: opts}, parts) do
    assert {:ok, request} = Google.prepare_request(:chat, model, context, opts)

    {_, %{body: buffered}} =
      Google.decode_response(
        {request, %Req.Response{status: 200, body: candidate(parts, "STOP")}}
      )

    assert {:ok, streamed} = stream_response(model, context, parts)

    for response <- [buffered, streamed] do
      assert response.finish_reason == :tool_calls
      assert [%{id: "weather-1", function: %{name: "weather"}}] = response.message.tool_calls
      assert List.last(response.context.messages) == response.message

      result = Context.tool_result("weather-1", "weather", %{temperature: 22})
      assert {:ok, continued} = Context.append_tool_exchange(response.context, response, [result])

      for body <- request_bodies(model, continued, opts) do
        assert [_, %{"role" => "model", "parts" => ^parts}, result_turn] = body["contents"]

        assert result_turn == %{
                 "role" => "user",
                 "parts" => [
                   %{
                     "functionResponse" => %{
                       "name" => "weather",
                       "id" => "weather-1",
                       "response" => %{"temperature" => 22}
                     }
                   }
                 ]
               }
      end
    end
  end

  defp request_bodies(model, context, opts) do
    assert {:ok, request} = Google.prepare_request(:chat, model, context, opts)
    assert {:ok, streamed} = Google.attach_stream(model, context, opts, nil)

    [request |> Google.encode_body() |> Helpers.json_body(), Jason.decode!(streamed.body)]
  end

  defp stream_response(model, context, parts) do
    server = ReqLLM.Test.StreamServerHelpers.start_server(provider_mod: Google, model: model)
    :ok = StreamServer.http_event(server, {:status, 200})
    :ok = StreamServer.http_event(server, {:headers, [{"content-type", "text/event-stream"}]})

    {early, [last]} = Enum.split(parts, -1)

    for body <- Enum.map(early, &candidate([&1])) ++ [candidate([last], "STOP")] do
      :ok = StreamServer.http_event(server, {:data, "data: #{Jason.encode!(body)}\n\n"})
    end

    :ok = StreamServer.http_event(server, :done)
    assert {:ok, metadata} = StreamServer.await_metadata(server)
    assert {:ok, handle} = StreamResponse.MetadataHandle.start_link(fn -> metadata end)

    stream =
      Stream.unfold(server, fn server ->
        case StreamServer.next(server) do
          {:ok, chunk} -> {chunk, server}
          :halt -> nil
        end
      end)

    StreamResponse.to_response(%StreamResponse{
      context: context,
      model: model,
      stream: stream,
      metadata_handle: handle,
      cancel: fn -> StreamServer.cancel(server) end
    })
  end

  defp candidate(parts, finish_reason \\ nil) do
    candidate = %{"content" => %{"role" => "model", "parts" => parts}}

    candidate =
      if finish_reason, do: Map.put(candidate, "finishReason", finish_reason), else: candidate

    %{"candidates" => [candidate]}
  end
end
