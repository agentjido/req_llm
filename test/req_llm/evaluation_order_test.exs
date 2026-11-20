defmodule ReqLLM.EvaluationOrderTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Response

  test "preserves explicitly ordered System One Choice criteria in the request JSON" do
    criteria = Jason.OrderedObject.new([{"z_billing", "Billing"}, {"a_support", "Support"}])
    questions = %{department: %{type: :choice, instructions: "Which team?", criteria: criteria}}

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert body =~ ~s("criteria":{"z_billing":"Billing","a_support":"Support"})

      Req.Test.json(conn, %{
        "model" => "jev-latest",
        "answers" => %{"department" => %{"type" => "choice", "choice" => "z_billing"}},
        "usage" => %{}
      })
    end

    assert {:ok, %Response{object: %{"department" => %{"choice" => "z_billing"}}}} =
             ReqLLM.evaluate("typesafe:jev-latest", "Please refund me", questions,
               api_key: "fixture-only",
               req_http_options: [plug: plug]
             )
  end
end
