# test/ontology_knhk_test.exs
# Purpose: Test KNHK (Knowledge Hooks) functionality

defmodule ReqLLM.OntologyKNHKTest do
  use ExUnit.Case, async: false  # async: false for telemetry handlers

  alias ReqLLM.Ontology.{Telemetry, AuditLogger, Metrics, DocGenerator}

  setup do
    # Start metrics GenServer for tests
    {:ok, _pid} = start_supervised(Metrics)
    Metrics.reset_metrics()

    # Cleanup audit logs after each test
    on_exit(fn ->
      File.rm_rf!("./audit_logs")
    end)

    :ok
  end

  describe "Telemetry" do
    test "emit_response_complete sends telemetry event" do
      # Attach test handler
      test_pid = self()

      :telemetry.attach(
        "test-handler",
        [:req_llm, :ontology, :response, :complete],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      response = %{
        id: "resp_123",
        finish_reason: :stop,
        usage: %{
          input_tokens: 100,
          output_tokens: 50,
          total_tokens: 150,
          total_cost: 0.005
        },
        context: %{
          messages: [
            %{role: :user, parts: [%{text: "Hello"}]},
            %{role: :assistant, parts: [%{text: "Hi"}]}
          ]
        }
      }

      Telemetry.emit_response_complete(response,
        provider: :openai,
        model: "gpt-4",
        duration_ms: 1234
      )

      assert_receive {:telemetry, [:req_llm, :ontology, :response, :complete], measurements,
                      metadata}

      assert measurements.input_tokens == 100
      assert measurements.output_tokens == 50
      assert measurements.total_cost == 0.005
      assert measurements.duration_ms == 1234

      assert metadata.ontology_type == "req:Response"
      assert metadata.finish_reason == :stop
      assert metadata.provider == :openai
      assert metadata.model == "gpt-4"
      assert metadata.message_count == 2

      :telemetry.detach("test-handler")
    end

    test "emit_stream_chunk sends telemetry event" do
      test_pid = self()

      :telemetry.attach(
        "test-stream-handler",
        [:req_llm, :ontology, :stream, :chunk],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      chunk = %{
        type: :content,
        text: "Hello, world!"
      }

      Telemetry.emit_stream_chunk(chunk, 0, provider: :anthropic)

      assert_receive {:telemetry, [:req_llm, :ontology, :stream, :chunk], measurements, metadata}

      assert measurements.chunk_size == 13  # byte_size("Hello, world!")
      assert measurements.chunk_index == 0
      assert metadata.chunk_type == :content
      assert metadata.provider == :anthropic

      :telemetry.detach("test-stream-handler")
    end

    test "emit_validation_result sends telemetry for valid data" do
      test_pid = self()

      :telemetry.attach(
        "test-validation-handler",
        [:req_llm, :ontology, :validation, :result],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      Telemetry.emit_validation_result("req:Response", :ok)

      assert_receive {:telemetry, [:req_llm, :ontology, :validation, :result], measurements,
                      metadata}

      assert measurements.is_valid == 1
      assert measurements.error_count == 0
      assert metadata.validation_errors == []

      :telemetry.detach("test-validation-handler")
    end

    test "emit_validation_result sends telemetry for invalid data" do
      test_pid = self()

      :telemetry.attach(
        "test-validation-error-handler",
        [:req_llm, :ontology, :validation, :result],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      errors = ["Message must have role", "Message must have parts"]
      Telemetry.emit_validation_result("req:Message", {:error, errors})

      assert_receive {:telemetry, [:req_llm, :ontology, :validation, :result], measurements,
                      metadata}

      assert measurements.is_valid == 0
      assert measurements.error_count == 2
      assert metadata.validation_errors == errors

      :telemetry.detach("test-validation-error-handler")
    end
  end

  describe "AuditLogger" do
    test "log_usage writes JSONL entry to file" do
      usage = %{
        input_tokens: 100,
        output_tokens: 50,
        total_tokens: 150,
        input_cost: 0.003,
        output_cost: 0.002,
        total_cost: 0.005
      }

      AuditLogger.log_usage(usage,
        provider: :openai,
        model: "gpt-4",
        session_id: "sess_123"
      )

      # Check that log file was created
      date = Date.utc_today() |> Date.to_string()
      log_file = Path.join("./audit_logs", "usage_#{date}.jsonl")

      assert File.exists?(log_file)

      # Read and verify contents
      lines = File.read!(log_file) |> String.split("\n", trim: true)
      assert length(lines) == 1

      entry = Jason.decode!(hd(lines))
      assert entry["ontology_type"] == "req:Usage"
      assert entry["input_tokens"] == 100
      assert entry["output_tokens"] == 50
      assert entry["provider"] == "openai"
      assert entry["model"] == "gpt-4"
      assert entry["session_id"] == "sess_123"
    end

    test "log_finish_reason writes JSONL entry to file" do
      AuditLogger.log_finish_reason(:stop,
        provider: :anthropic,
        model: "claude-3",
        response_id: "resp_456"
      )

      date = Date.utc_today() |> Date.to_string()
      log_file = Path.join("./audit_logs", "finish_reasons_#{date}.jsonl")

      assert File.exists?(log_file)

      lines = File.read!(log_file) |> String.split("\n", trim: true)
      entry = Jason.decode!(hd(lines))

      assert entry["ontology_type"] == "req:FinishReason"
      assert entry["finish_reason"] == "stop"
      assert entry["provider"] == "anthropic"
      assert entry["response_id"] == "resp_456"
    end

    test "read_usage_logs reads entries from date range" do
      # Write test entries
      usage1 = %{input_tokens: 10, output_tokens: 5, total_tokens: 15, total_cost: 0.001}
      usage2 = %{input_tokens: 20, output_tokens: 10, total_tokens: 30, total_cost: 0.002}

      AuditLogger.log_usage(usage1, provider: :openai)
      AuditLogger.log_usage(usage2, provider: :anthropic)

      # Read logs
      today = Date.utc_today() |> Date.to_iso8601()
      logs = AuditLogger.read_usage_logs(today, today)

      assert length(logs) == 2
      assert Enum.any?(logs, &(&1["input_tokens"] == 10))
      assert Enum.any?(logs, &(&1["input_tokens"] == 20))
    end

    test "aggregate_usage calculates totals" do
      # Write multiple entries
      for i <- 1..5 do
        usage = %{
          input_tokens: i * 10,
          output_tokens: i * 5,
          total_tokens: i * 15,
          total_cost: i * 0.001
        }

        AuditLogger.log_usage(usage, provider: :openai, model: "gpt-4")
      end

      today = Date.utc_today() |> Date.to_iso8601()
      summary = AuditLogger.aggregate_usage(today, today)

      assert summary.total_requests == 5
      assert summary.total_input_tokens == 150  # 10+20+30+40+50
      assert summary.total_output_tokens == 75  # 5+10+15+20+25
      assert summary.total_cost == 0.015  # 0.001+0.002+0.003+0.004+0.005
    end

    test "aggregate_finish_reasons counts distribution" do
      AuditLogger.log_finish_reason(:stop, provider: :openai)
      AuditLogger.log_finish_reason(:stop, provider: :openai)
      AuditLogger.log_finish_reason(:tool_calls, provider: :openai)
      AuditLogger.log_finish_reason(:length, provider: :openai)

      today = Date.utc_today() |> Date.to_iso8601()
      distribution = AuditLogger.aggregate_finish_reasons(today, today)

      assert distribution["stop"] == 2
      assert distribution["tool_calls"] == 1
      assert distribution["length"] == 1
    end
  end

  describe "Metrics" do
    test "record_class increments class counter" do
      Metrics.record_class("req:Response")
      Metrics.record_class("req:Response")
      Metrics.record_class("req:Context")

      metrics = Metrics.get_metrics()

      assert metrics.classes["req:Response"] == 2
      assert metrics.classes["req:Context"] == 1
    end

    test "record_property increments property counter" do
      Metrics.record_property("req:hasContext")
      Metrics.record_property("req:hasContext")
      Metrics.record_property("req:hasUsage")

      metrics = Metrics.get_metrics()

      assert metrics.properties["req:hasContext"] == 2
      assert metrics.properties["req:hasUsage"] == 1
    end

    test "record_part_type tracks ContentPart distribution" do
      Metrics.record_part_type(:text)
      Metrics.record_part_type(:text)
      Metrics.record_part_type(:text)
      Metrics.record_part_type(:tool_call)
      Metrics.record_part_type(:image_url)

      metrics = Metrics.get_metrics()

      assert metrics.part_types["text"] == 3
      assert metrics.part_types["tool_call"] == 1
      assert metrics.part_types["image_url"] == 1
    end

    test "record_finish_reason tracks FinishReason distribution" do
      Metrics.record_finish_reason(:stop)
      Metrics.record_finish_reason(:stop)
      Metrics.record_finish_reason(:stop)
      Metrics.record_finish_reason(:tool_calls)

      metrics = Metrics.get_metrics()

      assert metrics.finish_reasons["stop"] == 3
      assert metrics.finish_reasons["tool_calls"] == 1
    end

    test "coverage_report calculates ontology coverage" do
      # Record usage of various classes
      Metrics.record_class("req:Response")
      Metrics.record_class("req:Context")
      Metrics.record_class("req:Message")
      Metrics.record_class("req:TextPart")
      Metrics.record_class("req:Usage")

      # Record property usage
      Metrics.record_property("req:hasContext")
      Metrics.record_property("req:hasMessage")
      Metrics.record_property("req:role")

      report = Metrics.coverage_report()

      assert report.class_coverage > 0
      assert report.property_coverage > 0
      assert "req:Response" in report.used_classes
      assert "req:hasContext" in report.used_properties
      assert is_list(report.unused_classes)
      assert is_list(report.unused_properties)
    end

    test "reset_metrics clears all counters" do
      Metrics.record_class("req:Response")
      Metrics.record_property("req:hasContext")

      Metrics.reset_metrics()

      metrics = Metrics.get_metrics()

      assert metrics.classes == %{}
      assert metrics.properties == %{}
    end
  end

  describe "DocGenerator" do
    test "generate_schema_docs produces markdown" do
      docs = DocGenerator.generate_schema_docs()

      assert is_binary(docs)
      assert docs =~ "# ReqLLM Ontology Schema"
      assert docs =~ "## Classes"
      assert docs =~ "## Properties"
      assert docs =~ "## Enumerations"
      assert docs =~ "### Role"
      assert docs =~ "### FinishReason"
    end

    test "generate_erd produces mermaid diagram" do
      erd = DocGenerator.generate_erd()

      assert is_binary(erd)
      assert erd =~ "```mermaid"
      assert erd =~ "erDiagram"
      assert erd =~ "Response ||--|| Context"
      assert erd =~ "Message ||--o{ ContentPart"
    end

    test "generate_api_reference produces API docs" do
      docs = DocGenerator.generate_api_reference()

      assert is_binary(docs)
      assert docs =~ "# ReqLLM API Reference"
      assert docs =~ "## Response"
      assert docs =~ "## Message"
      assert docs =~ "## Usage"
      assert docs =~ "**Required Fields**"
      assert docs =~ "**Validation**"
    end
  end
end
