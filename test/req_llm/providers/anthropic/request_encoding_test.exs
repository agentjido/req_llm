defmodule ReqLLM.Providers.Anthropic.RequestEncodingTest do
  @moduledoc """
  Tests Anthropic request preparation, context encoding, and structured output schemas.
  """

  use ReqLLM.ProviderCase, provider: ReqLLM.Providers.Anthropic, async: true

  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Providers.Anthropic

  describe "request preparation & pipeline wiring" do
    test "prepare_request creates configured request" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")
      prompt = "Hello world"
      opts = [temperature: 0.7, max_tokens: 100]

      {:ok, request} = Anthropic.prepare_request(:chat, model, prompt, opts)

      assert %Req.Request{} = request
      assert request.url.path == "/v1/messages"
      assert request.method == :post
    end

    test "attach adds beta header for web_fetch server tool" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      request =
        Req.new()
        |> Anthropic.attach(model, provider_options: [web_fetch: %{max_uses: 1}])

      assert request.headers["anthropic-beta"] == ["tools-2024-05-16"]
    end

    test "attach supports manual anthropic beta headers through public provider options" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      request =
        Req.new()
        |> Anthropic.attach(model, provider_options: [anthropic_beta: ["advanced-tool-use-test"]])

      assert request.headers["anthropic-beta"] == ["advanced-tool-use-test"]
    end

    test "prepare_request adds files beta header for uploaded file references" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      context =
        ReqLLM.Context.new([
          ReqLLM.Context.user([
            ContentPart.text("Summarize this document."),
            ContentPart.file_id("file_011CNha8iCJcU1wXNR6q4V8w")
          ])
        ])

      {:ok, request} = Anthropic.prepare_request(:chat, model, context, api_key: "test-key")

      assert request.headers["anthropic-beta"] == ["files-api-2025-04-14"]
    end

    test "prepare_request combines files beta header with manual beta headers" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      context =
        ReqLLM.Context.new([
          ReqLLM.Context.user([
            ContentPart.text("Summarize this document."),
            ContentPart.file_id("file_011CNha8iCJcU1wXNR6q4V8w")
          ])
        ])

      {:ok, request} =
        Anthropic.prepare_request(:chat, model, context,
          api_key: "test-key",
          provider_options: [anthropic_beta: ["manual-beta-flag"]]
        )

      [beta_header] = request.headers["anthropic-beta"]

      assert beta_header =~ "files-api-2025-04-14"
      assert beta_header =~ "manual-beta-flag"
    end

    test "prepare_request for :object defaults max_tokens from model output limit" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")
      context = ReqLLM.Context.new([ReqLLM.Context.user("Generate a person")])
      {:ok, schema} = ReqLLM.Schema.compile(name: [type: :string, required: true])

      {:ok, request} = Anthropic.prepare_request(:object, model, context, compiled_schema: schema)

      body = request |> Anthropic.encode_body() |> ReqLLM.Test.Helpers.json_body()
      assert body["max_tokens"] == model.limits.output
    end

    test "error handling for invalid configurations" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")
      prompt = "Hello world"

      # Unsupported operation
      {:error, error} = Anthropic.prepare_request(:unsupported, model, prompt, [])
      assert %ReqLLM.Error.Invalid.Parameter{} = error

      # Provider mismatch
      {:ok, wrong_model} = ReqLLM.model(%{provider: :openai, id: "gpt-4"})

      assert_raise ReqLLM.Error.Invalid.Provider, fn ->
        Req.new() |> Anthropic.attach(wrong_model, [])
      end
    end
  end

  describe "body encoding & context translation" do
    test "encode_body converts file_id content parts to Anthropic file sources" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      document_part =
        ContentPart.file_id("file_011CNha8iCJcU1wXNR6q4V8w", "application/pdf", %{
          title: "Quarterly report",
          context: "Uploaded once through the Anthropic Files API",
          citations: %{enabled: true}
        })

      image_part = ContentPart.file_id("file_011CPMxVD3fHLUhvTqtsQA5w", "image/png")

      context =
        ReqLLM.Context.new([
          ReqLLM.Context.user([
            ContentPart.text("Compare these files."),
            document_part,
            image_part
          ])
        ])

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false
        ]
      }

      updated_request = Anthropic.encode_body(mock_request)
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      [user_message] = decoded["messages"]
      [_text_block, document_block, image_block] = user_message["content"]

      assert document_block == %{
               "type" => "document",
               "source" => %{
                 "type" => "file",
                 "file_id" => "file_011CNha8iCJcU1wXNR6q4V8w"
               },
               "title" => "Quarterly report",
               "context" => "Uploaded once through the Anthropic Files API",
               "citations" => %{"enabled" => true}
             }

      assert image_block == %{
               "type" => "image",
               "source" => %{
                 "type" => "file",
                 "file_id" => "file_011CPMxVD3fHLUhvTqtsQA5w"
               }
             }
    end

    test "encode_body consumes explicitly owned Anthropic file references" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      file_part =
        ContentPart.owned_file_id("file_owned", :anthropic,
          metadata: %{title: "Quarterly report"},
          purpose: :analysis,
          status: :active
        )

      context = ReqLLM.Context.new([ReqLLM.Context.user([file_part])])

      request = %Req.Request{
        options: [context: context, model: model.model, stream: false]
      }

      decoded = request |> Anthropic.encode_body() |> ReqLLM.Test.Helpers.json_body()

      assert [%{"content" => [block]}] = decoded["messages"]

      assert block == %{
               "type" => "document",
               "source" => %{"type" => "file", "file_id" => "file_owned"},
               "title" => "Quarterly report"
             }

      refute Jason.encode!(decoded) =~ "req_llm"
    end

    test "encode_body without tools" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")
      context = context_fixture()

      # Create a mock request with the expected structure
      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false
        ]
      }

      # Test the encode_body function directly
      updated_request = Anthropic.encode_body(mock_request)

      assert is_binary(IO.iodata_to_binary(ReqLLM.Test.Helpers.json_iodata(updated_request)))
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      assert decoded["model"] == "claude-sonnet-4-5-20250929"
      assert is_list(decoded["messages"])
      # Only user message, system goes to top-level
      assert length(decoded["messages"]) == 1
      assert decoded["stream"] == false
      refute Map.has_key?(decoded, "tools")

      # Check top-level system parameter (Anthropic format)
      assert decoded["system"] == "You are a helpful assistant."

      [user_msg] = decoded["messages"]
      assert user_msg["role"] == "user"
      assert user_msg["content"] == "Hello, how are you?"
    end

    test "encode_request encodes multiple system messages as non-empty blocks" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      context =
        ReqLLM.Context.new([
          ReqLLM.Context.system("Talk like a pirate"),
          ReqLLM.Context.user("Tell me about Elixir"),
          ReqLLM.Context.system("Respond in verses")
        ])

      request = ReqLLM.Providers.Anthropic.Context.encode_request(context, model)

      assert request[:system] == [
               %{type: "text", text: "Talk like a pirate"},
               %{type: "text", text: "Respond in verses"}
             ]

      assert request[:messages] == [%{role: "user", content: "Tell me about Elixir"}]
    end

    test "encode_request drops whitespace-only system text blocks" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      context =
        ReqLLM.Context.new([
          ReqLLM.Context.system("\n\n"),
          ReqLLM.Context.system("Talk like a pirate"),
          ReqLLM.Context.user("Tell me about Elixir"),
          %ReqLLM.Message{
            role: :system,
            content: [
              ReqLLM.Message.ContentPart.text("\t  "),
              ReqLLM.Message.ContentPart.text("Respond in verses")
            ]
          }
        ])

      request = ReqLLM.Providers.Anthropic.Context.encode_request(context, model)

      assert request[:system] == [
               %{type: "text", text: "Talk like a pirate"},
               %{type: "text", text: "Respond in verses"}
             ]

      assert request[:messages] == [%{role: "user", content: "Tell me about Elixir"}]
    end
  end

  describe "option translation" do
    test "translate_options converts stop to stop_sequences" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      # Test single stop string
      {translated_opts, []} = Anthropic.translate_options(:chat, model, stop: "STOP")
      assert Keyword.get(translated_opts, :stop_sequences) == ["STOP"]
      assert Keyword.get(translated_opts, :stop) == nil

      # Test stop list
      {translated_opts, []} = Anthropic.translate_options(:chat, model, stop: ["STOP", "END"])
      assert Keyword.get(translated_opts, :stop_sequences) == ["STOP", "END"]
      assert Keyword.get(translated_opts, :stop) == nil
    end

    test "translate_options removes unsupported parameters" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      opts = [
        temperature: 0.7,
        presence_penalty: 0.1,
        frequency_penalty: 0.2,
        logprobs: true,
        response_format: %{type: "json"}
      ]

      {translated_opts, []} = Anthropic.translate_options(:chat, model, opts)

      # Should keep supported parameters
      assert Keyword.get(translated_opts, :temperature) == 0.7

      # Should remove unsupported parameters
      assert Keyword.get(translated_opts, :presence_penalty) == nil
      assert Keyword.get(translated_opts, :frequency_penalty) == nil
      assert Keyword.get(translated_opts, :logprobs) == nil
      assert Keyword.get(translated_opts, :response_format) == nil
    end
  end

  describe "prepare_request(:object) - context validation" do
    test "rejects json_schema structured output when context ends with assistant" do
      {:ok, schema} =
        ReqLLM.Schema.compile(answer: [type: :boolean, required: true])

      context =
        ReqLLM.Context.new([
          ReqLLM.Context.assistant("I will inform the user if I support context pre-filling")
        ])

      {:error, error} =
        Anthropic.prepare_request(:object, "anthropic:claude-sonnet-4-5-20250929", context,
          compiled_schema: schema
        )

      assert %ReqLLM.Error.Invalid.Parameter{} = error
      assert error.parameter =~ "does not support contexts ending with an assistant message"
      assert error.parameter =~ "Append a user message requesting the structured output"
    end

    test "rejects tool_strict structured output when context ends with assistant" do
      {:ok, schema} =
        ReqLLM.Schema.compile(answer: [type: :boolean, required: true])

      context =
        ReqLLM.Context.new([
          ReqLLM.Context.assistant("I will inform the user if I support context pre-filling")
        ])

      {:error, error} =
        Anthropic.prepare_request(:object, "anthropic:claude-sonnet-4-5-20250929", context,
          compiled_schema: schema,
          provider_options: [anthropic_structured_output_mode: :tool_strict]
        )

      assert %ReqLLM.Error.Invalid.Parameter{} = error
      assert error.parameter =~ "does not support contexts ending with an assistant message"
      assert error.parameter =~ "Append a user message requesting the structured output"
    end
  end

  describe "prepare_request(:object) - schema constraint stripping" do
    test "strips minimum constraint from pos_integer schema in json_schema mode" do
      {:ok, schema} =
        ReqLLM.Schema.compile(
          count: [type: :pos_integer, required: true, doc: "A positive count"]
        )

      {:ok, request} =
        Anthropic.prepare_request(:object, "anthropic:claude-sonnet-4-5-20250929", "Generate",
          compiled_schema: schema
        )

      provider_opts = request.options[:provider_options]
      output_format = Keyword.get(provider_opts, :output_format)

      refute Map.has_key?(output_format.schema["properties"]["count"], "minimum")
      assert output_format.schema["properties"]["count"]["type"] == "integer"
    end

    test "strips maximum constraint from integer schema" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "rating" => %{"type" => "integer", "minimum" => 1, "maximum" => 5}
        }
      }

      compiled_schema = %{schema: schema}

      {:ok, request} =
        Anthropic.prepare_request(:object, "anthropic:claude-sonnet-4-5-20250929", "Generate",
          compiled_schema: compiled_schema
        )

      provider_opts = request.options[:provider_options]
      output_format = Keyword.get(provider_opts, :output_format)

      refute Map.has_key?(output_format.schema["properties"]["rating"], "minimum")
      refute Map.has_key?(output_format.schema["properties"]["rating"], "maximum")
    end

    test "strips minLength and maxLength from string schema" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string", "minLength" => 1, "maxLength" => 100}
        }
      }

      compiled_schema = %{schema: schema}

      {:ok, request} =
        Anthropic.prepare_request(:object, "anthropic:claude-sonnet-4-5-20250929", "Generate",
          compiled_schema: compiled_schema
        )

      provider_opts = request.options[:provider_options]
      output_format = Keyword.get(provider_opts, :output_format)

      refute Map.has_key?(output_format.schema["properties"]["name"], "minLength")
      refute Map.has_key?(output_format.schema["properties"]["name"], "maxLength")
    end

    test "recursively strips constraints from nested schemas" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "user" => %{
            "type" => "object",
            "properties" => %{
              "age" => %{"type" => "integer", "minimum" => 0, "maximum" => 150},
              "name" => %{"type" => "string", "minLength" => 1}
            }
          },
          "scores" => %{
            "type" => "array",
            "items" => %{"type" => "integer", "minimum" => 0, "maximum" => 100}
          }
        }
      }

      compiled_schema = %{schema: schema}

      {:ok, request} =
        Anthropic.prepare_request(:object, "anthropic:claude-sonnet-4-5-20250929", "Generate",
          compiled_schema: compiled_schema
        )

      provider_opts = request.options[:provider_options]
      output_format = Keyword.get(provider_opts, :output_format)
      props = output_format.schema["properties"]

      refute Map.has_key?(props["user"]["properties"]["age"], "minimum")
      refute Map.has_key?(props["user"]["properties"]["age"], "maximum")
      refute Map.has_key?(props["user"]["properties"]["name"], "minLength")
      refute Map.has_key?(props["scores"]["items"], "minimum")
      refute Map.has_key?(props["scores"]["items"], "maximum")
    end

    test "strips constraints in tool_strict mode" do
      {:ok, schema} =
        ReqLLM.Schema.compile(
          value: [type: :pos_integer, required: true, doc: "A positive value"]
        )

      tool =
        ReqLLM.Tool.new!(
          name: "other_tool",
          description: "Another tool",
          parameter_schema: [x: [type: :string]],
          callback: fn _ -> {:ok, "done"} end
        )

      {:ok, request} =
        Anthropic.prepare_request(:object, "anthropic:claude-sonnet-4-5-20250929", "Generate",
          compiled_schema: schema,
          tools: [tool]
        )

      tools = request.options[:tools]
      structured_tool = Enum.find(tools, fn t -> t.name == "structured_output" end)

      refute Map.has_key?(structured_tool.parameter_schema["properties"]["value"], "minimum")
    end
  end
end
