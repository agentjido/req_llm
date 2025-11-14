defmodule ReqLLM.Step.RetryTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Step.Retry

  describe "attach/1" do
    test "configures retry options on request" do
      request = Req.new()
      updated_request = Retry.attach(request)

      # Verify retry function is configured
      assert is_function(updated_request.options[:retry], 2)
      assert updated_request.options[:max_retries] == 3
      # Note: retry_delay should NOT be set since retry returns {:delay, ms}
      refute updated_request.options[:retry_delay]
      assert updated_request.options[:retry_log_level] == false
    end
  end

  describe "should_retry?/2" do
    test "returns {:delay, 0} for socket closed error" do
      request = Req.new()
      error = %Req.TransportError{reason: :closed}

      assert Retry.should_retry?(request, error) == {:delay, 0}
    end

    test "returns {:delay, 0} for timeout error" do
      request = Req.new()
      error = %Req.TransportError{reason: :timeout}

      assert Retry.should_retry?(request, error) == {:delay, 0}
    end

    test "returns {:delay, 0} for econnrefused error" do
      request = Req.new()
      error = %Req.TransportError{reason: :econnrefused}

      assert Retry.should_retry?(request, error) == {:delay, 0}
    end

    test "returns false for non-transient transport errors" do
      request = Req.new()
      error = %Req.TransportError{reason: :nxdomain}

      assert Retry.should_retry?(request, error) == false
    end

    test "returns false for non-transport errors" do
      request = Req.new()
      error = %RuntimeError{message: "Some application error"}

      assert Retry.should_retry?(request, error) == false
    end

    test "returns false for HTTP error responses" do
      request = Req.new()
      response = %Req.Response{status: 500, body: "Internal Server Error"}

      assert Retry.should_retry?(request, response) == false
    end

    test "returns false for successful responses" do
      request = Req.new()
      response = %Req.Response{status: 200, body: "OK"}

      assert Retry.should_retry?(request, response) == false
    end
  end

  describe "integration with ReqLLM.Provider.Defaults" do
    test "retry configuration is automatically applied to provider requests" do
      # Verify that when we create a request through Provider.Defaults,
      # it has retry configured
      {:ok, model} = ReqLLM.model("openai:gpt-4")

      request =
        ReqLLM.Provider.Defaults.default_attach(
          ReqLLM.Providers.OpenAI,
          Req.new(),
          model,
          api_key: "test-key"
        )

      # Verify retry is configured
      assert is_function(request.options[:retry], 2)
      assert request.options[:max_retries] == 3
      # Note: retry_delay should NOT be set since retry returns {:delay, ms}
      refute request.options[:retry_delay]
    end

    test "retry function correctly identifies retryable errors" do
      {:ok, model} = ReqLLM.model("openai:gpt-4")

      request =
        ReqLLM.Provider.Defaults.default_attach(
          ReqLLM.Providers.OpenAI,
          Req.new(),
          model,
          api_key: "test-key"
        )

      retry_fn = request.options[:retry]

      # Test retryable errors
      assert retry_fn.(request, %Req.TransportError{reason: :closed}) == {:delay, 0}
      assert retry_fn.(request, %Req.TransportError{reason: :timeout}) == {:delay, 0}
      assert retry_fn.(request, %Req.TransportError{reason: :econnrefused}) == {:delay, 0}

      # Test non-retryable errors
      assert retry_fn.(request, %RuntimeError{message: "error"}) == false
      assert retry_fn.(request, %Req.Response{status: 500}) == false
    end
  end
end
