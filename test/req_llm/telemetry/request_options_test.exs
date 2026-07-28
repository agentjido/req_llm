defmodule ReqLLM.Telemetry.RequestOptionsTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Telemetry.RequestOptions

  describe "extract/2" do
    test "drops nil values" do
      assert RequestOptions.extract(:sync, []) == %{stream?: false}
    end

    test "stamps stream? true when mode is :stream" do
      assert RequestOptions.extract(:stream, []) == %{stream?: true}
    end

    test "promotes scalar inference parameters" do
      result =
        RequestOptions.extract(:sync,
          temperature: 0.7,
          top_p: 0.9,
          max_tokens: 1024,
          seed: 42
        )

      assert result.temperature == 0.7
      assert result.top_p == 0.9
      assert result.max_tokens == 1024
      assert result.seed == 42
    end

    test "normalizes stop_sequences from :stop or :stop_sequences (string or list)" do
      assert %{stop_sequences: ["END"]} =
               RequestOptions.extract(:sync, stop: "END")

      assert %{stop_sequences: ["A", "B"]} =
               RequestOptions.extract(:sync, stop_sequences: ["A", "B"])
    end

    test "drops invalid choice counts" do
      assert :n not in Map.keys(RequestOptions.extract(:sync, n: 0))
      assert :n not in Map.keys(RequestOptions.extract(:sync, n: "two"))
      assert %{n: 3} = RequestOptions.extract(:sync, n: 3)
    end

    test "wraps single encoding_format binary into a list" do
      assert %{encoding_formats: ["float"]} =
               RequestOptions.extract(:sync, encoding_format: "float")
    end

    test "passes encoding_format list through unchanged" do
      assert %{encoding_formats: ["float", "base64"]} =
               RequestOptions.extract(:sync, encoding_format: ["float", "base64"])
    end

    test "reads conversation_id from telemetry opt (keyword or map, atom or string key)" do
      assert %{conversation_id: "tid-1"} =
               RequestOptions.extract(:sync, telemetry: [conversation_id: "tid-1"])

      assert %{conversation_id: "tid-2"} =
               RequestOptions.extract(:sync, telemetry: %{"conversation_id" => "tid-2"})
    end

    test "service_tier falls back to provider_options" do
      assert %{service_tier: "priority"} =
               RequestOptions.extract(:sync, provider_options: [service_tier: "priority"])

      # top-level wins
      assert %{service_tier: "default"} =
               RequestOptions.extract(:sync,
                 service_tier: "default",
                 provider_options: [service_tier: "priority"]
               )
    end

    test "includes model-call timeout and retry controls" do
      assert %{
               receive_timeout: 5_000,
               total_timeout: 60_000,
               stream_idle_timeout: 10_000,
               max_retries: 2
             } =
               RequestOptions.extract(:stream,
                 receive_timeout: 5_000,
                 total_timeout: 60_000,
                 stream_idle_timeout: 10_000,
                 max_retries: 2
               )
    end
  end
end
