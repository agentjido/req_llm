defmodule ReqLLM.Providers.GoogleVertex.TimeoutTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Providers.GoogleVertex

  test "preserves model-based receive_timeout defaults" do
    for {reasoning?, timeout} <- [{false, 60_000}, {true, 180_000}] do
      assert {:ok, request} = prepare_request(reasoning?)
      assert request.options.receive_timeout == timeout
    end
  end

  for timeout <- [240_000, :infinity] do
    test "honors an explicit receive_timeout of #{timeout}" do
      for reasoning? <- [false, true] do
        assert {:ok, request} =
                 prepare_request(reasoning?, receive_timeout: unquote(timeout))

        assert request.options.receive_timeout == unquote(timeout)
      end
    end
  end

  test "preserves req_http_options precedence over the top-level receive_timeout" do
    assert {:ok, request} =
             prepare_request(true,
               receive_timeout: 240_000,
               req_http_options: [receive_timeout: 300_000]
             )

    assert request.options.receive_timeout == 300_000
  end

  defp prepare_request(reasoning?, opts \\ []) do
    model = %LLMDB.Model{
      id: "gemini-2.5-flash",
      provider: :google_vertex,
      capabilities: %{chat: true, reasoning: %{enabled: reasoning?}}
    }

    GoogleVertex.prepare_request(
      :chat,
      model,
      "Hello",
      Keyword.merge([access_token: "test-token", project_id: "test-project"], opts)
    )
  end
end
