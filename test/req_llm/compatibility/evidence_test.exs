defmodule ReqLLM.Compatibility.EvidenceTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Compatibility.{Evidence, ScenarioCatalog, SupportReference}

  @checked_at "2026-07-01T00:00:00Z"
  @as_of ~U[2026-07-16 00:00:00Z]

  describe "migration" do
    test "versions legacy state without discarding observations or metadata" do
      legacy = %{
        "openai:gpt-4o-mini" => %{
          "source" => "legacy",
          "scenarios" => %{
            "basic" => %{
              "status" => "pass",
              "last_checked" => @checked_at,
              "mode" => "record",
              "fixtures" => ["basic"],
              "error" => nil,
              "attempt" => 3
            }
          }
        }
      }

      evidence =
        Evidence.migrate(legacy,
          surface_resolver: fn _model_spec, _operation, _fixtures -> "openai.responses" end
        )

      assert evidence["schema_version"] == 1
      assert evidence["generated_at"] == @checked_at

      assert %{
               "provider" => "openai",
               "model" => "gpt-4o-mini",
               "legacy_metadata" => %{"source" => "legacy"}
             } = evidence["models"]["openai:gpt-4o-mini"]

      scenario =
        get_in(evidence, [
          "models",
          "openai:gpt-4o-mini",
          "surfaces",
          "openai.responses",
          "scenarios",
          "basic"
        ])

      assert scenario["proof"] == "fixture_replay"

      assert [
               %{
                 "status" => "pass",
                 "checked_at" => @checked_at,
                 "mode" => "record",
                 "fixtures" => ["basic"],
                 "failure_layer" => nil,
                 "legacy_metadata" => %{"attempt" => 3}
               }
             ] = scenario["observations"]
    end

    test "keeps the current schema unchanged" do
      evidence = %{"schema_version" => 1, "generated_at" => @checked_at, "models" => %{}}
      assert Evidence.migrate(evidence) === evidence
    end

    test "rejects unknown schema versions instead of treating them as legacy state" do
      assert_raise ArgumentError, ~r/unsupported compatibility evidence schema version: 2/, fn ->
        Evidence.migrate(%{"schema_version" => 2, "models" => %{}})
      end
    end

    test "checked-in migration preserves every legacy scenario observation" do
      path = Path.expand("../../../priv/model_compat_scenarios.json", __DIR__)
      content = File.read!(path)
      evidence = Jason.decode!(content)

      observations =
        for {_model_spec, model} <- evidence["models"],
            {_surface_id, surface} <- model["surfaces"],
            {_scenario_id, scenario} <- surface["scenarios"],
            observation <- scenario["observations"] do
          observation
        end

      assert evidence["schema_version"] == 1
      assert map_size(evidence["models"]) == 689
      assert length(observations) == 780
      assert Enum.frequencies_by(observations, & &1["status"]) == %{"fail" => 132, "pass" => 648}
      assert Enum.frequencies_by(observations, & &1["mode"]) == %{"record" => 766, "replay" => 14}
      assert Enum.sum(Enum.map(observations, &length(&1["fixtures"]))) == 787
      assert Enum.count(observations, & &1["error"]) == 132
      assert observations |> Enum.map(& &1["checked_at"]) |> Enum.uniq() |> length() == 174
      assert Evidence.canonical_json(evidence) == content
    end
  end

  describe "record/5" do
    test "appends observations for the recorded execution surface" do
      evidence = evidence_with_surface(%{"basic" => observation("pass")})
      checked_at = ~U[2026-07-16 12:00:00Z]

      result = %{
        model_spec: "openai:gpt-4o-mini",
        scenarios: [
          %{
            "scenario" => "basic",
            "status" => "fail",
            "fixtures" => ["basic"],
            "failure_layer" => "assertion",
            "error" => "expected response"
          }
        ]
      }

      updated =
        Evidence.record(evidence, [result], checked_at, "replay",
          surface_resolver: fn _model_spec, _operation, _fixtures -> "openai.responses" end
        )

      observations =
        get_in(updated, [
          "models",
          "openai:gpt-4o-mini",
          "surfaces",
          "openai.responses",
          "scenarios",
          "basic",
          "observations"
        ])

      assert Enum.map(observations, & &1["status"]) == ["pass", "fail"]
      assert updated["generated_at"] == "2026-07-16T12:00:00Z"
    end

    test "rejects replay that follows a different execution surface" do
      evidence = evidence_with_surface(%{"basic" => observation("pass")})

      result = %{
        model_spec: "openai:gpt-4o-mini",
        scenarios: [
          %{
            "scenario" => "basic",
            "status" => "pass",
            "fixtures" => ["basic"],
            "failure_layer" => nil,
            "error" => nil
          }
        ]
      }

      assert_raise ArgumentError, ~r/replay surface changed/, fn ->
        Evidence.record(evidence, [result], @as_of, "replay",
          surface_resolver: fn _model_spec, _operation, _fixtures ->
            "openai.chat_completions"
          end
        )
      end
    end
  end

  describe "support tiers" do
    test "derives first-class only from a complete current baseline" do
      scenarios =
        :text
        |> ScenarioCatalog.baseline_scenarios()
        |> Map.new(&{&1, observation("pass")})

      status =
        scenarios
        |> evidence_with_surface()
        |> Evidence.support_status("openai:gpt-4o-mini", :text, as_of: @as_of)

      assert status.tier == :first_class
      assert status.reason == :complete_current_baseline
      assert status.missing_scenarios == []
    end

    test "derives best-effort from partial current baseline evidence" do
      status =
        %{"basic" => observation("pass")}
        |> evidence_with_surface()
        |> Evidence.support_status("openai:gpt-4o-mini", :text, as_of: @as_of)

      assert status.tier == :best_effort
      assert status.reason == :partial_current_baseline
      assert "streaming" in status.missing_scenarios
    end

    test "keeps missing and stale evidence experimental" do
      empty_status =
        Evidence.support_status(
          %{"schema_version" => 1, "models" => %{}},
          "openai:gpt-4o-mini",
          :text,
          as_of: @as_of
        )

      stale_status =
        %{"basic" => observation("pass", "2025-01-01T00:00:00Z")}
        |> evidence_with_surface()
        |> Evidence.support_status("openai:gpt-4o-mini", :text, as_of: @as_of)

      assert empty_status.tier == :experimental
      assert empty_status.reason == :missing_evidence
      assert stale_status.tier == :experimental
      assert stale_status.reason == :missing_or_stale_evidence
    end

    test "derives unsupported with a classified baseline failure reason" do
      status =
        %{"basic" => observation("fail", @checked_at, "provider_drift")}
        |> evidence_with_surface()
        |> Evidence.support_status("openai:gpt-4o-mini", :text, as_of: @as_of)

      assert status.tier == :unsupported
      assert status.reason == :baseline_failure
      assert status.scenario == "basic"
      assert status.failure_layer == "provider_drift"
    end

    test "reports undeclared operations as unsupported without consulting evidence" do
      status =
        Evidence.support_status(
          evidence_with_surface(%{"basic" => observation("pass")}),
          "openai:gpt-4o-mini",
          :image,
          declared?: false,
          as_of: @as_of
        )

      assert status.tier == :unsupported
      assert status.reason == :operation_not_declared
    end

    test "keeps evidence for models missing from the current catalog experimental" do
      evidence =
        %{"basic" => observation("pass")}
        |> evidence_with_surface()
        |> Evidence.annotate_declarations(fn _model_spec -> {:error, :unknown_model} end)

      status =
        Evidence.support_status(evidence, "openai:gpt-4o-mini", :text, as_of: @as_of)

      assert status.tier == :experimental
      assert status.reason == :surface_declaration_unknown
      assert status.checked_at == @checked_at
    end
  end

  describe "failure classification and execution surfaces" do
    test "classifies every stable failure layer" do
      assert Evidence.classify_failure("unknown model") == "resolution"
      assert Evidence.classify_failure("execution plan unavailable") == "planning"
      assert Evidence.classify_failure("failed to encode request body") == "encoding"
      assert Evidence.classify_failure("connection timed out") == "transport"
      assert Evidence.classify_failure("failed to decode response") == "decoding"

      assert Evidence.classify_failure("response builder materialization failed") ==
               "materialization"

      assert Evidence.classify_failure("expected true") == "assertion"
      assert Evidence.classify_failure("Provider response error (404)") == "provider_drift"

      assert Evidence.failure_layers() ==
               ~w(resolution planning encoding transport decoding materialization assertion provider_drift)
    end

    test "derives the exact wire surface from recorded fixture URLs" do
      root = Path.expand("../../support/fixtures", __DIR__)

      assert Evidence.fixture_surface(root, "openai:gpt-4o-mini", :text, ["basic"]) ==
               "openai.responses"

      assert Evidence.fixture_surface(
               root,
               "anthropic:claude-sonnet-4-5-20250929",
               :text,
               ["web_fetch_basic"]
             ) == "anthropic.messages"
    end
  end

  describe "deterministic output" do
    test "canonical JSON recursively sorts keys" do
      first = %{"models" => %{"b" => %{}, "a" => %{}}, "schema_version" => 1}
      second = %{"schema_version" => 1, "models" => %{"a" => %{}, "b" => %{}}}

      assert Evidence.canonical_json(first) == Evidence.canonical_json(second)
      assert Evidence.canonical_json(first) =~ ~s("a": {})
    end

    test "support reference is deterministic and catalog-derived" do
      evidence = evidence_with_surface(%{"basic" => observation("pass")})

      first = SupportReference.render(evidence, as_of: @as_of)
      second = SupportReference.render(evidence, as_of: @as_of)

      assert first == second
      assert first =~ "openai.responses"
      assert first =~ "text → text"
      assert first =~ "Best-effort"
    end
  end

  defp evidence_with_surface(scenarios) do
    scenario_entries =
      Map.new(scenarios, fn {scenario_id, observation} ->
        {scenario_id,
         %{
           "proof" => "fixture_replay",
           "observations" => [observation]
         }}
      end)

    %{
      "schema_version" => 1,
      "generated_at" => @checked_at,
      "models" => %{
        "openai:gpt-4o-mini" => %{
          "provider" => "openai",
          "model" => "gpt-4o-mini",
          "surfaces" => %{
            "openai.responses" => %{
              "provider" => "openai",
              "operation" => "text",
              "scenarios" => scenario_entries
            }
          }
        }
      }
    }
  end

  defp observation(status, checked_at \\ @checked_at, failure_layer \\ nil) do
    %{
      "status" => status,
      "checked_at" => checked_at,
      "mode" => "replay",
      "fixtures" => ["basic"],
      "failure_layer" => failure_layer,
      "error" => if(status == "pass", do: nil, else: "failure")
    }
  end
end
