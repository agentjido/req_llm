defmodule ReqLLM.Providers.GoogleVertex.AnthropicObjectTest do
  use ExUnit.Case, async: true

  @moduletag category: :core
  @moduletag provider: :anthropic

  alias ReqLLM.Providers.GoogleVertex.Anthropic, as: VertexAnthropic

  @schema %{
    "type" => "object",
    "properties" => %{
      "question" => %{"type" => "string"},
      "options" => %{
        "type" => "array",
        "items" => %{"type" => "string"},
        "minItems" => 4,
        "maxItems" => 4
      }
    },
    "required" => ["options", "question"],
    "additionalProperties" => true,
    "propertyOrdering" => ["options", "question"]
  }

  defp build_body(extra_opts) do
    {:ok, compiled} = ReqLLM.Schema.compile(@schema)
    context = ReqLLM.Context.new([ReqLLM.Context.user("translate")])

    opts =
      [operation: :object, compiled_schema: compiled, model: "claude-opus-4-6"] ++ extra_opts

    VertexAnthropic.format_request("claude-opus-4-6", context, opts)
  end

  defp tool_names(body), do: Enum.map(body[:tools] || [], &(&1[:name] || &1["name"]))

  describe "format_request/3 for :object" do
    test "json_schema mode emits output_config.format and no structured_output tool" do
      body = build_body(anthropic_structured_output_mode: :json_schema)

      assert get_in(body, [:output_config, :format, :type]) == "json_schema"

      options = get_in(body, [:output_config, :format, :schema])["properties"]["options"]
      refute Map.has_key?(options, "maxItems")
      assert get_in(body, [:output_config, :format, :schema])["additionalProperties"] == false

      refute "structured_output" in tool_names(body)
    end

    test "default mode injects a structured_output tool and no output_config" do
      body = build_body([])

      refute Map.has_key?(body, :output_config)
      assert "structured_output" in tool_names(body)
    end
  end

  describe "decode_response/1 forwards the structured-output mode" do
    @object %{"question" => "q", "options" => ["a", "b", "c", "d"]}

    defp decode(extra_options) do
      model = %LLMDB.Model{
        id: "claude-opus-4-6",
        provider: :google_vertex,
        capabilities: %{chat: true}
      }

      body = %{
        "id" => "msg_1",
        "type" => "message",
        "role" => "assistant",
        "model" => "claude-opus-4-6",
        "content" => [%{"type" => "text", "text" => JSON.encode!(@object)}],
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
      }

      request =
        Req.new()
        |> Req.Request.put_private(:model, model)

      request = %{request | options: Map.new([operation: :object] ++ extra_options)}

      {_req, %Req.Response{body: decoded}} =
        ReqLLM.Providers.GoogleVertex.decode_response(
          {request, %Req.Response{status: 200, body: body}}
        )

      decoded
    end

    test "json_schema mode parses the object from response text" do
      assert decode(anthropic_structured_output_mode: :json_schema).object == @object
    end

    test "without the mode forwarded the json_schema text is not parsed (tool path → nil)" do
      assert decode([]).object == nil
    end
  end
end
