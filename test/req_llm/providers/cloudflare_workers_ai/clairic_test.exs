defmodule ReqLLM.Providers.CloudflareWorkersAI.ClairicTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Providers.CloudflareWorkersAI.Clairic
  alias ReqLLM.Response

  @account_id "0123456789abcdef0123456789abcdef"
  @state "Invoice INV-7 from Northwind Supply. Total due: $0.00."
  @fields %{
    invoice_id: %{type: :text, instructions: "The invoice identifier."},
    total: %{type: :number, instructions: "The total amount due.", decimals: 2},
    po_number: %{type: :text, instructions: "The purchase order number, if printed."}
  }
  @fixture Path.expand("../fixtures/cloudflare_workers_ai/clairic-flash.json", __DIR__)

  test "posts native fields and retains spans, zero, null and usage" do
    native = @fixture |> File.read!() |> Jason.decode!()
    envelope = %{"success" => true, "errors" => [], "result" => native}

    Req.Test.stub(__MODULE__.Extract, fn conn ->
      assert conn.method == "POST"

      assert conn.request_path ==
               "/client/v4/accounts/#{@account_id}/ai/run/@cf/cloudflare/clairic-flash"

      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer fixture-only"]
      assert conn.body_params["state"] == @state
      assert conn.body_params["model"] == "clairic-flash"
      assert conn.body_params["fields"]["invoice_id"]["type"] == "text"
      assert conn.body_params["fields"]["total"]["decimals"] == 2
      refute Map.has_key?(conn.body_params, "questions")
      Req.Test.json(conn, envelope)
    end)

    assert {:ok, %Response{} = response} =
             Clairic.extract("clairic-flash", @state, @fields, options(__MODULE__.Extract))

    assert response.object["invoice_id"]["value"] == "INV-7"
    assert response.object["invoice_id"]["span"] == [8, 13]
    assert response.object["total"]["value"] == 0
    assert response.object["po_number"]["value"] == nil
    assert response.object["po_number"]["valid"]
    assert is_number(response.object["po_number"]["p_null"])
    assert response.usage.input_tokens == native["usage"]["input_tokens"]
    assert response.provider_meta.raw_response == envelope
  end

  test "preserves an incomplete field for the caller to handle" do
    answer = %{"type" => "text", "value" => nil, "valid" => false, "complete" => false}

    Req.Test.stub(__MODULE__.Incomplete, fn conn ->
      Req.Test.json(conn, %{
        "result" => %{
          "model" => "clairic",
          "answers" => %{"invoice_id" => answer},
          "usage" => %{},
          "truncated" => true
        }
      })
    end)

    assert {:ok, %Response{object: %{"invoice_id" => ^answer}}} =
             Clairic.extract(
               "clairic",
               @state,
               Map.take(@fields, [:invoice_id]),
               options(__MODULE__.Incomplete)
             )
  end

  test "reports failed and malformed Workers AI responses" do
    for body <- [
          %{"success" => false, "errors" => [%{"message" => "Request failed"}]},
          %{
            "success" => true,
            "result" => %{"model" => "clairic", "usage" => %{}, "answers" => %{}}
          },
          %{
            "success" => true,
            "result" => %{
              "model" => "clairic",
              "usage" => %{},
              "answers" => %{"invoice_id" => %{"type" => "number", "value" => 0}}
            }
          }
        ] do
      Req.Test.stub(__MODULE__.Invalid, fn conn -> Req.Test.json(conn, body) end)

      assert {:error, error} =
               Clairic.extract(
                 "clairic",
                 @state,
                 Map.take(@fields, [:invoice_id]),
                 options(__MODULE__.Invalid)
               )

      assert Exception.message(error) =~ "Invalid or unsuccessful Clairic extraction response"
    end
  end

  test "rejects malformed account IDs, unsupported fields and colliding names before HTTP" do
    opts = [
      account_id: @account_id,
      api_key: "fixture-only",
      req_http_options: [plug: fn _conn -> flunk("unexpected HTTP") end]
    ]

    for {fields, call_opts} <- [
          {@fields, Keyword.put(opts, :account_id, "../other")},
          {%{due: %{type: "date"}}, opts},
          {%{"invoice_id" => %{type: "text"}, invoice_id: %{type: "text"}}, opts}
        ] do
      assert {:error, %ReqLLM.Error.Invalid.Parameter{}} =
               Clairic.extract("clairic", @state, fields, call_opts)
    end
  end

  test "preserves the HTTP status of a Workers AI error" do
    Req.Test.stub(__MODULE__.Unauthorized, fn conn ->
      conn
      |> Plug.Conn.put_status(401)
      |> Req.Test.json(%{"success" => false, "errors" => [%{"message" => "Unauthorized"}]})
    end)

    assert {:error, %{status: 401}} =
             Clairic.extract("clairic", @state, @fields, options(__MODULE__.Unauthorized))
  end

  defp options(stub) do
    [
      account_id: @account_id,
      api_key: "fixture-only",
      max_retries: 0,
      req_http_options: [plug: {Req.Test, stub}]
    ]
  end
end
