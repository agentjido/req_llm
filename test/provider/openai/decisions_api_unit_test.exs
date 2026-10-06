defmodule Provider.OpenAI.DecisionsAPIUnitTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Providers.OpenAI.DecisionsAPI

  @questions %{
    urgent: %{type: :boolean, instructions: "Is this urgent?"},
    department: %{
      type: :choice,
      instructions: "Which team should handle this?",
      criteria: %{support: "Other requests", billing: "Billing and refunds"}
    },
    severity: %{
      type: :score,
      instructions: "How severe is this?",
      criteria: ["low", "medium", "high"]
    }
  }

  test "uses the Decisions endpoint" do
    assert DecisionsAPI.path() == "/decisions"
  end

  test "compiles stable JSON state and name-sorted questions" do
    first = %{"z" => [%{"b" => 2, "a" => 1}], a: true}
    second = %{"z" => [%{"a" => 1, "b" => 2}], a: true}

    assert {:ok, body, contract} =
             DecisionsAPI.compile_request("gpt-6-luna", first, @questions, "tenant-123")

    assert {:ok, body2, _contract} =
             DecisionsAPI.compile_request("gpt-6-luna", second, @questions, "tenant-123")

    assert body["input"] == ~s({"a":true,"z":[{"a":1,"b":2}]})
    assert body2["input"] == body["input"]
    assert body["model"] == "gpt-6-luna"
    assert body["safety_identifier"] == "tenant-123"
    assert Enum.map(body["questions"], & &1["name"]) == ["department", "severity", "urgent"]
    assert Enum.map(body["questions"], & &1["type"]) == ["choice", "score", "predicate"]

    assert hd(body["questions"])["choices"] == [
             %{"description" => "Billing and refunds", "value" => "billing"},
             %{"description" => "Other requests", "value" => "support"}
           ]

    assert Enum.at(body["questions"], 1)["levels"] == [
             %{"label" => "low"},
             %{"label" => "medium"},
             %{"label" => "high"}
           ]

    assert Enum.map(contract, & &1.name) == ["department", "severity", "urgent"]
  end

  test "passes string state unchanged and omits an absent safety identifier" do
    assert {:ok, body, _contract} =
             DecisionsAPI.compile_request("gpt-6-luna", "raw text", @questions, nil)

    assert body["input"] == "raw text"
    refute Map.has_key?(body, "safety_identifier")
  end

  test "rejects normalized state, question, and choice collisions" do
    assert {:error, %ReqLLM.Error.Invalid.Parameter{parameter: state_message}} =
             DecisionsAPI.compile_request(
               "gpt-6-luna",
               %{"risk" => 2, risk: 1},
               @questions,
               nil
             )

    assert state_message =~ "state object key collision"

    assert {:error, %ReqLLM.Error.Invalid.Parameter{parameter: question_message}} =
             DecisionsAPI.compile_request(
               "gpt-6-luna",
               "text",
               %{"risk" => @questions.urgent, risk: @questions.urgent},
               nil
             )

    assert question_message =~ "question name collision"

    choice = %{
      type: :choice,
      instructions: "Choose",
      criteria: %{"yes" => "String", yes: "Atom"}
    }

    assert {:error, %ReqLLM.Error.Invalid.Parameter{parameter: choice_message}} =
             DecisionsAPI.compile_request("gpt-6-luna", "text", %{answer: choice}, nil)

    assert choice_message =~ "choice value collision"
  end

  test "rejects invalid question shapes and safety identifiers" do
    invalid = %{bad: %{type: :choice, instructions: "Choose", criteria: []}}

    assert {:error, %ReqLLM.Error.Invalid.Parameter{}} =
             DecisionsAPI.compile_request("gpt-6-luna", "text", invalid, nil)

    assert {:error, %ReqLLM.Error.Invalid.Parameter{parameter: message}} =
             DecisionsAPI.compile_request(
               "gpt-6-luna",
               "text",
               @questions,
               String.duplicate("a", 129)
             )

    assert message =~ "safety_identifier"
  end

  test "encodes a compiled request body" do
    assert {:ok, body, contract} =
             DecisionsAPI.compile_request("gpt-6-luna", "text", @questions, nil)

    request = %Req.Request{
      options: %{decisions_body: body},
      private: %{req_llm_openai_decisions: contract}
    }

    encoded = DecisionsAPI.encode_body(request)
    assert Jason.decode!(encoded.body) == body
  end

  test "strict decoding accepts typed answers and refusals" do
    questions = %{
      accepted: %{
        type: :choice,
        instructions: "Accept?",
        criteria: %{true => "Accept", false => "Reject"}
      },
      severity: @questions.severity,
      urgent: @questions.urgent
    }

    assert {:ok, _body, contract} =
             DecisionsAPI.compile_request("gpt-6-luna", "text", questions, nil)

    body = %{
      "model" => "gpt-6-luna",
      "answers" => [
        %{
          "name" => "accepted",
          "type" => "choice",
          "choice" => true,
          "confidence" => 0.9,
          "probabilities" => [
            %{"value" => false, "probability" => 0.1},
            %{"value" => true, "probability" => 0.9}
          ]
        },
        %{"name" => "severity", "type" => "refusal", "reason" => "policy"},
        %{"name" => "urgent", "type" => "predicate", "probability" => 0.75}
      ],
      "usage" => %{"input_tokens" => 8, "output_tokens" => 3},
      "future_field" => %{"kept" => true}
    }

    {_req, response} = DecisionsAPI.decode_response(build_response(body, contract))

    assert %Req.Response{body: result} = response
    assert result.object["accepted"]["choice"] == true
    assert result.object["severity"] == %{"type" => "refusal"}
    assert result.object["urgent"] == %{"type" => "boolean", "probability" => 0.75}
    assert result.provider_meta.raw_response["future_field"] == %{"kept" => true}
  end

  test "strict decoding rejects count, order, type, and allowed-value mismatches" do
    assert {:ok, _body, contract} =
             DecisionsAPI.compile_request("gpt-6-luna", "text", @questions, nil)

    matching = matching_answers()

    for answers <- [
          Enum.drop(matching, -1),
          Enum.reverse(matching),
          List.update_at(matching, 0, &Map.put(&1, "type", "score")),
          List.update_at(matching, 0, &Map.put(&1, "choice", "unknown")),
          List.update_at(matching, 1, &Map.put(&1, "score", 10.0))
        ] do
      {_req, error} =
        DecisionsAPI.decode_response(
          build_response(
            %{
              "model" => "gpt-6-luna",
              "answers" => answers,
              "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
            },
            contract
          )
        )

      assert %ReqLLM.Error.API.Response{} = error
    end
  end

  test "structural decoding accepts valid raw data and rejects duplicate names" do
    body = %{
      "model" => "gpt-6-luna",
      "answers" => matching_answers(),
      "usage" => %{"input_tokens" => 4, "output_tokens" => 2}
    }

    {_req, response} = DecisionsAPI.decode_response(build_response(body, nil))
    assert %Req.Response{body: %ReqLLM.Response{} = result} = response
    assert Map.keys(result.object) |> Enum.sort() == ["department", "severity", "urgent"]

    duplicate = %{body | "answers" => [hd(body["answers"]), hd(body["answers"])]}
    {_req, error} = DecisionsAPI.decode_response(build_response(duplicate, nil))
    assert %ReqLLM.Error.API.Response{} = error
  end

  test "reports provider errors and rejects streaming" do
    req = %Req.Request{options: %{}, private: %{}}
    resp = %Req.Response{status: 429, body: %{"error" => %{"message" => "limited"}}}
    {_req, error} = DecisionsAPI.decode_response({req, resp})
    assert %ReqLLM.Error.API.Response{status: 429} = error

    model = %LLMDB.Model{provider: :openai, id: "gpt-6-luna"}
    assert DecisionsAPI.decode_stream_event(%{}, model) == []

    assert {:error, %ReqLLM.Error.Invalid.Parameter{parameter: message}} =
             DecisionsAPI.attach_stream(model, ReqLLM.Context.new(), [], :finch)

    assert message =~ "streaming"
  end

  defp matching_answers do
    [
      %{
        "name" => "department",
        "type" => "choice",
        "choice" => "billing",
        "confidence" => 0.8,
        "probabilities" => [
          %{"value" => "billing", "probability" => 0.8},
          %{"value" => "support", "probability" => 0.2}
        ]
      },
      %{
        "name" => "severity",
        "type" => "score",
        "score" => 1.0,
        "confidence" => 0.7,
        "probabilities" => [
          %{"label" => "low", "value" => 0, "probability" => 0.1},
          %{"label" => "medium", "value" => 1, "probability" => 0.7},
          %{"label" => "high", "value" => 2, "probability" => 0.2}
        ]
      },
      %{"name" => "urgent", "type" => "predicate", "probability" => 0.75}
    ]
  end

  defp build_response(body, contract) do
    private = if contract, do: %{req_llm_openai_decisions: contract}, else: %{}
    req = %Req.Request{options: %{model: "gpt-6-luna"}, private: private}
    {req, %Req.Response{status: 200, headers: %{}, body: body}}
  end
end
