defmodule ReqLLM.Providers.Google.OptionsTest do
  @moduledoc """
  Google provider option validation, translation, and encoding.
  """

  use ReqLLM.ProviderCase, provider: ReqLLM.Providers.Google, async: true

  alias ReqLLM.Providers.Google

  describe "labels option" do
    test "encode_body includes labels as a top-level field in chat body" do
      {:ok, model} = ReqLLM.model("google:gemini-1.5-flash")
      context = context_fixture()

      labels = %{"team" => "engineering", "environment" => "production"}

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          labels: labels
        ]
      }

      updated_request = Google.encode_body(mock_request)
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      # labels must be top-level, not nested in generationConfig
      assert decoded["labels"] == labels
      refute Map.has_key?(decoded["generationConfig"] || %{}, "labels")
    end

    test "encode_body omits labels when not provided" do
      {:ok, model} = ReqLLM.model("google:gemini-1.5-flash")
      context = context_fixture()

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false
        ]
      }

      updated_request = Google.encode_body(mock_request)
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      refute Map.has_key?(decoded, "labels")
    end

    test "encode_body includes labels in object (JSON mode) body" do
      {:ok, model} = ReqLLM.model("google:gemini-1.5-flash")
      context = context_fixture()
      {:ok, schema} = ReqLLM.Schema.compile(name: [type: :string, required: true])

      labels = %{"use_case" => "extraction", "team" => "data"}

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          operation: :object,
          compiled_schema: schema,
          max_tokens: 500,
          labels: labels
        ]
      }

      updated_request = Google.encode_body(mock_request)
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      assert decoded["labels"] == labels
    end
  end

  describe "google_url_context option" do
    test "encode_body includes url_context tool when boolean true" do
      {:ok, model} = ReqLLM.model("google:gemini-2.0-flash")
      context = context_fixture()

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          google_url_context: true
        ]
      }

      updated_request = Google.encode_body(mock_request)
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      assert is_list(decoded["tools"])
      assert length(decoded["tools"]) == 1
      [tool] = decoded["tools"]
      assert Map.has_key?(tool, "url_context")
      assert tool["url_context"] == %{}
    end

    test "options pipeline accepts an empty map and rejects a non-empty map" do
      model = ReqLLM.model!("google:gemini-2.5-flash")

      for opts <- [
            [google_url_context: %{}],
            [provider_options: [google_url_context: %{}]]
          ] do
        validated = ReqLLM.Provider.Options.process!(Google, :chat, model, opts)

        assert validated[:google_url_context] == true
        assert validated[:provider_options][:google_url_context] == true
      end

      assert_raise NimbleOptions.ValidationError, fn ->
        ReqLLM.Provider.Options.process!(Google, :chat, model,
          provider_options: [google_url_context: %{some_option: "value"}]
        )
      end
    end

    test "encode_body combines url_context with user tools" do
      {:ok, model} = ReqLLM.model("google:gemini-2.0-flash")
      context = context_fixture()

      tool =
        ReqLLM.Tool.new!(
          name: "test_tool",
          description: "A test tool",
          parameter_schema: [
            name: [type: :string, required: true, doc: "A name parameter"]
          ],
          callback: fn _ -> {:ok, "result"} end
        )

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          tools: [tool],
          google_url_context: true,
          operation: :chat
        ]
      }

      updated_request = Google.encode_body(mock_request)
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      assert is_list(decoded["tools"])
      assert length(decoded["tools"]) == 2

      tool_types = Enum.map(decoded["tools"], fn t -> Map.keys(t) end) |> List.flatten()
      assert "url_context" in tool_types
      assert "functionDeclarations" in tool_types
    end

    test "encode_body combines url_context with grounding" do
      {:ok, model} = ReqLLM.model("google:gemini-2.0-flash")
      context = context_fixture()

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          google_grounding: %{enable: true},
          google_url_context: true
        ]
      }

      updated_request = Google.encode_body(mock_request)
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      assert is_list(decoded["tools"])
      assert length(decoded["tools"]) == 2

      tool_types = Enum.map(decoded["tools"], fn t -> Map.keys(t) end) |> List.flatten()
      assert "url_context" in tool_types
      assert "google_search" in tool_types
    end
  end

  describe "option translation" do
    test "provider implements translate_options/3" do
      # Google implements translate_options/3 for stream? alias handling
      assert function_exported?(Google, :translate_options, 3)
    end

    test "translate_options handles stream? alias" do
      {:ok, model} = ReqLLM.model("google:gemini-1.5-flash")

      # Test stream? -> stream translation
      opts = [temperature: 0.7, stream?: true]
      {translated_opts, warnings} = Google.translate_options(:chat, model, opts)

      assert Keyword.get(translated_opts, :stream) == true
      refute Keyword.has_key?(translated_opts, :stream?)
      assert warnings == []
    end

    test "provider-specific option handling" do
      # Test that provider-specific options are present in the provider schema
      schema_keys = Google.provider_schema().schema |> Keyword.keys()

      # Test that these options are supported
      supported_opts = Google.supported_provider_options()

      for provider_option <- schema_keys do
        assert provider_option in supported_opts,
               "Expected #{provider_option} to be in supported options"
      end
    end

    test "translate_options maps reasoning_effort to google_thinking_budget" do
      {:ok, model} = ReqLLM.model("google:gemini-1.5-flash")

      test_cases = [
        {:none, 0},
        {:minimal, 2_048},
        {:low, 4_096},
        {:medium, 8_192},
        {:high, 16_384},
        {:xhigh, 32_768},
        {:max, 32_768}
      ]

      for {effort, expected_budget} <- test_cases do
        opts = [reasoning_effort: effort]
        {translated_opts, _warnings} = Google.translate_options(:chat, model, opts)

        assert Keyword.get(translated_opts, :google_thinking_budget) == expected_budget,
               "Expected reasoning_effort #{inspect(effort)} to map to budget #{expected_budget}"
      end
    end

    test "translate_options maps reasoning_effort to google_thinking_level for Gemini 3 models" do
      {:ok, model} = ReqLLM.model(%{provider: :google, id: "gemini-3-flash"})

      test_cases = [
        {:none, :minimal},
        {:minimal, :minimal},
        {:low, :low},
        {:medium, :medium},
        {:high, :high},
        {:xhigh, :high},
        {:max, :high}
      ]

      for {effort, expected_level} <- test_cases do
        opts = [reasoning_effort: effort]
        {translated_opts, _warnings} = Google.translate_options(:chat, model, opts)

        assert Keyword.get(translated_opts, :google_thinking_level) == expected_level,
               "Expected reasoning_effort #{inspect(effort)} to map to level #{inspect(expected_level)}"

        assert Keyword.get(translated_opts, :google_thinking_budget) == nil,
               "Expected no google_thinking_budget for Gemini 3 model"
      end
    end

    test "translate_options uses supported thinking levels from Gemini model metadata" do
      for model_spec <- ["google:gemini-3.7-flash", "google:gemini-3.1-pro-preview"] do
        model = ReqLLM.model!(model_spec)

        for effort <- [:none, :minimal] do
          {translated_opts, _warnings} =
            Google.translate_options(:chat, model, reasoning_effort: effort)

          assert Keyword.get(translated_opts, :google_thinking_level) == :low
          refute Keyword.has_key?(translated_opts, :google_thinking_budget)
        end
      end
    end

    test "uses known thinking constraints when explicit model specs omit metadata" do
      models = [
        LLMDB.Model.new!(%{provider: :google, id: "gemini-3.7-flash"}),
        LLMDB.Model.new!(%{
          provider: :google,
          id: "custom-gemini-pro",
          provider_model_id: "publishers/google/models/gemini-3.1-pro-preview"
        })
      ]

      for model <- models do
        assert {translated_opts, []} =
                 Google.translate_options(:chat, model, reasoning_effort: :minimal)

        assert translated_opts[:google_thinking_level] == :low

        assert {validated_opts, []} =
                 Google.pre_validate_options(:chat, model,
                   provider_options: [reasoning_effort: :minimal]
                 )

        assert validated_opts[:provider_options][:google_thinking_level] == :low
      end
    end

    test "uses structured capability metadata for supported thinking levels" do
      model =
        LLMDB.Model.new!(%{
          provider: :google,
          id: "gemini-3-custom",
          capabilities: %{
            reasoning: %{
              enabled: true,
              effort: %{supported: true, values: ["minimal", "high"]}
            }
          }
        })

      for {effort, expected_level} <- [low: :minimal, medium: :high] do
        assert {translated_opts, []} =
                 Google.translate_options(:chat, model, reasoning_effort: effort)

        assert translated_opts[:google_thinking_level] == expected_level
      end
    end

    test "ignores malformed supported thinking metadata" do
      model =
        LLMDB.Model.new!(%{
          provider: :google,
          id: "gemini-3-custom",
          extra: %{"reasoning_options" => "invalid"}
        })

      assert {translated_opts, []} =
               Google.translate_options(:chat, model, reasoning_effort: :minimal)

      assert translated_opts[:google_thinking_level] == :minimal
    end

    test "translate_options uses google_thinking_budget for reasoning_token_budget even on Gemini 3" do
      {:ok, model} = ReqLLM.model(%{provider: :google, id: "gemini-3-flash"})

      opts = [reasoning_token_budget: 10_000]
      {translated_opts, _warnings} = Google.translate_options(:chat, model, opts)

      assert Keyword.get(translated_opts, :google_thinking_budget) == 10_000
      assert Keyword.get(translated_opts, :google_thinking_level) == nil
    end
  end
end
