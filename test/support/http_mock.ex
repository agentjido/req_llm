defmodule ReqLLM.Test.HTTPMock do
  @moduledoc """
  Global HTTP mock system for ReqLLM tests.

  Automatically injects Req.Test global mock for non-coverage tests,
  providing generic request handling based on host/endpoint patterns
  and loading JSON fixtures from test/fixtures/<provider>/ directories.
  """

  @doc """
  Sets up the global HTTP mock if conditions are met.

  Skips mocking for:
  - Tests in test/coverage/ folder
  - When LIVE=true environment variable is set
  """
  def setup_global_mock do
    if should_mock?() do
      Req.Test.stub(:global, &handle_request/1)
    end
  end

  defp should_mock? do
    # Don't mock if LIVE=true
    if System.get_env("LIVE") == "true", do: false, else: true
  end

  defp handle_request(%Req.Request{url: %URI{host: host, path: path}} = request) do
    case determine_provider(host) do
      {:ok, provider} ->
        handle_provider_request(provider, path, request)

      :error ->
        # Return a generic error for unknown hosts
        Req.Response.new(
          status: 404,
          headers: [{"content-type", "application/json"}],
          body: %{"error" => "Mock not configured for host: #{host}"}
        )
    end
  end

  defp determine_provider(host) do
    case host do
      "api.openai.com" -> {:ok, :openai}
      "api.anthropic.com" -> {:ok, :anthropic}
      "api.groq.com" -> {:ok, :groq}
      "generativelanguage.googleapis.com" -> {:ok, :google}
      "openrouter.ai" -> {:ok, :openrouter}
      "api.x.ai" -> {:ok, :xai}
      _ -> :error
    end
  end

  defp handle_provider_request(provider, path, request) do
    fixture_name = generate_fixture_name(provider, path, request)

    case load_fixture(provider, fixture_name) do
      {:ok, fixture_data} ->
        create_response_from_fixture(fixture_data)

      {:error, _reason} ->
        # Return a default successful response if no fixture is found
        default_response(provider, path, request)
    end
  end

  defp generate_fixture_name(_provider, path, request) do
    # Create a fixture name based on provider, path, and request method
    method = String.downcase(to_string(request.method))
    path_key = path |> String.replace("/", "_") |> String.replace(".", "")

    "#{method}#{path_key}"
  end

  defp load_fixture(provider, fixture_name) do
    fixture_path =
      Path.join([
        "test",
        "fixtures",
        to_string(provider),
        "#{fixture_name}.json"
      ])

    case File.read(fixture_path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, data} -> {:ok, data}
          {:error, reason} -> {:error, {:json_decode, reason}}
        end

      {:error, reason} ->
        {:error, {:file_read, reason}}
    end
  end

  defp create_response_from_fixture(fixture_data) do
    # Handle streaming responses
    if is_streaming_fixture?(fixture_data) do
      create_streaming_response(fixture_data)
    else
      create_standard_response(fixture_data)
    end
  end

  defp is_streaming_fixture?(fixture_data) when is_map(fixture_data) do
    Map.has_key?(fixture_data, "chunks") ||
      Map.has_key?(fixture_data, "stream") ||
      (Map.has_key?(fixture_data, "object") && fixture_data["object"] == "chat.completion.chunk")
  end

  defp is_streaming_fixture?(_), do: false

  defp create_streaming_response(fixture_data) do
    chunks =
      cond do
        Map.has_key?(fixture_data, "chunks") ->
          fixture_data["chunks"]

        Map.has_key?(fixture_data, "stream") ->
          fixture_data["stream"]

        true ->
          [fixture_data]
      end

    # Convert chunks to Server-Sent Events format
    stream_body =
      chunks
      |> Enum.map_join(fn chunk ->
        "data: #{Jason.encode!(chunk)}\n\n"
      end)
      |> Kernel.<>("data: [DONE]\n\n")

    Req.Response.new(
      status: 200,
      headers: [
        {"content-type", "text/plain; charset=utf-8"},
        {"cache-control", "no-cache"},
        {"connection", "keep-alive"}
      ],
      body: stream_body
    )
  end

  defp create_standard_response(fixture_data) do
    status = Map.get(fixture_data, "status", 200)
    headers = Map.get(fixture_data, "headers", [{"content-type", "application/json"}])
    body = Map.get(fixture_data, "body", fixture_data)

    Req.Response.new(
      status: status,
      headers: headers,
      body: body
    )
  end

  defp default_response(provider, path, request) do
    # Provide sensible defaults based on common API patterns
    default_body =
      case {provider, path, request.method} do
        {:openai, "/v1/chat/completions", :post} ->
          %{
            "id" => "chatcmpl-mock",
            "object" => "chat.completion",
            "created" => System.system_time(:second),
            "model" => "gpt-4",
            "choices" => [
              %{
                "index" => 0,
                "message" => %{
                  "role" => "assistant",
                  "content" => "Mock response from HTTP mock system"
                },
                "finish_reason" => "stop"
              }
            ],
            "usage" => %{
              "prompt_tokens" => 10,
              "completion_tokens" => 8,
              "total_tokens" => 18
            }
          }

        {:anthropic, "/v1/messages", :post} ->
          %{
            "id" => "msg_mock",
            "type" => "message",
            "role" => "assistant",
            "content" => [
              %{
                "type" => "text",
                "text" => "Mock response from HTTP mock system"
              }
            ],
            "model" => "claude-3-sonnet-20240229",
            "stop_reason" => "end_turn",
            "stop_sequence" => nil,
            "usage" => %{
              "input_tokens" => 10,
              "output_tokens" => 8
            }
          }

        _ ->
          %{"message" => "Mock response", "provider" => provider, "path" => path}
      end

    Req.Response.new(
      status: 200,
      headers: [{"content-type", "application/json"}],
      body: default_body
    )
  end
end
