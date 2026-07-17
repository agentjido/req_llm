defmodule ReqLLM.ToolCallTest do
  use ExUnit.Case, async: true

  @moduletag contract: :public_api

  alias ReqLLM.{Tool, ToolCall}

  describe "new/3" do
    test "creates a ToolCall with provided id" do
      tool_call = ToolCall.new("call_123", "get_weather", ~s({"location":"Paris"}))

      assert tool_call.id == "call_123"
      assert tool_call.type == "function"
      assert tool_call.function.name == "get_weather"
      assert tool_call.function.arguments == ~s({"location":"Paris"})
    end

    test "generates an id when nil is provided" do
      tool_call = ToolCall.new(nil, "get_weather", ~s({"location":"Paris"}))

      assert String.starts_with?(tool_call.id, "call_")
      assert tool_call.type == "function"
      assert tool_call.function.name == "get_weather"
    end

    test "accepts empty arguments" do
      tool_call = ToolCall.new("call_456", "no_args", "{}")

      assert tool_call.function.arguments == "{}"
    end
  end

  describe "new_builtin/3 and builtin?/1" do
    test "creates builtin tool calls and detects them" do
      tool_call = ToolCall.new_builtin("ws_1", "web_search_call", ~s({"query":"elixir"}))

      assert tool_call.id == "ws_1"
      assert tool_call.function.name == "web_search_call"
      assert tool_call.function.arguments == ~s({"query":"elixir"})
      assert ToolCall.builtin?(tool_call)
    end

    test "detects builtin flags in maps" do
      assert ToolCall.builtin?(%{builtin?: true})
      assert ToolCall.builtin?(%{"builtin?" => true})
      assert ToolCall.builtin?(%{function: %{builtin?: true}})
      assert ToolCall.builtin?(%{"function" => %{"builtin?" => true}})
      refute ToolCall.builtin?(%{function: %{name: "get_weather"}})
    end
  end

  describe "flagged_builtin?/1" do
    test "checks the flag on the given map without unwrapping :function" do
      assert ToolCall.flagged_builtin?(%{builtin?: true})
      assert ToolCall.flagged_builtin?(%{"builtin?" => true})
      refute ToolCall.flagged_builtin?(%{function: %{builtin?: true}})
      refute ToolCall.flagged_builtin?(%{builtin?: false})
      refute ToolCall.flagged_builtin?(%{})
      refute ToolCall.flagged_builtin?(nil)
    end
  end

  describe "builtin_flag?/1 (deprecated alias)" do
    test "delegates to flagged_builtin?/1" do
      assert ToolCall.builtin_flag?(%{builtin?: true}) ==
               ToolCall.flagged_builtin?(%{builtin?: true})

      refute ToolCall.builtin_flag?(%{function: %{builtin?: true}})
    end
  end

  describe "name/1" do
    test "extracts function name from ToolCall" do
      tool_call = ToolCall.new("call_123", "get_weather", "{}")

      assert ToolCall.name(tool_call) == "get_weather"
    end
  end

  describe "args_json/1" do
    test "extracts arguments JSON string from ToolCall" do
      args = ~s({"location":"SF","unit":"celsius"})
      tool_call = ToolCall.new("call_123", "get_weather", args)

      assert ToolCall.args_json(tool_call) == args
    end

    test "returns empty object string for empty arguments" do
      tool_call = ToolCall.new("call_123", "no_args", "{}")

      assert ToolCall.args_json(tool_call) == "{}"
    end
  end

  describe "to_map/1" do
    test "converts ToolCall to flat map with decoded arguments" do
      tool_call = ToolCall.new("call_123", "get_weather", ~s({"location":"Paris"}))
      result = ToolCall.to_map(tool_call)

      assert result == %{id: "call_123", name: "get_weather", arguments: %{"location" => "Paris"}}
    end

    test "returns empty map for invalid JSON arguments" do
      tool_call = ToolCall.new("call_123", "broken", "invalid json")
      result = ToolCall.to_map(tool_call)

      assert result == %{id: "call_123", name: "broken", arguments: %{}}
    end

    test "handles empty arguments" do
      tool_call = ToolCall.new("call_456", "no_args", "{}")
      result = ToolCall.to_map(tool_call)

      assert result == %{id: "call_456", name: "no_args", arguments: %{}}
    end

    test "includes attached metadata" do
      tool_call =
        "call_123"
        |> ToolCall.new("search", ~s({"query":"docs"}))
        |> ToolCall.put_metadata(%{thought_signature: "sig_123"})

      assert ToolCall.to_map(tool_call) == %{
               id: "call_123",
               name: "search",
               arguments: %{"query" => "docs"},
               metadata: %{thought_signature: "sig_123"}
             }
    end
  end

  describe "put_metadata/2" do
    test "merges metadata into existing metadata" do
      tool_call =
        "call_123"
        |> ToolCall.new("search", "{}")
        |> ToolCall.put_metadata(%{thought_signature: "sig_123"})
        |> ToolCall.put_metadata(%{raw_arguments: "{}"})

      assert ToolCall.metadata(tool_call) == %{
               thought_signature: "sig_123",
               raw_arguments: "{}"
             }
    end
  end

  describe "provider_native?/1" do
    test "recognizes provider-native metadata without changing wire encoding" do
      tool_call =
        "call_123"
        |> ToolCall.new("web_search", ~s({"query":"docs"}))
        |> ToolCall.put_metadata(%{provider_native: :example, request_id: "req_123"})

      assert ToolCall.provider_native?(tool_call)
      assert ToolCall.metadata(tool_call).request_id == "req_123"

      decoded = tool_call |> Jason.encode!() |> Jason.decode!()
      refute Map.has_key?(decoded["function"], "metadata")
      refute Map.has_key?(decoded["function"], "provider_native")
    end

    test "does not confuse provider-executed builtins with provider-native metadata" do
      builtin = ToolCall.new_builtin("call_123", "web_search", "{}")

      assert ToolCall.builtin?(builtin)
      refute ToolCall.provider_native?(builtin)
    end
  end

  describe "resolve/3 and execute/3" do
    setup do
      parent = self()

      tool =
        Tool.new!(
          name: "search",
          description: "Search documents",
          parameter_schema: [
            query: [type: :string, required: true],
            limit: [type: :integer, default: 5]
          ],
          callback: fn args ->
            send(parent, {:tool_executed, args})
            {:ok, %{matches: args.limit}}
          end
        )

      %{tool: tool}
    end

    test "resolves raw, decoded, and validated arguments without executing", %{tool: tool} do
      raw_arguments = ~s({"query":"elixir"})

      call =
        "call_valid"
        |> ToolCall.new("search", raw_arguments)
        |> ToolCall.put_metadata(%{provider_request_id: "req_123"})

      assert %{
               state: :valid,
               call: ^call,
               id: "call_valid",
               name: "search",
               tool: ^tool,
               raw_arguments: ^raw_arguments,
               arguments: %{"query" => "elixir"},
               validated_arguments: %{query: "elixir", limit: 5},
               metadata: %{provider_request_id: "req_123"},
               error: nil
             } = ToolCall.resolve(call, [tool])

      refute_received {:tool_executed, _args}
    end

    test "executes one valid call with the existing callback contract", %{tool: tool} do
      call = ToolCall.new("call_valid", "search", ~s({"query":"elixir"}))

      assert {:ok, %{matches: 5}} = ToolCall.execute(call, [tool])
      assert_received {:tool_executed, %{query: "elixir", limit: 5}}
      refute_received {:tool_executed, _args}
    end

    test "preserves callback error values" do
      tool =
        Tool.new!(
          name: "restricted",
          description: "Restricted tool",
          callback: fn _args -> {:error, :permission_denied} end
        )

      call = ToolCall.new("call_error", "restricted", "{}")

      assert {:error, :permission_denied} = ToolCall.execute(call, [tool])
    end

    test "keeps invalid schema input inspectable and does not execute", %{tool: tool} do
      call = ToolCall.new("call_invalid", "search", ~s({"limit":"many"}))

      assert %{
               state: :invalid,
               call: ^call,
               raw_arguments: ~s({"limit":"many"}),
               arguments: %{"limit" => "many"},
               validated_arguments: nil,
               error: %ReqLLM.Error.Validation.Error{}
             } = resolution = ToolCall.resolve(call, [tool])

      assert {:error,
              %{
                state: :invalid,
                call: ^call,
                arguments: %{"limit" => "many"},
                error: %ReqLLM.Error.Validation.Error{}
              }} = ToolCall.execute(call, [tool])

      assert resolution.state == :invalid
      refute_received {:tool_executed, _args}
    end

    test "keeps malformed arguments inspectable and honors JSON repair options", %{tool: tool} do
      call = ToolCall.new("call_invalid_json", "search", ~s({"query":"elixir",}))

      assert %{state: :valid, arguments: %{"query" => "elixir"}} =
               ToolCall.resolve(call, [tool])

      assert %{
               state: :invalid,
               call: ^call,
               raw_arguments: ~s({"query":"elixir",}),
               arguments: nil,
               validated_arguments: nil,
               error: %Jason.DecodeError{}
             } = ToolCall.resolve(call, [tool], json_repair: false)

      assert {:error, %{state: :invalid}} =
               ToolCall.execute(call, [tool], json_repair: false)

      refute_received {:tool_executed, _args}
    end

    test "rejects arguments that decode to a non-map", %{tool: tool} do
      call = ToolCall.new("call_array", "search", ~s(["elixir"]))

      assert %{
               state: :invalid,
               call: ^call,
               raw_arguments: ~s(["elixir"]),
               arguments: nil,
               validated_arguments: nil,
               error: %ReqLLM.Error.Invalid.Parameter{}
             } = resolution = ToolCall.resolve(call, [tool])

      assert Exception.message(resolution.error) =~ "must decode to a map"
      assert {:error, %{state: :invalid}} = ToolCall.execute(call, [tool])
      refute_received {:tool_executed, _args}
    end

    test "keeps unknown calls inspectable and does not execute another tool", %{tool: tool} do
      call = ToolCall.new("call_unknown", "missing", ~s({"query":"elixir"}))

      assert %{
               state: :unknown,
               call: ^call,
               name: "missing",
               tool: nil,
               raw_arguments: ~s({"query":"elixir"}),
               arguments: %{"query" => "elixir"},
               validated_arguments: nil,
               error: %ReqLLM.Error.Invalid.Parameter{}
             } = resolution = ToolCall.resolve(call, [tool])

      assert Exception.message(resolution.error) =~ ~s(Tool "missing" not found)

      assert {:error,
              %{
                state: :unknown,
                call: ^call,
                arguments: %{"query" => "elixir"},
                error: %ReqLLM.Error.Invalid.Parameter{}
              }} = ToolCall.execute(call, [tool])

      refute_received {:tool_executed, _args}
    end

    test "classifies provider-executed builtins before application tools", %{tool: tool} do
      call = ToolCall.new_builtin("call_builtin", "search", ~s({"query":"elixir"}))

      assert %{
               state: :provider_executed,
               call: ^call,
               tool: nil,
               raw_arguments: ~s({"query":"elixir"}),
               arguments: %{"query" => "elixir"},
               validated_arguments: nil,
               metadata: %{},
               error: nil
             } = resolution = ToolCall.resolve(call, [tool])

      assert {:error, ^resolution} = ToolCall.execute(call, [tool])
      refute_received {:tool_executed, _args}
    end

    test "classifies provider-native calls and preserves provider metadata", %{tool: tool} do
      call =
        "call_native"
        |> ToolCall.new("search", ~s({"query":"elixir"}))
        |> ToolCall.put_metadata(%{
          provider_native: :example,
          provider_payload: %{request_id: "req_native"}
        })

      assert %{
               state: :provider_native,
               call: ^call,
               tool: nil,
               arguments: %{"query" => "elixir"},
               validated_arguments: nil,
               metadata: %{
                 provider_native: :example,
                 provider_payload: %{request_id: "req_native"}
               },
               error: nil
             } = resolution = ToolCall.resolve(call, [tool])

      assert {:error, ^resolution} = ToolCall.execute(call, [tool])
      refute_received {:tool_executed, _args}
    end

    test "keeps multiple calls independent and executes each callback once", %{tool: tool} do
      calls = [
        ToolCall.new("call_1", "search", ~s({"query":"one"})),
        ToolCall.new("call_2", "search", ~s({"query":"two","limit":2}))
      ]

      assert Enum.map(calls, &ToolCall.execute(&1, [tool])) == [
               {:ok, %{matches: 5}},
               {:ok, %{matches: 2}}
             ]

      assert_received {:tool_executed, %{query: "one", limit: 5}}
      assert_received {:tool_executed, %{query: "two", limit: 2}}
      refute_received {:tool_executed, _args}
    end
  end

  describe "args_map/1" do
    test "decodes valid JSON arguments to map" do
      args = ~s({"location":"Paris","unit":"celsius"})
      tool_call = ToolCall.new("call_123", "get_weather", args)

      assert ToolCall.args_map(tool_call) == %{"location" => "Paris", "unit" => "celsius"}
    end

    test "returns nil for invalid JSON" do
      tool_call = ToolCall.new("call_123", "broken", "invalid json")

      assert ToolCall.args_map(tool_call) == nil
    end

    test "decodes empty object" do
      tool_call = ToolCall.new("call_123", "no_args", "{}")

      assert ToolCall.args_map(tool_call) == %{}
    end

    test "handles nested JSON structures" do
      args = ~s({"location":{"city":"Paris","country":"France"},"unit":"celsius"})
      tool_call = ToolCall.new("call_123", "get_weather", args)

      assert ToolCall.args_map(tool_call) == %{
               "location" => %{"city" => "Paris", "country" => "France"},
               "unit" => "celsius"
             }
    end

    test "repairs lightly malformed JSON by default" do
      tool_call = ToolCall.new("call_123", "structured_output", ~s({"name":"Ada",}))

      assert ToolCall.args_map(tool_call) == %{"name" => "Ada"}
    end

    test "allows JSON repair to be disabled" do
      tool_call = ToolCall.new("call_123", "structured_output", ~s({"name":"Ada",}))

      assert ToolCall.args_map(tool_call, json_repair: false) == nil
    end
  end

  describe "matches_name?/2" do
    test "returns true when name matches" do
      tool_call = ToolCall.new("call_123", "get_weather", "{}")

      assert ToolCall.matches_name?(tool_call, "get_weather") == true
    end

    test "returns false when name does not match" do
      tool_call = ToolCall.new("call_123", "get_weather", "{}")

      assert ToolCall.matches_name?(tool_call, "get_time") == false
    end

    test "is case-sensitive" do
      tool_call = ToolCall.new("call_123", "get_weather", "{}")

      assert ToolCall.matches_name?(tool_call, "Get_Weather") == false
    end
  end

  describe "find_args/2" do
    setup do
      tool_calls = [
        ToolCall.new("call_1", "get_weather", ~s({"location":"Paris"})),
        ToolCall.new("call_2", "get_time", ~s({"timezone":"UTC"})),
        ToolCall.new("call_3", "structured_output", ~s({"name":"John","age":30}))
      ]

      {:ok, tool_calls: tool_calls}
    end

    test "finds and decodes arguments for matching tool call", %{tool_calls: tool_calls} do
      result = ToolCall.find_args(tool_calls, "get_weather")

      assert result == %{"location" => "Paris"}
    end

    test "finds first matching tool call when multiple exist", %{tool_calls: tool_calls} do
      duplicate_calls = tool_calls ++ [ToolCall.new("call_4", "get_time", ~s({"timezone":"PST"}))]

      result = ToolCall.find_args(duplicate_calls, "get_time")

      assert result == %{"timezone" => "UTC"}
    end

    test "returns nil when no matching tool call found", %{tool_calls: tool_calls} do
      result = ToolCall.find_args(tool_calls, "nonexistent_function")

      assert result == nil
    end

    test "returns nil when arguments cannot be decoded" do
      tool_calls = [ToolCall.new("call_1", "broken", "invalid json")]

      result = ToolCall.find_args(tool_calls, "broken")

      assert result == nil
    end

    test "works with empty list" do
      result = ToolCall.find_args([], "any_function")

      assert result == nil
    end

    test "finds structured_output tool call", %{tool_calls: tool_calls} do
      result = ToolCall.find_args(tool_calls, "structured_output")

      assert result == %{"name" => "John", "age" => 30}
    end

    test "respects JSON repair options" do
      tool_calls = [ToolCall.new("call_1", "structured_output", ~s({"name":"Ada",}))]

      assert ToolCall.find_args(tool_calls, "structured_output") == %{"name" => "Ada"}
      assert ToolCall.find_args(tool_calls, "structured_output", json_repair: false) == nil
    end
  end

  describe "Jason.Encoder implementation" do
    test "encodes ToolCall to JSON" do
      tool_call = ToolCall.new("call_123", "get_weather", ~s({"location":"Paris"}))
      json = Jason.encode!(tool_call)

      assert json =~ ~s("id":"call_123")
      assert json =~ ~s("type":"function")
      assert json =~ ~s("name":"get_weather")
      assert json =~ ~s("arguments":"{\\"location\\":\\"Paris\\"}")
    end

    test "decodes back to map with correct structure" do
      tool_call = ToolCall.new("call_456", "get_time", ~s({"timezone":"UTC"}))
      json = Jason.encode!(tool_call)
      decoded = Jason.decode!(json)

      assert decoded["id"] == "call_456"
      assert decoded["type"] == "function"
      assert decoded["function"]["name"] == "get_time"
      assert decoded["function"]["arguments"] == ~s({"timezone":"UTC"})
      refute Map.has_key?(decoded["function"], "builtin?")
    end

    test "preserves builtin marker when encoding" do
      tool_call = ToolCall.new_builtin("ws_1", "web_search_call", ~s({"query":"elixir"}))
      decoded = tool_call |> Jason.encode!() |> Jason.decode!()

      assert decoded["function"]["builtin?"] == true
      assert ToolCall.builtin?(decoded)
    end

    test "does not encode local metadata" do
      decoded =
        "call_123"
        |> ToolCall.new("search", ~s({"query":"docs"}))
        |> ToolCall.put_metadata(%{thought_signature: "sig_123"})
        |> Jason.encode!()
        |> Jason.decode!()

      refute Map.has_key?(decoded["function"], "metadata")
    end
  end

  describe "from_map/1" do
    test "converts a ToolCall struct (delegates to to_map)" do
      tool_call = ToolCall.new("call_123", "get_weather", ~s({"location":"Paris"}))
      result = ToolCall.from_map(tool_call)

      assert result == %{id: "call_123", name: "get_weather", arguments: %{"location" => "Paris"}}
    end

    test "converts a map with string keys" do
      map = %{"id" => "call_456", "name" => "get_time", "arguments" => ~s({"timezone":"UTC"})}
      result = ToolCall.from_map(map)

      assert result == %{id: "call_456", name: "get_time", arguments: %{"timezone" => "UTC"}}
    end

    test "converts a map with atom keys" do
      map = %{id: "call_789", name: "search", arguments: %{"query" => "elixir"}}
      result = ToolCall.from_map(map)

      assert result == %{id: "call_789", name: "search", arguments: %{"query" => "elixir"}}
    end

    test "parses JSON string arguments" do
      map = %{id: "call_abc", name: "calc", arguments: ~s({"x":1,"y":2})}
      result = ToolCall.from_map(map)

      assert result == %{id: "call_abc", name: "calc", arguments: %{"x" => 1, "y" => 2}}
    end

    test "generates id when missing" do
      map = %{"name" => "no_id_func", "arguments" => "{}"}
      result = ToolCall.from_map(map)

      assert String.starts_with?(result.id, "call_")
      assert result.name == "no_id_func"
      assert result.arguments == %{}
    end

    test "handles missing arguments" do
      map = %{id: "call_xyz", name: "no_args"}
      result = ToolCall.from_map(map)

      assert result == %{id: "call_xyz", name: "no_args", arguments: %{}}
    end

    test "handles invalid JSON arguments" do
      map = %{id: "call_bad", name: "broken", arguments: "not valid json"}
      result = ToolCall.from_map(map)

      assert result == %{id: "call_bad", name: "broken", arguments: %{}}
    end

    test "preserves map metadata" do
      map = %{
        id: "call_meta",
        name: "search",
        arguments: %{"query" => "docs"},
        metadata: %{thought_signature: "sig_123"}
      }

      assert ToolCall.from_map(map) == %{
               id: "call_meta",
               name: "search",
               arguments: %{"query" => "docs"},
               metadata: %{thought_signature: "sig_123"}
             }
    end
  end

  describe "Inspect implementation" do
    test "provides readable inspection format" do
      tool_call = ToolCall.new("call_123", "get_weather", ~s({"location":"Paris"}))
      inspected = inspect(tool_call)

      assert inspected == ~s[#ToolCall<call_123: get_weather({"location":"Paris"})>]
    end

    test "shows empty arguments" do
      tool_call = ToolCall.new("call_456", "no_args", "{}")
      inspected = inspect(tool_call)

      assert inspected == "#ToolCall<call_456: no_args({})>"
    end
  end
end
