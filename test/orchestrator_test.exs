defmodule ReqLLM.OrchestratorTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Orchestrator.{
    CallPlan,
    ProviderCandidate,
    Attempt,
    RetryPolicy,
    BudgetPolicy,
    Failure
  }

  alias ReqLLM.Context
  alias ReqLLM.Response

  describe "CallPlan" do
    test "creates a new call plan with defaults" do
      context = %Context{messages: []}
      candidates = [
        ProviderCandidate.new("anthropic", "claude-3-5-sonnet-20241022", priority: 1),
        ProviderCandidate.new("openai", "gpt-4o", priority: 2)
      ]
      retry_policy = RetryPolicy.new()
      budget_policy = BudgetPolicy.new()

      {:ok, plan} = CallPlan.new(context, candidates, retry_policy, budget_policy)

      assert String.starts_with?(plan.id, "plan_")  # UUID-generated ID
      assert plan.context == context
      assert length(plan.candidates) == 2
      assert plan.attempts == []
      assert plan.retry_policy.max_attempts == 3
      assert plan.budget_policy.max_total_cost_usd == 1.0
    end

    test "creates call plan with custom policies" do
      context = %Context{messages: []}
      candidates = [ProviderCandidate.new("anthropic", "claude-3-5-sonnet-20241022")]
      retry_policy = RetryPolicy.new(max_attempts: 5)
      budget_policy = BudgetPolicy.new(max_total_cost_usd: 2.0)

      {:ok, plan} = CallPlan.new(context, candidates, retry_policy, budget_policy)

      assert plan.retry_policy.max_attempts == 5
      assert plan.budget_policy.max_total_cost_usd == 2.0
    end
  end

  describe "ProviderCandidate" do
    test "creates provider candidate with defaults" do
      candidate = ProviderCandidate.new("anthropic", "claude-3-5-sonnet-20241022")

      assert candidate.provider == "anthropic"
      assert candidate.model == "claude-3-5-sonnet-20241022"
      assert candidate.priority == 999
      assert candidate.estimated_cost == 0.0
    end

    test "creates provider candidate with custom priority" do
      candidate =
        ProviderCandidate.new("openai", "gpt-4o", priority: 1, estimated_cost: 0.03)

      assert candidate.priority == 1
      assert candidate.estimated_cost == 0.03
    end
  end

  describe "Attempt" do
    setup do
      context = %Context{messages: [%{role: :user, content: "test"}]}
      candidate = ProviderCandidate.new("anthropic", "claude-3-5-sonnet-20241022", priority: 1)
      {:ok, context: context, candidate: candidate}
    end

    test "records successful attempt", %{context: context, candidate: candidate} do
      # Note: This would require mocking ReqLLM.generate_text
      # For now, we'll test the struct creation
      response = %Response{
        id: "resp_test",
        model: candidate.model,
        context: context,
        message: %{role: :assistant, content: "test response"},
        finish_reason: :stop,
        usage: %{input_tokens: 10, output_tokens: 20}
      }

      attempt = %Attempt{
        index: 0,
        provider: candidate.provider,
        model: candidate.model,
        cost_usd: 0.02,
        duration_ms: 1500,
        success: true,
        error: nil,
        response: response,
        timestamp: DateTime.utc_now()
      }

      assert attempt.success == true
      assert attempt.provider == "anthropic"
      assert attempt.cost_usd == 0.02
      assert attempt.duration_ms == 1500
    end

    test "records failed attempt" do
      attempt = %Attempt{
        index: 0,
        provider: "anthropic",
        model: "claude-3-5-sonnet-20241022",
        cost_usd: 0.0,
        duration_ms: 500,
        success: false,
        error: "rate_limit_exceeded",
        response: nil,
        timestamp: DateTime.utc_now()
      }

      assert attempt.success == false
      assert attempt.error == "rate_limit_exceeded"
      assert attempt.response == nil
    end
  end

  describe "RetryPolicy" do
    test "creates policy with defaults" do
      policy = RetryPolicy.new()

      assert policy.max_attempts == 3
      assert policy.backoff_ms == 1000
      assert is_list(policy.retryable_errors)
      assert "rate_limit" in policy.retryable_errors
    end

    test "determines if retry should happen" do
      policy = RetryPolicy.new(max_attempts: 3)

      # No retries if under max attempts and last failed with retryable error
      attempts = [
        %Attempt{success: false, error: "rate_limit_exceeded"}
      ]

      assert RetryPolicy.should_retry?(policy, attempts) == true
    end

    test "prevents retry after max attempts" do
      policy = RetryPolicy.new(max_attempts: 2)

      attempts = [
        %Attempt{success: false, error: "rate_limit"},
        %Attempt{success: false, error: "rate_limit"}
      ]

      assert RetryPolicy.should_retry?(policy, attempts) == false
    end

    test "calculates exponential backoff" do
      policy = RetryPolicy.new(backoff_ms: 1000)

      assert RetryPolicy.backoff_delay(policy, 0) == 500
      assert RetryPolicy.backoff_delay(policy, 1) == 1000
      assert RetryPolicy.backoff_delay(policy, 2) == 2000
      assert RetryPolicy.backoff_delay(policy, 3) == 4000
    end

    test "checks if error is retryable" do
      policy = RetryPolicy.new()

      assert RetryPolicy.is_retryable_error?(policy, "rate_limit_exceeded") == true
      assert RetryPolicy.is_retryable_error?(policy, "connection_timeout") == true
      assert RetryPolicy.is_retryable_error?(policy, "invalid_api_key") == false
      assert RetryPolicy.is_retryable_error?(policy, nil) == false
    end
  end

  describe "BudgetPolicy" do
    test "creates policy with defaults" do
      policy = BudgetPolicy.new()

      assert policy.max_total_cost_usd == 1.0
      assert policy.max_latency_ms == 30_000
    end

    test "checks if within budget" do
      policy = BudgetPolicy.new(max_total_cost_usd: 1.0)

      attempts = [
        %Attempt{cost_usd: 0.30},
        %Attempt{cost_usd: 0.40}
      ]

      assert BudgetPolicy.within_budget?(policy, attempts) == true

      attempts = attempts ++ [%Attempt{cost_usd: 0.50}]
      assert BudgetPolicy.within_budget?(policy, attempts) == false
    end

    test "checks if latency exceeded" do
      policy = BudgetPolicy.new(max_latency_ms: 5000)

      attempts = [
        %Attempt{duration_ms: 2000},
        %Attempt{duration_ms: 2000}
      ]

      assert BudgetPolicy.exceeds_latency?(policy, attempts) == false

      attempts = attempts ++ [%Attempt{duration_ms: 2000}]
      assert BudgetPolicy.exceeds_latency?(policy, attempts) == true
    end

    test "calculates remaining budget" do
      policy = BudgetPolicy.new(max_total_cost_usd: 1.0)

      attempts = [
        %Attempt{cost_usd: 0.30},
        %Attempt{cost_usd: 0.20}
      ]

      assert BudgetPolicy.remaining_budget(policy, attempts) == 0.5
    end

    test "calculates remaining time" do
      policy = BudgetPolicy.new(max_latency_ms: 10_000)

      attempts = [
        %Attempt{duration_ms: 3000},
        %Attempt{duration_ms: 2000}
      ]

      assert BudgetPolicy.remaining_time_ms(policy, attempts) == 5000
    end
  end

  describe "Failure" do
    test "creates failure from attempts" do
      attempts = [
        %Attempt{success: false, error: "rate_limit", cost_usd: 0.01, duration_ms: 100},
        %Attempt{success: false, error: "timeout", cost_usd: 0.02, duration_ms: 200}
      ]

      failure = Failure.from_attempts(attempts)

      assert failure.reason == :all_attempts_failed
      assert failure.attempt_count == 2
      assert failure.total_cost_usd == 0.03
      assert failure.total_duration_ms == 300
      assert failure.last_error == "timeout"
      assert failure.message == "All 2 attempt(s) failed"
    end

    test "creates budget exceeded failure" do
      attempts = [
        %Attempt{cost_usd: 0.50},
        %Attempt{cost_usd: 0.60}
      ]

      failure = Failure.budget_exceeded(attempts, 1.0)

      assert failure.reason == :budget_exceeded
      assert failure.message =~ "Budget exceeded"
      assert failure.total_cost_usd == 1.1
    end

    test "creates latency exceeded failure" do
      attempts = [
        %Attempt{duration_ms: 20_000},
        %Attempt{duration_ms: 15_000}
      ]

      failure = Failure.latency_exceeded(attempts, 30_000)

      assert failure.reason == :latency_exceeded
      assert failure.message =~ "Latency exceeded"
      assert failure.total_duration_ms == 35_000
    end

    test "creates no candidates failure" do
      attempts = []

      failure = Failure.no_candidates_available(attempts)

      assert failure.reason == :no_candidates
      assert failure.message == "No more provider candidates available"
    end

    test "converts failure to error tuple" do
      attempts = [%Attempt{success: false, error: "test"}]
      failure = Failure.from_attempts(attempts)

      {:error, error} = Failure.to_error(failure)

      assert error.type == :orchestration_failure
      assert error.reason == :all_attempts_failed
      assert error.message == "All 1 attempt(s) failed"
      assert error.metadata.attempt_count == 1
    end
  end

  describe "JSON-LD Emitters" do
    test "emits call plan as JSON-LD" do
      alias ReqLLM.Ontology.Emitter

      context = %Context{messages: []}
      candidates = [ProviderCandidate.new("anthropic", "claude-3-5-sonnet-20241022")]
      retry_policy = RetryPolicy.new()
      budget_policy = BudgetPolicy.new()
      {:ok, plan} = CallPlan.new(context, candidates, retry_policy, budget_policy)

      jsonld = Emitter.emit_call_plan(plan)

      assert jsonld["@type"] == "CallPlan"
      assert String.starts_with?(jsonld["id"], "plan_")  # UUID-generated ID
      assert is_map(jsonld["@context"])
    end

    test "emits attempt as JSON-LD" do
      alias ReqLLM.Ontology.Emitter

      attempt = %Attempt{
        index: 0,
        provider: "anthropic",
        model: "claude-3-5-sonnet-20241022",
        cost_usd: 0.02,
        duration_ms: 1500,
        success: true,
        timestamp: DateTime.utc_now()
      }

      jsonld = Emitter.emit_attempt(attempt, strip: true)

      assert jsonld["@type"] == "Attempt"
      assert jsonld["provider"] == "anthropic"
      assert jsonld["costUSD"] == 0.02
      assert jsonld["durationMs"] == 1500
      assert jsonld["success"] == true
    end

    test "emits failure as JSON-LD" do
      alias ReqLLM.Ontology.Emitter

      attempts = [%Attempt{success: false, error: "test", cost_usd: 0.01, duration_ms: 100}]
      failure = Failure.from_attempts(attempts)

      jsonld = Emitter.emit_failure(failure, strip: true)

      assert jsonld["@type"] == "Failure"
      assert jsonld["reason"] == "all_attempts_failed"
      assert jsonld["attemptCount"] == 1
      assert jsonld["totalCostUSD"] == 0.01
    end
  end
end
