defmodule ReqLLM.Providers.OpenAICacheDiagnosticsTest do
  use ExUnit.Case, async: true

  alias ReqLLM.{Context, Providers.OpenAI}

  test "Responses sends the comparison ID and preserves buffered diagnostics" do
    model = ReqLLM.model!(%{provider: :openai, id: "gpt-6.1-sol"})
    options = %{comparison_response_id: "resp_baseline"}

    assert {:ok, request} =
             OpenAI.prepare_request(:chat, model, "Check cache",
               api_key: "test-key",
               provider_options: [prompt_cache_options: options]
             )

    request = OpenAI.encode_body(request)

    assert Jason.decode!(request.body)["prompt_cache_options"] ==
             %{"comparison_response_id" => "resp_baseline"}

    diagnostics = %{
      "type" => "cache_miss",
      "reason" => "tools_changed",
      "comparison_reusable_tokens" => 5629,
      "cache_missed_tokens" => 5629
    }

    body = %{
      "id" => "resp_current",
      "model" => model.id,
      "output" => [],
      "prompt_cache_diagnostics" => diagnostics,
      "usage" => %{
        "input_tokens" => 6000,
        "output_tokens" => 1,
        "input_tokens_details" => %{"cached_tokens" => 0}
      }
    }

    {_, response} =
      OpenAI.ResponsesAPI.decode_response({request, Req.Response.new(status: 200, body: body)})

    assert response.body.provider_meta["prompt_cache_diagnostics"] == diagnostics
    assert response.body.usage.input_tokens == 6000
  end

  test "stream completion preserves all diagnostic result types" do
    model = ReqLLM.model!(%{provider: :openai, id: "gpt-6.1-sol"})

    for type <- ~w(cache_hit cache_miss comparison_response_not_found unavailable) do
      diagnostics = %{"type" => type}

      event = %{
        data: %{
          "type" => "response.completed",
          "response" => %{
            "id" => "resp_current",
            "output" => [],
            "prompt_cache_diagnostics" => diagnostics,
            "usage" => %{
              "input_tokens" => 2500,
              "output_tokens" => 1,
              "input_tokens_details" => %{"cached_tokens" => 2000}
            }
          }
        }
      }

      {chunks, _} = OpenAI.ResponsesAPI.decode_stream_event(event, model, nil)

      assert {:ok, response} =
               OpenAI.ResponsesAPI.ResponseBuilder.build_response(chunks, hd(chunks).metadata,
                 model: model,
                 context: Context.new([])
               )

      assert response.provider_meta["prompt_cache_diagnostics"] == diagnostics
      assert response.usage.input_tokens == 2500
    end
  end
end
