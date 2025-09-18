defmodule ReqLLM.Step.ErrorTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Error.API
  alias ReqLLM.Step.Error

  # Shared helpers
  defp mock_response(status, body) do
    %Req.Response{status: status, body: body}
  end

  defp assert_request_preserved(original_req, updated_req, additional_checks) do
    for {field, value} <- Map.from_struct(original_req) do
      case field do
        :error_steps ->
          for check <- additional_checks, do: check.(updated_req)

        _ ->
          assert Map.get(updated_req, field) == value
      end
    end
  end

  defp assert_error_structure(
         error,
         expected_status,
         expected_reason,
         request_body,
         response_body
       ) do
    assert %API.Request{} = error
    assert error.status == expected_status
    assert error.reason == expected_reason
    assert error.request_body == request_body
    assert error.response_body == response_body
    assert error.cause == nil
  end

  describe "attach/1" do
    test "attaches splode error step and preserves request structure" do
      request = %Req.Request{
        options: [test: "value"],
        headers: [{"content-type", "application/json"}]
      }

      updated_request = Error.attach(request)

      assert_request_preserved(request, updated_request, [
        fn req -> assert Keyword.has_key?(req.error_steps, :splode_errors) end,
        fn req -> assert req.error_steps[:splode_errors] == (&Error.handle/1) end
      ])
    end
  end

  describe "handle/1 with HTTP response errors" do
    @http_status_cases [
      # {status, api_error_body}
      {400, ~s({"error": "Invalid request format"})},
      {401, ~s({"error": {"message": "Invalid API key"}})},
      {403, ~s({"message": "Quota exceeded"})},
      {404, ~s({"detail": "Endpoint not found"})},
      {429, ~s({"details": "Too many requests per minute"})}
    ]

    test "handles specific HTTP status codes with API messages" do
      request = %Req.Request{body: ~s({"query": "test"})}

      for {status, api_body} <- @http_status_cases do
        response = mock_response(status, api_body)
        {_request, error} = Error.handle({request, response})

        # Extract expected message from API body
        expected_message =
          case Jason.decode(api_body) do
            {:ok, %{"error" => %{"message" => msg}}} -> msg
            {:ok, %{"error" => msg}} when is_binary(msg) -> msg
            {:ok, %{"message" => msg}} -> msg
            {:ok, %{"detail" => msg}} -> msg
            {:ok, %{"details" => msg}} -> msg
            _ -> api_body
          end

        assert_error_structure(error, status, expected_message, ~s({"query": "test"}), api_body)
      end
    end

    test "handles unknown HTTP status codes" do
      request = %Req.Request{}
      response = mock_response(418, "I'm a teapot")

      {_request, error} = Error.handle({request, response})

      assert_error_structure(error, 418, "HTTP Error 418", nil, "I'm a teapot")
    end

    test "handles 5xx server errors with default message" do
      request = %Req.Request{}

      for status <- [500, 501, 502, 503, 504, 505, 520, 599] do
        response = mock_response(status, ~s({"error": "Internal server error"}))
        {_request, error} = Error.handle({request, response})

        assert_error_structure(
          error,
          status,
          "Internal server error",
          nil,
          ~s({"error": "Internal server error"})
        )
      end
    end

    test "falls back to default messages when no API error found" do
      request = %Req.Request{}

      # Test default fallback for known status codes
      default_cases = [
        {400, "Bad Request - Invalid parameters or malformed request"},
        {401, "Unauthorized - Invalid or missing API key"},
        {403, "Forbidden - Insufficient permissions or quota exceeded"},
        {404, "Not Found - Endpoint or resource not found"},
        {429, "Rate Limited - Too many requests"}
      ]

      for {status, expected_default} <- default_cases do
        response = mock_response(status, ~s({"some_other_field": "value"}))
        {_request, error} = Error.handle({request, response})

        assert_error_structure(
          error,
          status,
          expected_default,
          nil,
          ~s({"some_other_field": "value"})
        )
      end
    end

    test "handles server errors without API message" do
      request = %Req.Request{}
      response = mock_response(502, "Bad Gateway")

      {_request, error} = Error.handle({request, response})

      assert_error_structure(error, 502, "Server Error - Internal API error", nil, "Bad Gateway")
    end
  end

  describe "handle/1 with exceptions" do
    @exception_cases [
      {%RuntimeError{message: "Connection timeout"}, "Connection timeout"},
      {%Req.TransportError{reason: :nxdomain},
       Exception.message(%Req.TransportError{reason: :nxdomain})},
      {%Req.TransportError{reason: :cert_expired},
       Exception.message(%Req.TransportError{reason: :cert_expired})}
    ]

    test "handles various network exceptions" do
      request = %Req.Request{body: ~s({"test": "data"})}

      for {exception, expected_reason} <- @exception_cases do
        {_request, error} = Error.handle({request, exception})

        assert %API.Request{} = error
        assert error.status == nil
        assert error.reason == expected_reason
        assert error.response_body == nil
        assert error.request_body == ~s({"test": "data"})
        assert error.cause == exception
      end
    end
  end

  describe "API error message extraction" do
    @error_field_cases [
      # {json_body, expected_message}
      {~s({"error": {"message": "Missing required parameter: model"}}),
       "Missing required parameter: model"},
      {~s({"error": "Invalid JSON format"}), "Invalid JSON format"},
      {~s({"message": "Validation failed"}), "Validation failed"},
      {~s({"detail": "Resource not found"}), "Resource not found"},
      {~s({"details": "Rate limit exceeded"}), "Rate limit exceeded"},
      {~s({"error_description": "The request was malformed"}), "The request was malformed"}
    ]

    test "extracts error messages from various API response formats" do
      request = %Req.Request{}

      for {json_body, expected_message} <- @error_field_cases do
        response = mock_response(400, json_body)
        {_request, error} = Error.handle({request, response})

        assert error.reason == expected_message
      end
    end

    test "handles malformed and edge case response bodies" do
      request = %Req.Request{}

      # Test various edge cases
      edge_cases = [
        # {body, expected_reason}
        {"Internal Server Error (not JSON)", "Server Error - Internal API error"},
        # non-string body
        {%{"error" => "some error"}, "some error"},
        # empty body
        {"", "Server Error - Internal API error"},
        # nil body
        {nil, "Bad Request - Invalid parameters or malformed request"}
      ]

      for {body, expected_reason} <- edge_cases do
        status = if is_nil(body) or body == "", do: if(body == "", do: 503, else: 400), else: 500
        response = %Req.Response{status: status, body: body}
        {_request, error} = Error.handle({request, response})

        assert error.reason == expected_reason
      end
    end

    test "handles non-string message values" do
      request = %Req.Request{}
      response = mock_response(400, ~s({"error": {"message": 123}}))

      {_request, error} = Error.handle({request, response})

      # Should fall back to default since message is not a string
      assert error.reason == "Bad Request - Invalid parameters or malformed request"
    end

    test "preserves request and response data for debugging" do
      request_body = ~s({"model": "test", "messages": []})
      response_body = ~s({"error": {"message": "Model not found"}})

      request = %Req.Request{body: request_body}
      response = %Req.Response{status: 404, body: response_body}

      {_request, error} = Error.handle({request, response})

      assert error.request_body == request_body
      assert error.response_body == response_body
      assert error.status == 404
      assert error.reason == "Model not found"
    end
  end

  describe "Req pipeline integration" do
    test "error step works in Req pipeline" do
      request = %Req.Request{}
      updated_request = Error.attach(request)

      mock_response = %Req.Response{
        status: 500,
        body: ~s({"error": "Server overloaded"})
      }

      error_step_fun = updated_request.error_steps[:splode_errors]
      {_request, error} = error_step_fun.({updated_request, mock_response})

      assert %API.Request{} = error
      assert error.status == 500
      assert error.reason == "Server overloaded"
    end
  end
end
