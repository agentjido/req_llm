defmodule ReqLLM.EvaluationAnswerValidationTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Error.API.Request, as: RequestError
  alias ReqLLM.Error.API.Response, as: ResponseError
  alias ReqLLM.Response

  @questions %{
    department: %{
      type: :choice,
      instructions: "Which team should handle this?",
      criteria: %{billing: "Billing and refunds", support: "Other requests"}
    },
    severity: %{
      type: :score,
      instructions: "How severe is this?",
      criteria: ["low", "medium", "high"]
    },
    urgent: %{type: :boolean, instructions: "Is this urgent?"}
  }

  test "strict validation rejects an out-of-rubric choice and leaves default decoding intact" do
    answer = %{"type" => "choice", "choice" => "outside"}
    opts = strict_fixture_options(%{"department" => answer})
    questions = Map.take(@questions, [:department])

    for model <- ["typesafe:jev-latest", "openrouter:typesafe/jev-1.13"] do
      assert {:ok, %Response{object: %{"department" => ^answer}}} =
               ReqLLM.evaluate(model, "Please refund me", questions, opts)

      assert {:error, %RequestError{cause: %ResponseError{reason: reason}}} =
               ReqLLM.evaluate(
                 model,
                 "Please refund me",
                 questions,
                 [answer_validation: :strict] ++ opts
               )

      assert reason =~ "Choice was not in the submitted criteria"
    end
  end

  test "strict validation checks missing, mismatched, and invalid known answers" do
    for {field, answers, expected} <- [
          {:urgent, %{}, "Answer is missing"},
          {:urgent, %{"urgent" => %{"type" => "score", "score" => 0}},
           "Expected a boolean answer"},
          {:urgent, %{"urgent" => %{"type" => "noul", "noul" => 1.1}},
           "Probability must be in [0, 1]"},
          {:severity, %{"severity" => %{"type" => "score", "score" => 2.5}}, "Score is outside"},
          {:department,
           %{"department" => %{"type" => "choice", "choice" => "billing", "confidence" => -0.1}},
           "Confidence must be in [0, 1]"},
          {:department,
           %{
             "department" => %{
               "type" => "choice",
               "choice" => "billing",
               "probabilities" => %{"billing" => "high"}
             }
           }, "Probabilities must be in [0, 1]"}
        ] do
      opts = [answer_validation: :strict] ++ strict_fixture_options(answers)

      assert {:error, %RequestError{cause: %ResponseError{reason: reason}}} =
               ReqLLM.evaluate(
                 "typesafe:jev-latest",
                 "Please refund me",
                 Map.take(@questions, [field]),
                 opts
               )

      assert reason =~ expected
    end
  end

  test "strict validation accepts ordered criteria and preserves provider extensions" do
    questions = %{
      department: %{
        @questions.department
        | criteria: Jason.OrderedObject.new([{"support", "Other"}, {"billing", "Payments"}])
      }
    }

    answers = %{
      "department" => %{"type" => "choice", "choice" => "billing", "provider_detail" => true},
      "extension" => %{"type" => "future", "value" => 0}
    }

    opts = [answer_validation: :strict] ++ strict_fixture_options(answers)

    assert {:ok, %Response{object: ^answers}} =
             ReqLLM.evaluate("typesafe:jev-latest", "Please refund me", questions, opts)
  end

  test "strict validation matches Choice keys as encoded in JSON" do
    criteria = %{1 => "Billing", nil => "Other"}

    for model <- ["typesafe:jev-latest", "openrouter:typesafe/jev-1.13"],
        criteria <- [criteria, Jason.OrderedObject.new(Map.to_list(criteria))],
        choice <- ["1", "nil"] do
      questions = %{department: %{@questions.department | criteria: criteria}}
      answers = %{"department" => %{"type" => "choice", "choice" => choice}}

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        assert get_in(Jason.decode!(body), ["questions", "department", "criteria"]) == %{
                 "1" => "Billing",
                 "nil" => "Other"
               }

        Req.Test.json(conn, %{"model" => "jev-latest", "answers" => answers, "usage" => %{}})
      end

      assert {:ok, %Response{object: ^answers}} =
               ReqLLM.evaluate(model, "Please refund me", questions,
                 api_key: "fixture-only",
                 answer_validation: :strict,
                 req_http_options: [plug: plug]
               )
    end
  end

  test "strict validation is explicit about supported wire protocols" do
    assert {:error, %ReqLLM.Error.Invalid.Parameter{parameter: message}} =
             ReqLLM.evaluate("openai:gpt-6-luna", "Please refund me", @questions,
               answer_validation: :strict,
               req_http_options: [plug: fn _conn -> flunk("unexpected HTTP") end]
             )

    assert message =~ "strict answer validation requires"
  end

  defp strict_fixture_options(answers) do
    plug = fn conn ->
      Req.Test.json(conn, %{"model" => "jev-latest", "answers" => answers, "usage" => %{}})
    end

    [api_key: "fixture-only", req_http_options: [plug: plug]]
  end
end
