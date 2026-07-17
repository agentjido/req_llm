defmodule ReqLLM.Provider.Options.NamespaceTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ReqLLM.Provider.Options
  alias ReqLLM.Provider.Options.Namespace

  defmodule MockProvider do
    @behaviour ReqLLM.Provider

    def provider_id, do: :mock_namespace
    def default_base_url, do: "https://mock.namespace.test"
    def supported_provider_options, do: [:custom_option, :another_option, :payload, :dimensions]

    def provider_schema do
      NimbleOptions.new!(
        custom_option: [type: :string],
        another_option: [type: :integer],
        payload: [type: :map],
        dimensions: [type: :pos_integer]
      )
    end

    def prepare_request(_operation, _model, _input, _opts), do: {:error, :not_implemented}
    def attach(request, _model, _opts), do: request
    def encode_body(request), do: request
    def decode_response(response), do: response
  end

  defmodule ProviderNameOptionProvider do
    @behaviour ReqLLM.Provider

    def provider_id, do: :provider_name_option
    def default_base_url, do: "https://provider-name-option.test"
    def supported_provider_options, do: [:openai]
    def provider_schema, do: NimbleOptions.new!(openai: [type: :any])
    def prepare_request(_operation, _model, _input, _opts), do: {:error, :not_implemented}
    def attach(request, _model, _opts), do: request
    def encode_body(request), do: request
    def decode_response(response), do: response
  end

  describe "namespace normalization" do
    test "preserves unambiguous legacy keyword and map containers" do
      model = model(:mock_namespace)

      keyword_opts = [provider_options: [custom_option: "legacy"]]
      map_opts = [provider_options: %{"custom_option" => "legacy"}]

      assert {:ok, ^keyword_opts, []} =
               Namespace.normalize(MockProvider, :chat, model, keyword_opts)

      assert {:ok, ^map_opts, []} = Namespace.normalize(MockProvider, :chat, model, map_opts)
    end

    test "normalizes atom and string provider namespaces to the legacy flat shape" do
      model = model(:mock_namespace)

      assert {:ok, atom_opts, []} =
               Namespace.normalize(MockProvider, :chat, model,
                 provider_options: [mock_namespace: [custom_option: "atom"]]
               )

      assert atom_opts[:provider_options] == [custom_option: "atom"]

      assert {:ok, string_opts, []} =
               Namespace.normalize(MockProvider, :chat, model,
                 provider_options: %{
                   "mock_namespace" => %{"custom_option" => "string"}
                 }
               )

      assert string_opts[:provider_options] == [custom_option: "string"]
    end

    test "uses the same normalization contract across every V1 request operation" do
      operations = [:chat, :object, :embedding, :image, :transcription, :speech, :rerank, :ocr]

      Enum.each(operations, fn operation ->
        assert {:ok, normalized} =
                 Options.normalize_namespaced_provider_options(
                   MockProvider,
                   operation,
                   model(:mock_namespace),
                   provider_options: [mock_namespace: [custom_option: "value"]]
                 )

        assert normalized[:provider_options] == [custom_option: "value"]
      end)
    end

    test "keeps provider-schema keys ahead of namespace detection" do
      model = model(:provider_name_option)
      opts = [provider_options: [openai: [custom: true]]]

      assert {:ok, ^opts, []} =
               Namespace.normalize(ProviderNameOptionProvider, :chat, model, opts)
    end

    test "preserves atom-keyed options for schema-less providers" do
      elevenlabs_model = model(:elevenlabs, "eleven_multilingual_v2")

      assert {:ok, normalized, []} =
               Namespace.normalize(
                 ReqLLM.Providers.ElevenLabs,
                 :speech,
                 elevenlabs_model,
                 provider_options: [
                   elevenlabs: [stability: 0.5, future_voice_setting: true]
                 ]
               )

      assert normalized[:provider_options] == [stability: 0.5, future_voice_setting: true]
    end

    test "rejects foreign provider namespaces before translation" do
      assert {:error, %ReqLLM.Error.Invalid.Parameter{} = error} =
               Namespace.normalize(MockProvider, :chat, model(:mock_namespace),
                 provider_options: [anthropic: [custom_option: "foreign"]]
               )

      assert Exception.message(error) =~ "namespace :anthropic"
      assert Exception.message(error) =~ "selected provider :mock_namespace"
    end

    test "rejects malformed selected namespaces" do
      assert {:error, %ReqLLM.Error.Invalid.Parameter{} = error} =
               Namespace.normalize(MockProvider, :chat, model(:mock_namespace),
                 provider_options: [mock_namespace: "invalid"]
               )

      assert Exception.message(error) =~ "must contain a keyword list or map"
    end

    test "rejects unknown and misplaced canonical keys inside a namespace" do
      assert {:error, %ReqLLM.Error.Invalid.Parameter{} = unknown_error} =
               Namespace.normalize(MockProvider, :chat, model(:mock_namespace),
                 provider_options: [mock_namespace: [unknown: true]]
               )

      assert Exception.message(unknown_error) =~ "unknown provider option :unknown"

      assert {:error, %ReqLLM.Error.Invalid.Parameter{} = canonical_error} =
               Namespace.normalize(MockProvider, :chat, model(:mock_namespace),
                 provider_options: [mock_namespace: [temperature: 0.2]]
               )

      assert Exception.message(canonical_error) =~ "temperature"
      assert Exception.message(canonical_error) =~ "top-level"
    end

    test "rejects duplicate selected namespaces and duplicate nested keys" do
      assert {:error, %ReqLLM.Error.Invalid.Parameter{} = container_error} =
               Namespace.normalize(MockProvider, :chat, model(:mock_namespace),
                 provider_options: [mock_namespace: [custom_option: "one"]],
                 provider_options: [mock_namespace: [custom_option: "two"]]
               )

      assert Exception.message(container_error) =~ "provider_options more than once"

      assert {:error, %ReqLLM.Error.Invalid.Parameter{} = namespace_error} =
               Namespace.normalize(MockProvider, :chat, model(:mock_namespace),
                 provider_options: [
                   mock_namespace: [custom_option: "one"],
                   mock_namespace: [custom_option: "two"]
                 ]
               )

      assert Exception.message(namespace_error) =~ "more than once"

      assert {:error, %ReqLLM.Error.Invalid.Parameter{} = key_error} =
               Namespace.normalize(MockProvider, :chat, model(:mock_namespace),
                 provider_options: [
                   mock_namespace: [custom_option: "one", custom_option: "two"]
                 ]
               )

      assert Exception.message(key_error) =~ "duplicate"
      assert Exception.message(key_error) =~ ":custom_option"
    end
  end

  describe "precedence and warning policy" do
    test "namespaced provider values win collisions with mixed legacy values" do
      model = model(:mock_namespace)

      log =
        capture_log(fn ->
          assert {:ok, processed} =
                   Options.process(MockProvider, :chat, model,
                     provider_options: [
                       custom_option: "legacy",
                       mock_namespace: [custom_option: "namespaced", another_option: 2]
                     ]
                   )

          assert processed[:provider_options] == [
                   custom_option: "namespaced",
                   another_option: 2
                 ]
        end)

      assert log =~ "namespaced values took precedence for :custom_option"
    end

    test "explicit canonical values win collisions with namespaced values" do
      model = model(:mock_namespace)

      log =
        capture_log(fn ->
          assert {:ok, processed} =
                   Options.process(MockProvider, :embedding, model,
                     dimensions: 128,
                     provider_options: [mock_namespace: [dimensions: 256]]
                   )

          assert processed[:dimensions] == 128
          assert processed[:provider_options][:dimensions] == 128
        end)

      assert log =~ "explicit top-level canonical options take precedence"
      assert log =~ ":dimensions"
    end

    test "strict policy rejects ambiguous mixed input" do
      assert {:error, %ReqLLM.Error.Validation.Error{} = error} =
               Options.process(MockProvider, :chat, model(:mock_namespace),
                 on_unsupported: :error,
                 provider_options: [
                   custom_option: "legacy",
                   mock_namespace: [custom_option: "namespaced"]
                 ]
               )

      assert Exception.message(error) =~ "namespaced values took precedence"
    end

    test "ignore policy keeps deterministic precedence without logging" do
      log =
        capture_log(fn ->
          assert {:ok, processed} =
                   Options.process(MockProvider, :chat, model(:mock_namespace),
                     on_unsupported: :ignore,
                     provider_options: [
                       custom_option: "legacy",
                       mock_namespace: [custom_option: "namespaced"]
                     ]
                   )

          assert processed[:provider_options][:custom_option] == "namespaced"
        end)

      assert log == ""
    end
  end

  describe "provider processing and planning" do
    test "accepts flat provider option maps with known string keys" do
      assert {:ok, processed} =
               Options.process(MockProvider, :chat, model(:mock_namespace),
                 provider_options: %{
                   "custom_option" => "map",
                   "another_option" => 7
                 }
               )

      assert processed[:provider_options][:custom_option] == "map"
      assert processed[:provider_options][:another_option] == 7
    end

    test "produces equivalent options for OpenAI, Anthropic, and OpenRouter" do
      cases = [
        {ReqLLM.Providers.OpenAI, model(:openai, "gpt-4.1-mini"), [reasoning_summary: "auto"]},
        {ReqLLM.Providers.Anthropic, model(:anthropic, "claude-sonnet-4-5-20250929"),
         [anthropic_top_k: 20]},
        {ReqLLM.Providers.OpenRouter, model(:openrouter, "openai/gpt-4.1-mini"),
         [openrouter_route: "fallback"]}
      ]

      Enum.each(cases, fn {provider_mod, provider_model, provider_options} ->
        provider = provider_model.provider

        assert {:ok, legacy} =
                 Options.process(provider_mod, :chat, provider_model,
                   provider_options: provider_options
                 )

        assert {:ok, namespaced} =
                 Options.process(provider_mod, :chat, provider_model,
                   provider_options: [{provider, provider_options}]
                 )

        assert comparable_options(namespaced) == comparable_options(legacy)
      end)
    end

    test "uses hosted and compatible provider identities instead of upstream protocols" do
      azure_model = model(:azure, "gpt-4o")
      vertex_model = model(:google_vertex, "gemini-2.5-flash")
      openrouter_model = model(:openrouter, "openai/gpt-4.1-mini")

      assert {:ok, azure_opts, []} =
               Namespace.normalize(ReqLLM.Providers.Azure, :chat, azure_model,
                 provider_options: [azure: [deployment: "deployment"]]
               )

      assert azure_opts[:provider_options] == [deployment: "deployment"]

      assert {:ok, vertex_opts, []} =
               Namespace.normalize(ReqLLM.Providers.GoogleVertex, :chat, vertex_model,
                 provider_options: [google_vertex: [project_id: "project"]]
               )

      assert vertex_opts[:provider_options] == [project_id: "project"]

      assert {:error, %ReqLLM.Error.Invalid.Parameter{}} =
               Namespace.normalize(ReqLLM.Providers.Azure, :chat, azure_model,
                 provider_options: [openai: [deployment: "deployment"]]
               )

      assert {:error, %ReqLLM.Error.Invalid.Parameter{}} =
               Namespace.normalize(ReqLLM.Providers.GoogleVertex, :chat, vertex_model,
                 provider_options: [google: [project_id: "project"]]
               )

      assert {:error, %ReqLLM.Error.Invalid.Parameter{}} =
               Namespace.normalize(ReqLLM.Providers.OpenRouter, :chat, openrouter_model,
                 provider_options: [openai: [openrouter_route: "fallback"]]
               )
    end

    test "makes normalized provider options available to request planning" do
      assert {:ok, plan} =
               ReqLLM.RequestPlan.build("openai:gpt-4o-mini", :chat,
                 stream: true,
                 provider_options: [openai: [openai_stream_transport: :websocket]]
               )

      assert plan.transport == :websocket
      assert plan.options[:provider_options] == [openai_stream_transport: :websocket]

      assert {:ok, diagnostic} =
               ReqLLM.plan("openai:gpt-4o-mini", :chat,
                 stream: true,
                 provider_options: [openai: [openai_stream_transport: :websocket]]
               )

      assert diagnostic.transport == :websocket
      assert :openai_stream_transport in diagnostic.options.canonical
      refute :openai in diagnostic.options.canonical

      assert {:ok, flat_map_plan} =
               ReqLLM.RequestPlan.build("openai:gpt-4o-mini", :chat,
                 provider_options: %{"reasoning_summary" => "auto"}
               )

      assert flat_map_plan.options[:provider_options] == [reasoning_summary: "auto"]
    end

    test "keeps namespace validation actionable in sanitized planning errors" do
      assert {:error, %ReqLLM.Error.Invalid.Parameter{} = error} =
               ReqLLM.plan("openai:gpt-4o-mini", :chat,
                 provider_options: [anthropic: [anthropic_top_k: 20]]
               )

      assert Exception.message(error) =~ "namespace :anthropic"
      assert Exception.message(error) =~ "selected provider :openai"
    end
  end

  defp model(provider, id \\ "model") do
    %LLMDB.Model{provider: provider, id: id}
  end

  defp comparable_options(options) do
    Keyword.drop(options, [:base_url, :telemetry_original_opts])
  end
end
