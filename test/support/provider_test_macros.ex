defmodule ReqLLM.ProviderTestMacros do
  @moduledoc """
  Macros for generating common provider test patterns.

  This module provides macros that generate standard test cases for provider
  implementations, focusing on the low-level Req plugin API contract.
  """

  @doc """
  Generates provider contract tests.

  Tests the basic DSL contract including identity, schema separation,
  and supported options.

  ## Options

  - `:mod` - The provider module to test

  ## Example

      provider_contract_tests(mod: ReqLLM.Providers.Groq)
  """
  defmacro provider_contract_tests(opts) do
    mod = Keyword.fetch!(opts, :mod)

    quote do
      describe "DSL contract" do
        test "provider identity and configuration" do
          assert is_atom(unquote(mod).provider_id())
          assert is_binary(unquote(mod).default_base_url())
          assert String.starts_with?(unquote(mod).default_base_url(), "http")
        end

        test "provider schema separation from core options" do
          schema_keys = unquote(mod).provider_schema().schema |> Keyword.keys()
          core_keys = ReqLLM.Generation.schema().schema |> Keyword.keys()

          # Provider-specific keys should not overlap with core generation keys
          overlap = MapSet.intersection(MapSet.new(schema_keys), MapSet.new(core_keys))

          assert MapSet.size(overlap) == 0,
                 "Schema overlap detected: #{inspect(MapSet.to_list(overlap))}"
        end

        test "supported options include core generation keys" do
          supported = unquote(mod).supported_provider_options()
          core_keys = ReqLLM.Provider.Options.all_generation_keys()

          # All core keys should be supported (except meta-keys like :provider_options)
          core_without_meta = Enum.reject(core_keys, &(&1 == :provider_options))
          missing = core_without_meta -- supported
          assert missing == [], "Missing core generation keys: #{inspect(missing)}"
        end
      end
    end
  end

  @doc """
  Generates pipeline smoke tests.

  Tests prepare_request/4 and attach/3 functions for basic pipeline wiring.

  ## Options

  - `:mod` - The provider module to test
  - `:model` - Model string to use for testing (e.g., "groq:llama-3.1-8b-instant")

  ## Example

      pipeline_smoke_tests(
        mod: ReqLLM.Providers.Groq,
        model: "groq:llama-3.1-8b-instant"
      )
  """
  defmacro pipeline_smoke_tests(opts) do
    mod = Keyword.fetch!(opts, :mod)
    model_string = Keyword.fetch!(opts, :model)

    quote do
      describe "request preparation & pipeline wiring" do
        test "prepare_request creates configured request" do
          model = ReqLLM.Model.from!(unquote(model_string))
          context = context_fixture()
          opts = [temperature: 0.7, max_tokens: 100]

          {:ok, request} = unquote(mod).prepare_request(:chat, model, context, opts)

          assert %Req.Request{} = request
          assert request.url.path == "/chat/completions"
          assert request.method == :post
        end

        test "attach configures authentication and pipeline" do
          model = ReqLLM.Model.from!(unquote(model_string))
          opts = [temperature: 0.5, max_tokens: 50]

          request = Req.new() |> unquote(mod).attach(model, opts)

          # Verify core options
          assert request.options[:model] == model.model
          assert request.options[:temperature] == 0.5
          assert request.options[:max_tokens] == 50
          assert {:bearer, _key} = request.options[:auth]

          # Verify pipeline steps
          request_steps = Keyword.keys(request.request_steps)
          response_steps = Keyword.keys(request.response_steps)

          assert :llm_encode_body in request_steps
          assert :llm_decode_response in response_steps
        end

        test "error handling for invalid configurations" do
          model = ReqLLM.Model.from!(unquote(model_string))
          context = context_fixture()

          # Unsupported operation
          {:error, error} = unquote(mod).prepare_request(:unsupported, model, context, [])
          assert %ReqLLM.Error.Invalid.Parameter{} = error

          # Provider mismatch
          wrong_model = ReqLLM.Model.from!("openai:gpt-4")

          assert_raise ReqLLM.Error.Invalid.Provider, fn ->
            Req.new() |> unquote(mod).attach(wrong_model, [])
          end
        end
      end
    end
  end

  @doc """
  Macro for asserting request JSON body structure.

  Stubs the provider, decodes the request body, runs the assertion function,
  and returns a mock response to continue the call chain.

  ## Options

  - `:provider` - Provider module to stub
  - `:assert` - Function to run on decoded JSON body
  - `:fixture_opts` - Options to pass to json fixture (optional)

  ## Example

      assert_request_json(
        provider: MyProvider,
        assert: fn json ->
          assert json["model"] == "expected-model"
          assert is_list(json["messages"])
        end
      )
  """
  defmacro assert_request_json(opts) do
    quote do
      opts = unquote(opts)
      provider = Keyword.fetch!(opts, :provider)
      assert_fn = Keyword.fetch!(opts, :assert)
      fixture_opts = Keyword.get(opts, :fixture_opts, [])

      Req.Test.stub(provider, fn conn ->
        decoded_body = Jason.decode!(conn.body)
        assert_fn.(decoded_body)
        Req.Test.json(conn, openai_format_json_fixture(fixture_opts))
      end)
    end
  end

  @doc """
  Generates response normalization tests.

  Tests that the provider correctly decodes API responses into canonical
  ReqLLM.Response structures for both regular and streaming responses.

  ## Options

  - `:provider` - Provider module
  - `:model` - Model string for testing
  - `:fixture` - Fixture name for basic response test
  - `:streaming_fixture` - Fixture name for streaming response test

  ## Example

      response_normalisation_tests(
        provider: ReqLLM.Providers.Groq,
        model: "groq:llama-3.1-8b-instant",
        fixture: "groq_basic",
        streaming_fixture: "groq_streaming_test"
      )
  """
  defmacro response_normalisation_tests(opts) do
    model_string = Keyword.fetch!(opts, :model)
    fixture = Keyword.fetch!(opts, :fixture)
    streaming_fixture = Keyword.fetch!(opts, :streaming_fixture)

    quote do
      describe "response decoding & normalization" do
        test "basic response normalization" do
          {:ok, response} =
            ReqLLM.generate_text(unquote(model_string), context_fixture(),
              fixture: unquote(fixture)
            )

          # Verify canonical response structure
          assert %ReqLLM.Response{} = response
          assert is_binary(response.id)
          assert response.model == ReqLLM.Model.from!(unquote(model_string)).model
          assert response.stream? == false

          # Verify message normalization
          assert response.message.role == :assistant
          text = ReqLLM.Response.text(response)
          assert is_binary(text)
          assert String.length(text) > 0
          assert response.finish_reason in [:stop, :length, "stop", "length"]

          # Verify usage normalization (atoms, not strings)
          assert is_integer(response.usage.input_tokens)
          assert is_integer(response.usage.output_tokens)
          assert is_integer(response.usage.total_tokens)

          # Verify context advancement (system + user + assistant)
          assert length(response.context.messages) == 3
          assert List.last(response.context.messages).role == :assistant
        end

        test "streaming response normalization" do
          {:ok, response} =
            ReqLLM.stream_text(unquote(model_string), context_fixture(),
              fixture: unquote(streaming_fixture)
            )

          # Verify streaming structure
          assert response.stream? == true
          assert is_struct(response.stream, Stream)

          # Collect chunks to verify they are proper StreamChunk structs
          chunks = Enum.to_list(response.stream)
          assert is_list(chunks)
          refute Enum.empty?(chunks)

          # Verify chunks are proper StreamChunk structs
          assert Enum.all?(chunks, fn chunk ->
                   match?(%ReqLLM.StreamChunk{}, chunk)
                 end)

          # Verify at least one chunk has text content
          assert Enum.any?(chunks, fn chunk ->
                   chunk.type in [:text, :content] and is_binary(chunk.text) and chunk.text != ""
                 end)

          # Verify stream materialization
          {:ok, materialized} = ReqLLM.Response.join_stream(response)
          assert materialized.stream? == false
          text = ReqLLM.Response.text(materialized)
          assert is_binary(text)
          assert String.length(text) > 0
        end
      end
    end
  end

  @doc """
  Generates option translation tests.

  Tests provider-specific option handling and translation.

  ## Options

  - `:mod` - Provider module to test

  ## Example

      option_translation_tests(mod: ReqLLM.Providers.Groq)
  """
  defmacro option_translation_tests(opts) do
    mod = Keyword.fetch!(opts, :mod)

    quote do
      describe "options translation layer" do
        test "provider does not implement translate_options/3" do
          # Most providers don't implement translate_options/3, verify this
          refute function_exported?(unquote(mod), :translate_options, 3)
        end

        test "provider-specific option handling" do
          # Test that provider-specific options are present in the provider schema
          schema_keys = unquote(mod).provider_schema().schema |> Keyword.keys()

          # Test that these options are supported
          supported_opts = unquote(mod).supported_provider_options()

          for provider_option <- schema_keys do
            assert provider_option in supported_opts,
                   "Expected #{provider_option} to be in supported options"
          end
        end
      end
    end
  end
end
