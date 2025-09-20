defmodule ReqLLM.Provider.DSLTest do
  use ExUnit.Case, async: true

  # Helper functions for reducing test duplication
  defp with_test_metadata(filename, metadata_content, test_func) do
    File.mkdir_p!("test/fixtures")
    full_path = "test/fixtures/#{filename}"
    File.write!(full_path, Jason.encode!(metadata_content))

    try do
      test_func.(full_path)
    after
      File.rm(full_path)
    end
  end

  defp test_metadata_content do
    %{
      "models" => [
        %{
          "id" => "test-model",
          "context_length" => 8192,
          "capabilities" => ["text_generation"],
          "pricing" => %{"input" => 0.001, "output" => 0.002}
        }
      ],
      "capabilities" => ["text_generation"],
      "documentation" => "https://test.com/docs"
    }
  end

  defp assert_schema_contains(provider_module, expected_keys) do
    schema_keys = provider_module.provider_schema().schema |> Keyword.keys()

    for key <- expected_keys do
      assert key in schema_keys, "Expected schema key #{key} not found in #{inspect(schema_keys)}"
    end
  end

  # Pre-define test provider modules to avoid dynamic compilation issues
  defmodule TestProvider do
    @behaviour ReqLLM.Provider

    use ReqLLM.Provider.DSL,
      id: :test_provider,
      base_url: "https://api.test.com/v1",
      provider_schema: [
        custom_option: [type: :string, default: "test"],
        temperature_override: [type: :float, default: 0.8]
      ]

    def attach(_request, _model, _opts), do: :ok
    def prepare_request(_operation, _model, _context, _opts), do: {:ok, %Req.Request{}}
  end

  defmodule TestProviderWithWrappers do
    @behaviour ReqLLM.Provider

    use ReqLLM.Provider.DSL,
      id: :test_wrappers,
      base_url: "https://api.wrappers.com/v1",
      default_env_key: "TEST_API_KEY",
      context_wrapper: TestProviderWithWrappers.Context,
      response_wrapper: TestProviderWithWrappers.Response

    defmodule Context, do: defstruct([:context])
    defmodule Response, do: defstruct([:payload])

    def attach(_request, _model, _opts), do: :ok
    def prepare_request(_operation, _model, _context, _opts), do: {:ok, %Req.Request{}}
  end

  defmodule EmptySchemaProvider do
    @behaviour ReqLLM.Provider

    use ReqLLM.Provider.DSL,
      id: :empty_schema,
      base_url: "https://empty.com"

    def attach(_request, _model, _opts), do: :ok
    def prepare_request(_operation, _model, _context, _opts), do: {:ok, %Req.Request{}}
  end

  describe "DSL validation" do
    test "validates required options" do
      assert_raise KeyError, ~r/key :id not found/, fn ->
        defmodule MissingId do
          use ReqLLM.Provider.DSL, base_url: "https://test.com"
        end
      end

      assert_raise KeyError, ~r/key :base_url not found/, fn ->
        defmodule MissingBaseUrl do
          use ReqLLM.Provider.DSL, id: :missing_base
        end
      end
    end

    test "validates option types" do
      assert_raise ArgumentError, ~r/Provider :id must be an atom/, fn ->
        defmodule InvalidIdProvider do
          use ReqLLM.Provider.DSL,
            id: "string_id",
            base_url: "https://test.com"
        end
      end

      assert_raise ArgumentError, ~r/Provider :base_url must be a string/, fn ->
        defmodule InvalidBaseUrlProvider do
          use ReqLLM.Provider.DSL,
            id: :test_id,
            base_url: :atom_url
        end
      end

      assert_raise ArgumentError, ~r/Provider :default_env_key must be a string/, fn ->
        defmodule InvalidEnvKeyProvider do
          use ReqLLM.Provider.DSL,
            id: :test_env,
            base_url: "https://test.com",
            default_env_key: :atom_key
        end
      end
    end
  end

  describe "generated core functions" do
    test "basic provider metadata functions" do
      assert TestProvider.provider_id() == :test_provider
      assert TestProvider.default_base_url() == "https://api.test.com/v1"
      assert is_map(TestProvider.metadata())
    end

    test "schema functions" do
      assert_schema_contains(TestProvider, [:custom_option, :temperature_override])

      # Test provider_schema/0
      schema = TestProvider.provider_schema()
      assert %NimbleOptions{} = schema

      # Test supported_provider_options/0 includes core + provider options
      supported = TestProvider.supported_provider_options()
      assert :custom_option in supported
      # core option
      assert :temperature in supported
      # core option
      assert :max_tokens in supported

      # Test default_provider_opts/0
      defaults = TestProvider.default_provider_opts()
      assert {:custom_option, "test"} in defaults
      assert {:temperature_override, 0.8} in defaults
    end

    test "extended generation schema integration" do
      extended_schema = TestProvider.provider_extended_generation_schema()
      schema_keys = extended_schema.schema |> Keyword.keys()

      # Should have core generation options
      core_keys = ReqLLM.Provider.Options.generation_schema().schema |> Keyword.keys()

      for key <- core_keys do
        assert key in schema_keys, "Missing core key: #{key}"
      end

      # Should have provider-specific options
      assert :custom_option in schema_keys
      assert :temperature_override in schema_keys

      # Verify extended schema is superset of provider schema
      provider_keys = TestProvider.provider_schema().schema |> Keyword.keys() |> MapSet.new()
      extended_keys = schema_keys |> MapSet.new()
      assert MapSet.subset?(provider_keys, extended_keys)
    end
  end

  describe "translation helper functions" do
    test "validate_mutex!/3" do
      assert :ok = TestProvider.validate_mutex!([], [:a, :b], "test")
      assert :ok = TestProvider.validate_mutex!([a: 1], [:a, :b], "test")

      assert_raise ReqLLM.Error.Invalid.Parameter, fn ->
        TestProvider.validate_mutex!([a: 1, b: 2], [:a, :b], "test")
      end
    end

    test "translate_rename/3" do
      assert {[new: "val"], []} = TestProvider.translate_rename([old: "val"], :old, :new)
      assert {[], []} = TestProvider.translate_rename([], :old, :new)

      assert_raise ReqLLM.Error.Invalid.Parameter, fn ->
        TestProvider.translate_rename([old: 1, new: 2], :old, :new)
      end
    end

    test "translate_drop/3" do
      assert {[keep: 1], ["warn"]} =
               TestProvider.translate_drop([keep: 1, drop: 2], :drop, "warn")

      assert {[keep: 1], []} = TestProvider.translate_drop([keep: 1], :missing, "warn")
      assert {[], []} = TestProvider.translate_drop([], :missing, "warn")
    end

    test "translate_combine_warnings/1" do
      results = [{[a: 1], ["w1"]}, {[b: 2], ["w2"]}, {[c: 3], []}]
      assert {[a: 1, b: 2, c: 3], ["w1", "w2"]} = TestProvider.translate_combine_warnings(results)
    end
  end

  describe "conditional function generation" do
    test "generates optional functions when options provided" do
      # TestProviderWithWrappers has all optional features
      assert TestProviderWithWrappers.default_env_key() == "TEST_API_KEY"

      context = %ReqLLM.Context{messages: []}

      assert %TestProviderWithWrappers.Context{context: ^context} =
               TestProviderWithWrappers.wrap_context(context)

      response = "test response"

      assert %TestProviderWithWrappers.Response{payload: ^response} =
               TestProviderWithWrappers.wrap_response(response)

      # Test double-wrapping prevention
      wrapped = %TestProviderWithWrappers.Response{payload: "data"}
      assert ^wrapped = TestProviderWithWrappers.wrap_response(wrapped)
    end

    test "does not generate functions when options absent" do
      # TestProvider doesn't have optional features
      refute function_exported?(TestProvider, :default_env_key, 0)
      refute function_exported?(TestProvider, :wrap_context, 1)
      refute function_exported?(TestProvider, :wrap_response, 1)
    end
  end

  describe "metadata loading" do
    test "loads and atomizes metadata from JSON" do
      with_test_metadata("metadata_test.json", test_metadata_content(), fn metadata_path ->
        defmodule TestMetadataProvider do
          @behaviour ReqLLM.Provider

          use ReqLLM.Provider.DSL,
            id: :test_metadata,
            base_url: "https://api.metadata.com/v1",
            metadata: metadata_path

          def attach(_request, _model, _opts), do: :ok
          def prepare_request(_operation, _model, _context, _opts), do: {:ok, %Req.Request{}}
        end

        metadata = TestMetadataProvider.metadata()

        # Verify key atomization
        assert metadata.models == [
                 %{
                   id: "test-model",
                   context_length: 8192,
                   capabilities: ["text_generation"],
                   pricing: %{input: 0.001, output: 0.002}
                 }
               ]

        assert metadata.capabilities == ["text_generation"]
      end)
    end

    test "handles metadata loading errors gracefully" do
      # Missing file
      defmodule MissingMetadataProvider do
        @behaviour ReqLLM.Provider

        use ReqLLM.Provider.DSL,
          id: :missing_metadata,
          base_url: "https://missing.com",
          metadata: "nonexistent/path.json"

        def attach(_request, _model, _opts), do: :ok
        def prepare_request(_operation, _model, _context, _opts), do: {:ok, %Req.Request{}}
      end

      assert MissingMetadataProvider.metadata() == %{}

      # Invalid JSON
      File.mkdir_p!("test/fixtures")
      File.write!("test/fixtures/invalid.json", "invalid json")

      defmodule InvalidJSONProvider do
        @behaviour ReqLLM.Provider

        use ReqLLM.Provider.DSL,
          id: :invalid_json,
          base_url: "https://invalid.com",
          metadata: "test/fixtures/invalid.json"

        def attach(_request, _model, _opts), do: :ok
        def prepare_request(_operation, _model, _context, _opts), do: {:ok, %Req.Request{}}
      end

      assert InvalidJSONProvider.metadata() == %{}
      File.rm("test/fixtures/invalid.json")

      # Read permission error
      File.write!("test/fixtures/readonly.json", "{}")
      File.chmod!("test/fixtures/readonly.json", 0o000)

      defmodule ReadErrorProvider do
        @behaviour ReqLLM.Provider

        use ReqLLM.Provider.DSL,
          id: :read_error,
          base_url: "https://readonly.com",
          metadata: "test/fixtures/readonly.json"

        def attach(_request, _model, _opts), do: :ok
        def prepare_request(_operation, _model, _context, _opts), do: {:ok, %Req.Request{}}
      end

      assert ReadErrorProvider.metadata() == %{}
      File.chmod!("test/fixtures/readonly.json", 0o644)
      File.rm("test/fixtures/readonly.json")
    end
  end

  describe "atomize_keys behavior" do
    test "atomizes nested structures correctly" do
      # Complex nested structures
      complex_content = %{
        "models" => [%{"id" => "m1", "pricing" => %{"input" => 0.1, "output" => 0.2}}],
        "custom_field" => "preserved"
      }

      with_test_metadata("atomize_complex.json", complex_content, fn path ->
        defmodule AtomizeComplexProvider do
          @behaviour ReqLLM.Provider

          use ReqLLM.Provider.DSL,
            id: :atomize_complex,
            base_url: "https://atomize.com",
            metadata: path

          def attach(_request, _model, _opts), do: :ok
          def prepare_request(_operation, _model, _context, _opts), do: {:ok, %Req.Request{}}
        end

        metadata = AtomizeComplexProvider.metadata()
        model = List.first(metadata.models)
        assert model.id == "m1"
        assert model.pricing.input == 0.1
        # unknown keys preserved
        assert metadata["custom_field"] == "preserved"
      end)

      # List handling
      list_content = %{"models" => [%{"id" => "m1"}, %{"id" => "m2"}]}

      with_test_metadata("atomize_list.json", list_content, fn path ->
        defmodule AtomizeListProvider do
          @behaviour ReqLLM.Provider

          use ReqLLM.Provider.DSL,
            id: :atomize_list,
            base_url: "https://atomize.com",
            metadata: path

          def attach(_request, _model, _opts), do: :ok
          def prepare_request(_operation, _model, _context, _opts), do: {:ok, %Req.Request{}}
        end

        metadata = AtomizeListProvider.metadata()
        assert length(metadata.models) == 2
        assert Enum.all?(metadata.models, &(&1.id in ["m1", "m2"]))
      end)

      # Primitive values
      primitive_content = %{"number" => 42, "boolean" => true}

      with_test_metadata("atomize_primitive.json", primitive_content, fn path ->
        defmodule AtomizePrimitiveProvider do
          @behaviour ReqLLM.Provider

          use ReqLLM.Provider.DSL,
            id: :atomize_primitive,
            base_url: "https://atomize.com",
            metadata: path

          def attach(_request, _model, _opts), do: :ok
          def prepare_request(_operation, _model, _context, _opts), do: {:ok, %Req.Request{}}
        end

        metadata = AtomizePrimitiveProvider.metadata()
        assert metadata["number"] == 42
        assert metadata["boolean"] == true
      end)
    end
  end

  describe "schema compilation and validation" do
    test "empty provider schema" do
      schema = EmptySchemaProvider.provider_schema()
      assert %NimbleOptions{} = schema
      assert schema.schema == []

      # Extended schema should still include core options
      extended_keys =
        EmptySchemaProvider.provider_extended_generation_schema().schema |> Keyword.keys()

      core_keys = ReqLLM.Provider.Options.generation_schema().schema |> Keyword.keys()

      for key <- core_keys do
        assert key in extended_keys
      end
    end

    test "warns about schema conflicts with core options" do
      warning_output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          defmodule ConflictingProvider do
            @behaviour ReqLLM.Provider

            use ReqLLM.Provider.DSL,
              id: :conflicting,
              base_url: "https://conflict.com",
              provider_schema: [temperature: [type: :float, default: 0.9]]

            def attach(_request, _model, _opts), do: :ok
            def prepare_request(_operation, _model, _context, _opts), do: {:ok, %Req.Request{}}
          end
        end)

      assert warning_output =~ "schema key :temperature conflicts with core generation option"
    end
  end

  test "end-to-end provider functionality" do
    # Verify complete provider works as expected
    assert is_atom(TestProvider.provider_id())
    assert String.starts_with?(TestProvider.default_base_url(), "http")

    # All schema-related functions should work together
    provider_schema = TestProvider.provider_schema()
    extended_schema = TestProvider.provider_extended_generation_schema()

    assert %NimbleOptions{} = provider_schema
    assert %NimbleOptions{} = extended_schema

    # Relationship between schemas
    provider_keys = provider_schema.schema |> Keyword.keys() |> MapSet.new()
    extended_keys = extended_schema.schema |> Keyword.keys() |> MapSet.new()
    assert MapSet.subset?(provider_keys, extended_keys)

    # Supported options should match extended schema
    supported_keys = TestProvider.supported_provider_options() |> MapSet.new()
    assert MapSet.equal?(supported_keys, extended_keys)
  end
end
