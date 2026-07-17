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

    test "preserves max_retries already configured on the request" do
      request = Req.new(max_retries: 0)

      assert Retry.attach(request).options[:max_retries] == 0
    end
  end

  describe "attach/2" do
    test "honors max_retries in the real Req pipeline" do
      for {max_retries, expected_attempts} <- [{0, 1}, {1, 2}] do
        parent = self()

        request =
          Req.new(
            url: "https://example.invalid",
            adapter: fn request ->
              send(parent, :attempt)
              {request, %Req.TransportError{reason: :closed}}
            end
          )
          |> Retry.attach(max_retries: max_retries)

        assert {:error, %Req.TransportError{reason: :closed}} = Req.request(request)

        Enum.each(1..expected_attempts, fn _attempt ->
          assert_receive :attempt
        end)

        refute_receive :attempt, 20
      end
    end

    test "emits completed attempt timing before a retry" do
      test_pid = self()
      handler_id = {__MODULE__, self(), make_ref()}
      conversation_id = "retry-timing-#{System.unique_integer([:positive])}"
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      :ok =
        :telemetry.attach(
          handler_id,
          [:req_llm, :request, :retry],
          fn event, measurements, metadata, pid ->
            if get_in(metadata, [:request_options, :conversation_id]) == conversation_id do
              send(pid, {:retry_telemetry, event, measurements, metadata})
            end
          end,
          test_pid
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      request =
        Req.new(
          url: "https://example.invalid",
          adapter: fn request ->
            attempt = Agent.get_and_update(counter, fn value -> {value, value + 1} end)

            if attempt == 0 do
              {request, %Req.TransportError{reason: :closed}}
            else
              {request, %Req.Response{status: 200, body: "ok"}}
            end
          end
        )
        |> Retry.attach(max_retries: 1)
        |> ReqLLM.Step.Telemetry.attach(
          %LLMDB.Model{provider: :test, id: "retry-model"},
          max_retries: 1,
          telemetry: [conversation_id: conversation_id]
        )

      assert {:ok, %Req.Response{status: 200}} = Req.request(request)

      assert_receive {:retry_telemetry, [:req_llm, :request, :retry], measurements, metadata}
      assert measurements.duration >= 0
      assert metadata.retry.attempt == 1
      assert metadata.retry.next_attempt == 2
      assert metadata.retry.max_retries == 1
      assert metadata.retry.delay == 0
      assert metadata.retry.http_status == nil
    end

    test "does not emit retry timing after the retry budget is exhausted" do
      test_pid = self()
      handler_id = {__MODULE__, self(), make_ref()}
      conversation_id = "retry-exhausted-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler_id,
          [:req_llm, :request, :retry],
          fn event, measurements, metadata, pid ->
            if get_in(metadata, [:request_options, :conversation_id]) == conversation_id do
              send(pid, {:retry_telemetry, event, measurements, metadata})
            end
          end,
          test_pid
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      request =
        Req.new(
          url: "https://example.invalid",
          adapter: fn request -> {request, %Req.TransportError{reason: :closed}} end
        )
        |> Retry.attach(max_retries: 0)
        |> ReqLLM.Step.Telemetry.attach(
          %LLMDB.Model{provider: :test, id: "retry-model"},
          max_retries: 0,
          telemetry: [conversation_id: conversation_id]
        )

      assert {:error, %Req.TransportError{reason: :closed}} = Req.request(request)
      refute_receive {:retry_telemetry, [:req_llm, :request, :retry], _, _}
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

    test "returns {:delay, 0} for a transient transport error wrapped in ReqLLM.Error.API.Request" do
      request = Req.new()

      for reason <- [:closed, :timeout, :econnrefused] do
        wrapped = %ReqLLM.Error.API.Request{cause: %Finch.TransportError{reason: reason}}
        assert Retry.should_retry?(request, wrapped) == {:delay, 0}
      end
    end

    test "returns false for a non-transient transport error wrapped in ReqLLM.Error.API.Request" do
      request = Req.new()
      wrapped = %ReqLLM.Error.API.Request{cause: %Finch.TransportError{reason: :nxdomain}}

      assert Retry.should_retry?(request, wrapped) == false
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

    test "returns retry-after delay for 429 responses with list headers" do
      request = Req.new()
      response = %Req.Response{status: 429, headers: [{"retry-after", "2"}]}

      assert Retry.should_retry?(request, response) == {:delay, 2_000}
    end

    test "returns retry-after delay for 429 responses with map headers" do
      request = Req.new()
      response = %Req.Response{status: 429, headers: %{"retry-after" => ["3"]}}

      assert Retry.should_retry?(request, response) == {:delay, 3_000}
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

    test "default_attach preserves an existing finch option" do
      {:ok, model} = ReqLLM.model("openai:gpt-4")

      request =
        ReqLLM.Provider.Defaults.default_attach(
          ReqLLM.Providers.OpenAI,
          Req.new(finch: :custom_finch),
          model,
          api_key: "test-key"
        )

      assert request.options[:finch] == :custom_finch
    end

    test "default_attach preserves caller max_retries" do
      {:ok, model} = ReqLLM.model("openai:gpt-4")

      request =
        ReqLLM.Provider.Defaults.default_attach(
          ReqLLM.Providers.OpenAI,
          Req.new(),
          model,
          api_key: "test-key",
          max_retries: 0
        )

      assert request.options[:max_retries] == 0
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
