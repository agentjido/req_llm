defmodule Provider.OpenAI.ResponsesAPI.UsageTest do
  use ExUnit.Case, async: false

  import ReqLLM.Test.OpenAI.ResponsesAPIHelpers, only: [build_response: 2]

  alias ReqLLM.Providers.OpenAI.ResponsesAPI

  describe "usage billing parity" do
    test "accepts integer strings in token and hosted tool counts" do
      usage = %{
        "input_tokens" => "10",
        "output_tokens" => "20",
        "input_tokens_details" => %{"cached_tokens" => "4", "cache_write_tokens" => "6"},
        "output_tokens_details" => %{"reasoning_tokens" => "5"},
        "server_side_tool_usage_details" => %{
          "web_search_calls" => "2",
          "unrelated" => "ignored"
        }
      }

      for parsed <- parsed_response_usages(usage) do
        assert parsed.input_tokens == 10
        assert parsed.output_tokens == 20
        assert parsed.total_tokens == 30
        assert parsed.cached_tokens == 4
        assert parsed.cache_creation_tokens == 6
        assert parsed.reasoning_tokens == 5
        assert parsed.usage_reported == %{input: true, output: true}
        assert parsed.tool_usage == %{web_search: %{count: 2, unit: :call}}
      end
    end

    test "keeps unconfirmed supplier function counts as unknown tool usage" do
      usage = %{
        "input_tokens" => 10,
        "output_tokens" => 20,
        "server_side_tool_usage_details" => %{"function_calls" => 3}
      }

      for parsed <- parsed_response_usages(usage) do
        assert parsed.tool_usage == %{"function" => %{count: 3, unit: :call}}

        assert {:ok, nil} =
                 ReqLLM.Billing.calculate(ReqLLM.Usage.normalize(parsed), billing_model())
      end
    end

    test "keeps malformed counters visible without unsafe total arithmetic" do
      for input <- ["invalid", false, %{}],
          parsed <- parsed_response_usages(%{"input_tokens" => input, "output_tokens" => 3}) do
        assert parsed.input_tokens === input
        assert parsed.output_tokens == 3
        assert parsed.total_tokens == nil

        assert {:ok, nil} =
                 ReqLLM.Billing.calculate(ReqLLM.Usage.normalize(parsed), billing_model())
      end
    end

    test "missing counters remain unreported" do
      for usage <- [nil, "invalid", %{}, %{"input_tokens" => 10}],
          parsed <- parsed_response_usages(usage) do
        assert parsed.usage_reported.output == false

        assert {:ok, nil} =
                 ReqLLM.Billing.calculate(ReqLLM.Usage.normalize(parsed), billing_model())
      end
    end

    test "malformed token and hosted tool details prevent a complete estimate" do
      for {key, value} <- [
            {"input_tokens_details", "invalid"},
            {"output_tokens_details", false},
            {"input_tokens_details", %{"cached_tokens" => false}},
            {"server_side_tool_usage_details", []},
            {"server_side_tool_usage_details", %{"web_search_calls" => "invalid"}},
            {"server_side_tool_usage", %{"web_search_calls" => -1}},
            {"server_tool_use", %{"web_search_requests" => nil}}
          ],
          parsed <-
            parsed_response_usages(%{"input_tokens" => 10, "output_tokens" => 20, key => value}) do
        assert {:ok, nil} =
                 ReqLLM.Billing.calculate(ReqLLM.Usage.normalize(parsed), billing_model())
      end
    end

    test "keeps a gateway-reported cost as the total" do
      # Final usage of a LiteLLM 1.108.5 proxy stream on /v1/responses.
      usage = %{
        "input_tokens" => 8,
        "input_tokens_details" => %{"cached_tokens" => 0, "cache_write_tokens" => 0},
        "output_tokens" => 11,
        "output_tokens_details" => %{"reasoning_tokens" => 0},
        "total_tokens" => 19,
        "cost" => 7.56e-6
      }

      for parsed <- parsed_response_usages(usage) do
        assert parsed.provider_cost == %{cost: 7.56e-6, byok: false, upstream_cost: nil}

        priced =
          parsed |> ReqLLM.Usage.normalize() |> ReqLLM.Usage.Cost.apply(billing_model())

        assert priced.total_cost == 7.56e-6
      end
    end

    test "a null gateway cost is not a reported charge" do
      for parsed <-
            parsed_response_usages(%{"input_tokens" => 8, "output_tokens" => 6, "cost" => nil}) do
        refute Map.has_key?(parsed, :provider_cost)
      end
    end

    test "streamed metadata preserves explicit invalid service tiers" do
      model = %LLMDB.Model{provider: :openai, id: "gpt-5"}

      for tier <- [nil, "", false, %{}, []] do
        response = %{"id" => "resp_123", "service_tier" => tier}

        [chunk] =
          ResponsesAPI.decode_stream_event(
            %{data: %{"type" => "response.completed", "response" => response}},
            model
          )

        assert Map.has_key?(chunk.metadata.provider_meta, "service_tier")
        assert chunk.metadata.provider_meta["service_tier"] === tier
      end
    end

    test "malformed terminal response metadata keeps its terminal flag" do
      model = %LLMDB.Model{provider: :openai, id: "gpt-5"}

      for type <- ["response.completed", "response.incomplete", "response.failed"],
          response <- [nil, false, "invalid", []] do
        [chunk] =
          ResponsesAPI.decode_stream_event(
            %{data: %{"type" => type, "response" => response}},
            model
          )

        assert chunk.metadata.terminal? == true
        refute Map.has_key?(chunk.metadata, :usage)
      end
    end
  end

  defp parsed_response_usages(usage) do
    model = %LLMDB.Model{provider: :openai, id: "gpt-5"}

    response = %{
      "id" => "resp_123",
      "model" => "gpt-5",
      "output_text" => "Hello",
      "usage" => usage
    }

    {_req, buffered} = ResponsesAPI.decode_response(build_response(200, response))

    events = [
      %{"type" => "response.usage", "usage" => usage},
      %{"type" => "response.completed", "response" => response},
      %{"type" => "response.incomplete", "response" => response},
      %{"type" => "response.failed", "response" => response}
    ]

    streamed =
      Enum.map(events, fn event ->
        [chunk] = ResponsesAPI.decode_stream_event(%{data: event}, model)
        chunk.metadata.usage
      end)

    [buffered.body.usage | streamed]
  end

  defp billing_model do
    %LLMDB.Model{
      provider: :openai,
      id: "parser-test",
      pricing: %{
        components: [
          %{id: "token.input", kind: "token", per: 1_000_000, rate: 1.0},
          %{id: "token.output", kind: "token", per: 1_000_000, rate: 1.0}
        ]
      }
    }
  end
end
