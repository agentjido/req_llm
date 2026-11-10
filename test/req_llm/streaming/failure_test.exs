defmodule ReqLLM.Streaming.FailureTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ReqLLM.Streaming.Failure

  test "classifies structured HTTP failures as retryable provider/API failures" do
    error =
      Failure.api_error(
        429,
        ~s({"error":{"code":"traffic_queue_timeout","message":"traffic queue wait expired"}}),
        [{"retry-after", "1"}]
      )

    assert error.status == 429
    assert error.provider_code == "traffic_queue_timeout"
    assert error.retryable == true
    assert error.reason == "traffic queue wait expired"

    assert {:api, 429, "traffic_queue_timeout", true} = Failure.classify(error)

    log = capture_log(fn -> Failure.log(error) end)

    assert log =~ "[warning]"
    assert log =~ "Streaming provider/API request failed"
    assert log =~ "status=429"
    assert log =~ "provider_code=\"traffic_queue_timeout\""
    refute log =~ "Finch streaming failed"
  end

  test "marks streamed 503 responses as retryable API failures" do
    error = Failure.api_error(503, ~s({"error":{"code":"overloaded"}}), [])

    assert {:api, 503, "overloaded", true} = Failure.classify(error)
  end

  test "unwraps an array-wrapped context length error" do
    error =
      Failure.api_error(
        400,
        Jason.encode!([
          %{
            "error" => %{
              "code" => 400,
              "message" =>
                "The input token count exceeds the maximum number of tokens allowed 1048576.",
              "status" => "INVALID_ARGUMENT"
            }
          }
        ]),
        []
      )

    assert error.reason ==
             "The input token count exceeds the maximum number of tokens allowed 1048576."

    assert error.provider_code == 400
    assert error.kind == :context_length_exceeded

    assert error.response_body == %{
             "code" => 400,
             "message" =>
               "The input token count exceeds the maximum number of tokens allowed 1048576.",
             "status" => "INVALID_ARGUMENT"
           }
  end

  test "normalizes the OpenAI context length error code" do
    error =
      Failure.api_error(
        400,
        ~s({"error":{"code":"context_length_exceeded","message":"Input is too long"}}),
        []
      )

    assert error.kind == :context_length_exceeded
  end

  test "preserves an unmatched singleton array body" do
    error = Failure.api_error(400, ~s([{"message":"not an error wrapper"}]), [])

    assert error.reason == "HTTP 400"
    assert error.response_body == [%{"message" => "not an error wrapper"}]
  end

  test "does not classify an unrelated invalid request as a context length error" do
    error =
      Failure.api_error(
        400,
        ~s({"error":{"code":400,"message":"The request is invalid","status":"INVALID_ARGUMENT"}}),
        []
      )

    assert error.kind == nil
  end

  test "preserves a plain-text provider response as the failure reason" do
    error = Failure.api_error(429, "rate limit exceeded", [], use_body_as_reason?: true)

    assert error.reason == "rate limit exceeded"
    assert error.response_body == "rate limit exceeded"
  end

  test "classifies Finch errors backed by Mint as transport failures" do
    error = %Finch.TransportError{source: %Mint.TransportError{reason: :closed}}

    assert {:transport, :closed, true} = Failure.classify(error)
    assert {:transport, :closed, true} = Failure.classify({:error, error})

    log = capture_log(fn -> Failure.log(error) end)

    assert log =~ "[error]"
    assert log =~ "Finch streaming transport failed"
    assert log =~ "reason=:closed"
  end

  test "treats expected cancellation as a non-logged terminal outcome" do
    assert :cancelled = Failure.classify({:exit, :cancelled})

    assert capture_log(fn -> Failure.log({:exit, :cancelled}) end) == ""
  end
end
