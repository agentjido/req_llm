defmodule ReqLLM.PropertyOrderingWireTest do
  @moduledoc """
  Verifies that propertyOrdering annotations are consumed during encoding,
  producing ordered JSON on the wire and stripping the annotation key.

  Tests the actual encoded JSON string (not intermediate maps) to confirm
  that structured output schema properties appear in declared order for
  providers that rely on JSON key order (OpenAI, Anthropic) and that
  Google retains the annotation as-is.
  """

  use ExUnit.Case, async: true

  alias ReqLLM.Providers.Anthropic
  alias ReqLLM.Providers.OpenAI.ChatAPI
  alias ReqLLM.Providers.OpenAI.ResponsesAPI

  @multi_prop_schema [
    reasoning: [type: :string, required: true, doc: "Reasoning"],
    answer: [type: :string, required: true, doc: "Answer"],
    confidence: [type: :integer, doc: "Confidence score"]
  ]

  @expected_order ["reasoning", "answer", "confidence"]

  # -- OpenAI Responses API ---------------------------------------------------

  describe "OpenAI Responses API structured output wire order" do
    test "schema properties are ordered on the wire" do
      response_format = %{
        type: "json_schema",
        json_schema: %{
          name: "analysis",
          strict: true,
          schema: @multi_prop_schema
        }
      }

      request = build_responses_request(provider_options: [response_format: response_format])
      encoded = ResponsesAPI.encode_body(request)

      assert_no_property_ordering(encoded.body)

      assert ordered_prop_keys(encoded.body, ["text", "format", "schema", "properties"]) ==
               @expected_order
    end
  end

  # -- OpenAI Chat API --------------------------------------------------------

  describe "OpenAI Chat API structured output wire order" do
    test "response_format json_schema properties are ordered on the wire" do
      context = %ReqLLM.Context{
        messages: [%ReqLLM.Message{role: :user, content: "test"}]
      }

      response_format = %{
        type: "json_schema",
        json_schema: %{
          name: "analysis",
          strict: true,
          schema: @multi_prop_schema
        }
      }

      request = %Req.Request{
        method: :post,
        url: URI.parse("https://api.openai.com/v1/chat/completions"),
        headers: %{},
        body: nil,
        options: %{
          context: context,
          model: "gpt-4o",
          operation: :chat,
          stream: false,
          provider_options: [response_format: response_format]
        }
      }

      encoded = ChatAPI.encode_body(request)

      assert_no_property_ordering(encoded.body)

      assert ordered_prop_keys(
               encoded.body,
               ["response_format", "json_schema", "schema", "properties"]
             ) == @expected_order
    end
  end

  # -- Anthropic --------------------------------------------------------------

  describe "Anthropic structured output wire order" do
    test "output_format json_schema properties are ordered on the wire" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")
      json_schema = ReqLLM.Schema.to_json(@multi_prop_schema)

      context = %ReqLLM.Context{
        messages: [%ReqLLM.Message{role: :user, content: "test"}]
      }

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          provider_options: [
            output_format: %{
              type: "json_schema",
              schema: json_schema
            }
          ]
        ]
      }

      updated = Anthropic.encode_body(mock_request)

      assert_no_property_ordering(updated.body)

      assert ordered_prop_keys(updated.body, ["output_format", "schema", "properties"]) ==
               @expected_order
    end
  end

  # -- Default encode_body_from_map path (covers many providers) --------------

  describe "encode_body_from_map structured output wire order" do
    test "properties are ordered in response_format schema" do
      body = %{
        model: "test-model",
        response_format: %{
          "type" => "json_schema",
          "json_schema" => %{
            "name" => "analysis",
            "schema" => ReqLLM.Schema.to_json(@multi_prop_schema)
          }
        }
      }

      request = %Req.Request{
        method: :post,
        url: URI.parse("https://example.com"),
        headers: %{},
        body: nil,
        options: %{}
      }

      encoded = ReqLLM.Provider.Defaults.encode_body_from_map(request, body)

      assert_no_property_ordering(encoded.body)

      assert ordered_prop_keys(
               encoded.body,
               ["response_format", "json_schema", "schema", "properties"]
             ) == @expected_order
    end

    test "properties are ordered for raw atom-key schemas" do
      body = %{
        model: "test-model",
        response_format: %{
          type: "json_schema",
          json_schema: %{
            name: "analysis",
            schema: %{
              type: "object",
              properties: %{
                reasoning: %{"type" => "string"},
                answer: %{"type" => "string"},
                confidence: %{"type" => "integer"}
              },
              propertyOrdering: @expected_order
            }
          }
        }
      }

      request = %Req.Request{
        method: :post,
        url: URI.parse("https://example.com"),
        headers: %{},
        body: nil,
        options: %{}
      }

      encoded = ReqLLM.Provider.Defaults.encode_body_from_map(request, body)

      assert_no_property_ordering(encoded.body)

      assert ordered_prop_keys(
               encoded.body,
               ["response_format", "json_schema", "schema", "properties"]
             ) == @expected_order
    end
  end

  # -- Google (should retain propertyOrdering) --------------------------------

  describe "Google retains propertyOrdering" do
    test "propertyOrdering annotation is preserved in schema" do
      schema = ReqLLM.Schema.to_json(@multi_prop_schema)

      assert schema["propertyOrdering"] == @expected_order

      json = Jason.encode!(schema)
      decoded = Jason.decode!(json)

      assert decoded["propertyOrdering"] == @expected_order
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp ordered_prop_keys(json, path) do
    ordered = Jason.decode!(json, objects: :ordered_objects)

    node =
      Enum.reduce(path, ordered, fn
        key, acc when is_binary(key) -> find_ordered_value(acc, key)
        idx, acc when is_integer(idx) -> Enum.at(acc, idx)
      end)

    case node do
      %Jason.OrderedObject{values: values} -> Enum.map(values, fn {k, _} -> k end)
      _ -> flunk("Expected ordered properties at path #{inspect(path)}, got: #{inspect(node)}")
    end
  end

  defp find_ordered_value(%Jason.OrderedObject{values: values}, key) do
    Enum.find_value(values, fn {k, v} -> if k == key, do: v end)
  end

  defp find_ordered_value(%{} = map, key), do: Map.get(map, key)
  defp find_ordered_value(_, _), do: nil

  defp assert_no_property_ordering(json) do
    refute json =~ "propertyOrdering",
           "propertyOrdering should be stripped from wire JSON"
  end

  defp build_responses_request(opts) do
    context = Keyword.get(opts, :context, %ReqLLM.Context{messages: []})
    provider_opts = Keyword.get(opts, :provider_options, [])

    req_opts = %{
      id: Keyword.get(opts, :id, "gpt-5"),
      context: context,
      stream: Keyword.get(opts, :stream),
      tools: Keyword.get(opts, :tools),
      provider_options: provider_opts
    }

    %Req.Request{
      method: :post,
      url: URI.parse("https://api.openai.com/v1/responses"),
      headers: %{},
      body: {:json, %{}},
      options: req_opts
    }
  end
end
