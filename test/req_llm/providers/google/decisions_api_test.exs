defmodule ReqLLM.Providers.Google.DecisionsAPITest do
  use ExUnit.Case, async: true

  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Providers.Google.DecisionsAPI

  @model %{
    provider: :google,
    id: "gemini-decision-1",
    capabilities: %{chat: false, evaluate: true},
    cost: %{input: 0.1, output: 0.0},
    pricing: %{
      currency: "USD",
      components: [
        %{id: "token.input", kind: "token", per: 1_000_000, rate: 0.1},
        %{id: "token.output", kind: "token", per: 1_000_000, rate: 0.0}
      ]
    },
    execution: %{
      evaluate: %{
        supported: true,
        family: "google_decisions",
        wire_protocol: "google_decisions",
        transport: "http",
        path: "/decisions",
        provider_model_id: "gemini-decision-1"
      }
    }
  }
  @questions %{
    damaged: %{
      type: :boolean,
      instructions: "Is the item damaged?",
      criteria: %{true_description: "Broken item", false_description: "Intact item"}
    },
    team: %{
      type: :choice,
      instructions: "Which team should handle this?",
      criteria: %{billing: "Payment problems", support: "Product problems"}
    },
    severity: %{
      type: :score,
      instructions: "How severe is the problem?",
      criteria: ["Minor", "Major", "Critical"]
    }
  }

  test "evaluates all question types through the public API with Google authentication and usage" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.host == "generativelanguage.googleapis.com"
      assert conn.request_path == "/v1beta/decisions"
      assert conn.query_string == ""
      assert Plug.Conn.get_req_header(conn, "x-goog-api-key") == ["test-key"]
      assert Plug.Conn.get_req_header(conn, "authorization") == []
      assert conn.body_params["model"] == "gemini-decision-1"
      assert conn.body_params["input"] == "My mug arrived broken"
      assert conn.body_params["questions"]["damaged"]["type"] == "noul"

      assert conn.body_params["questions"]["damaged"]["criteria"] == %{
               "true_description" => "Broken item",
               "false_description" => "Intact item"
             }

      assert conn.body_params["questions"]["team"]["criteria"]["support"] == "Product problems"

      assert conn.body_params["questions"]["severity"]["criteria"] == [
               "Minor",
               "Major",
               "Critical"
             ]

      assert Enum.sort(Map.keys(conn.body_params)) == ["input", "model", "questions"]
      Req.Test.json(conn, response_body())
    end)

    for model <- [@model, ReqLLM.model!(@model)] do
      assert {:ok, result} =
               ReqLLM.evaluate(model, "My mug arrived broken", @questions, options())

      assert result.model == "gemini-decision-1"

      assert result.object["damaged"] == %{
               "type" => "boolean",
               "probability" => 0.95,
               "confidence" => 0.95
             }

      assert result.object["team"]["choice"] == "support"
      assert result.object["team"]["probabilities"] == %{"billing" => 0.1, "support" => 0.9}
      assert result.object["severity"]["score"] == 1.6
      assert result.object["severity"]["legend"]["2"] == "Critical"
      assert result.message == nil
      assert result.provider_meta.operation == :evaluate
      assert result.provider_meta.provider == :google
      assert result.provider_meta.raw_response == response_body()
      assert result.usage.input_tokens == 100
      assert result.usage.output_tokens == 0
      assert result.usage.total_tokens == 100
      assert_in_delta result.usage.input_cost, 0.00001, 0.000000001
      assert result.usage.output_cost == 0.0
    end
  end

  test "serializes JSON states as text rather than interpreting them as media blocks" do
    for state <- [%{type: "image", uri: "plain-data"}, ["a", %{value: 2}]] do
      Req.Test.stub(__MODULE__, fn conn ->
        assert Jason.decode!(conn.body_params["input"]) == Jason.decode!(Jason.encode!(state))
        Req.Test.json(conn, response_body())
      end)

      assert {:ok, _} = ReqLLM.evaluate(@model, state, @questions, options())
    end
  end

  test "encodes text, image, audio, video, and PDF input without generating chat contents" do
    context =
      ReqLLM.Context.new([
        ReqLLM.Context.user([
          ContentPart.text("Inspect these files.\n"),
          ContentPart.image(<<0, 1, 2>>, "image/png", %{resolution: :low}),
          ContentPart.image_url("https://example.com/photo.jpg"),
          ContentPart.file("audio-bytes", "clip.wav", "audio/wav"),
          ContentPart.video_url("https://example.com/clip.mp4", %{resolution: "medium"}),
          ContentPart.file("pdf-bytes", "report.pdf", "application/pdf"),
          ContentPart.file_id("https://generativelanguage.googleapis.com/v1beta/files/example")
        ])
      ])

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.body_params["input"] == [
               %{"type" => "text", "text" => "Inspect these files.\n"},
               %{
                 "type" => "image",
                 "data" => "AAEC",
                 "mime_type" => "image/png",
                 "resolution" => "low"
               },
               %{
                 "type" => "image",
                 "uri" => "https://example.com/photo.jpg",
                 "mime_type" => "image/jpeg"
               },
               %{
                 "type" => "audio",
                 "data" => Base.encode64("audio-bytes"),
                 "mime_type" => "audio/wav"
               },
               %{
                 "type" => "video",
                 "uri" => "https://example.com/clip.mp4",
                 "mime_type" => "video/mp4",
                 "resolution" => "medium"
               },
               %{
                 "type" => "document",
                 "data" => Base.encode64("pdf-bytes"),
                 "mime_type" => "application/pdf"
               },
               %{
                 "type" => "document",
                 "uri" => "https://generativelanguage.googleapis.com/v1beta/files/example",
                 "mime_type" => "application/pdf"
               }
             ]

      refute Map.has_key?(conn.body_params, "contents")
      Req.Test.json(conn, response_body())
    end)

    assert {:ok, _} = ReqLLM.evaluate(@model, context, @questions, options())
  end

  test "honors endpoint overrides and the explicit query authentication option" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.host == "proxy.example"
      assert conn.request_path == "/gateway/v1beta/custom-decisions"
      assert URI.decode_query(conn.query_string) == %{"key" => "test-key"}
      assert Plug.Conn.get_req_header(conn, "x-goog-api-key") == []
      Req.Test.json(conn, response_body())
    end)

    for provider_opts <- [
          [google: [google_auth_header: false, google_api_version: "v1beta"]],
          %{"google_auth_header" => false}
        ] do
      assert {:ok, _} =
               ReqLLM.evaluate(
                 @model,
                 "text",
                 @questions,
                 options() ++
                   [
                     base_url: "https://proxy.example/gateway/v1beta",
                     evaluate_path: "/v1beta/custom-decisions",
                     provider_options: provider_opts
                   ]
               )
    end
  end

  test "validates question types, counts, names, criteria, and normalized key collisions" do
    invalid_questions = [
      %{"bad name" => %{type: :boolean, instructions: "Question"}},
      Map.new(1..1001, &{"q#{&1}", %{type: :boolean, instructions: "Question"}}),
      %{q: %{type: :choice, instructions: "Question", criteria: %{only: "One option"}}},
      %{
        q: %{
          type: :choice,
          instructions: "Question",
          criteria: %{" leading" => "Bad", "ok" => "Good"}
        }
      },
      %{q: %{type: :score, instructions: "Question", criteria: ["", "high"]}},
      %{q: %{type: :boolean, instructions: "Question", criteria: %{true_description: 123}}},
      %{q: %{type: :freeform, instructions: "Question"}},
      %{q: %{type: :boolean, instructions: 123}},
      %{
        "q" => %{type: :boolean, instructions: "Question"},
        q: %{type: :boolean, instructions: "Question"}
      },
      %{q: %{"type" => "choice", type: :boolean, instructions: "Question"}}
    ]

    for questions <- invalid_questions do
      assert {:error, %ReqLLM.Error.Invalid.Parameter{}} =
               ReqLLM.evaluate(@model, "text", questions, no_http_options())
    end
  end

  test "rejects unsupported contexts and media before HTTP" do
    invalid_states = [
      "",
      ReqLLM.Context.new(),
      ReqLLM.Context.new([ReqLLM.Context.system("System"), ReqLLM.Context.user("User")]),
      ReqLLM.Context.new([ReqLLM.Context.assistant("Assistant")]),
      ReqLLM.Context.new([ReqLLM.Context.user([ContentPart.thinking("Thought")])]),
      ReqLLM.Context.new([ReqLLM.Context.user([ContentPart.image_url("gs://bucket/photo.png")])]),
      ReqLLM.Context.new([
        ReqLLM.Context.user([ContentPart.video_url("https://youtu.be/example")])
      ]),
      ReqLLM.Context.new([ReqLLM.Context.user([ContentPart.file("bytes", "unknown.bin")])]),
      ReqLLM.Context.new([
        ReqLLM.Context.user([
          ContentPart.video_url("https://example.com/a.mp4", %{resolution: "ultra_high"})
        ])
      ])
    ]

    for state <- invalid_states do
      assert {:error, %ReqLLM.Error.Invalid.Parameter{}} =
               ReqLLM.evaluate(@model, state, @questions, no_http_options())
    end
  end

  test "rejects v1 and Vertex AI evaluation without sending a request" do
    assert {:error, %ReqLLM.Error.Invalid.Parameter{parameter: reason}} =
             ReqLLM.evaluate(
               @model,
               "text",
               @questions,
               no_http_options() ++ [provider_options: [google_api_version: "v1"]]
             )

    assert reason =~ "v1beta"

    assert {:error, %ReqLLM.Error.Invalid.Parameter{parameter: reason}} =
             ReqLLM.evaluate(
               %{@model | provider: :google_vertex},
               "text",
               @questions,
               no_http_options()
             )

    assert reason =~ "does not implement this protocol"
  end

  test "returns a structured error for an empty API key" do
    assert {:error, %ReqLLM.Error.Invalid.Parameter{parameter: reason}} =
             ReqLLM.evaluate(
               @model,
               "text",
               @questions,
               Keyword.put(no_http_options(), :api_key, "")
             )

    assert reason =~ "GOOGLE_API_KEY"
  end

  test "rejects file references owned by another provider before HTTP" do
    context =
      ReqLLM.Context.new([
        ReqLLM.Context.user([
          ContentPart.owned_file_id("https://example.com/private.pdf", :openai)
        ])
      ])

    assert {:error, %ReqLLM.Error.Invalid.ProviderFileReference{}} =
             ReqLLM.evaluate(@model, context, @questions, no_http_options())
  end

  test "rejects malformed or mismatched successful responses" do
    body = response_body()

    for invalid <- [
          %{},
          Map.delete(body, "usage"),
          put_in(body, ["answers", "damaged", "noul"], 1.5),
          put_in(body, ["answers", "team", "choice"], "unknown"),
          put_in(body, ["answers", "severity", "score"], 5),
          put_in(body, ["answers", "severity", "legend"], %{}),
          update_in(body, ["answers"], &Map.delete(&1, "team")),
          put_in(body, ["usage", "total_input_tokens"], "invalid")
        ] do
      Req.Test.stub(__MODULE__, &Req.Test.json(&1, invalid))

      assert {:error, %ReqLLM.Error.API.Request{status: 200, response_body: ^invalid}} =
               ReqLLM.evaluate(@model, "text", @questions, options())
    end
  end

  test "preserves provider error details" do
    error = %{"error" => %{"code" => "safety", "message" => "Request blocked"}}

    Req.Test.stub(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_status(400) |> Req.Test.json(error)
    end)

    assert {:error, exception} = ReqLLM.evaluate(@model, "text", @questions, options())
    assert exception.status == 400
    assert exception.response_body == error
  end

  test "accepts native noul questions and boolean choice keys" do
    assert {:ok, body, _} =
             DecisionsAPI.compile_request("gemini-decision-1", "text", %{
               check: %{type: "noul", instructions: "Check?"},
               select: %{
                 type: :choice,
                 instructions: "Select?",
                 criteria: %{true => "Yes", false => "No"}
               }
             })

    assert body["questions"]["check"]["type"] == "noul"
    assert body["questions"]["select"]["criteria"] == %{"true" => "Yes", "false" => "No"}
  end

  defp options, do: [api_key: "test-key", req_http_options: [plug: {Req.Test, __MODULE__}]]

  defp no_http_options do
    [api_key: "test-key", req_http_options: [adapter: fn _ -> flunk("HTTP must not run") end]]
  end

  defp response_body do
    %{
      "answers" => %{
        "damaged" => %{"type" => "noul", "noul" => 0.95, "confidence" => 0.95},
        "team" => %{
          "type" => "choice",
          "choice" => "support",
          "probabilities" => %{"billing" => 0.1, "support" => 0.9},
          "confidence" => 0.9
        },
        "severity" => %{
          "type" => "score",
          "score" => 1.6,
          "probabilities" => %{"0" => 0.1, "1" => 0.2, "2" => 0.7},
          "legend" => %{"0" => "Minor", "1" => "Major", "2" => "Critical"},
          "confidence" => 0.7
        }
      },
      "usage" => %{
        "total_input_tokens" => 100,
        "total_output_tokens" => 0,
        "total_tokens" => 100,
        "input_tokens_by_modality" => [%{"modality" => "text", "tokens" => 100}]
      }
    }
  end
end
