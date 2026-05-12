defmodule ReqLLM.MixProject do
  use Mix.Project

  @version "1.11.0"
  @source_url "https://github.com/agentjido/req_llm"

  def project do
    [
      app: :req_llm,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      elixirc_paths: elixirc_paths(Mix.env()),

      # Test coverage
      test_coverage: [tool: ExCoveralls, export: "cov", exclude: [:coverage]],

      # Dialyzer configuration
      dialyzer: [
        plt_add_apps: [:mix, :llm_db],
        exclude_paths: ["test/support"]
      ],

      # Package
      package: package(),

      # Documentation
      name: "ReqLLM",
      source_url: @source_url,
      homepage_url: @source_url,
      source_ref: "v#{@version}",
      docs: [
        main: "overview",
        extras: [
          {"README.md", title: "Overview", filename: "overview"},
          "CHANGELOG.md",
          "CONTRIBUTING.md",
          "guides/getting-started.md",
          "guides/configuration.md",
          "guides/telemetry.md",
          "guides/core-concepts.md",
          "guides/data-structures.md",
          "guides/pricing-policy.md",
          "guides/model-specs.md",
          "guides/usage-and-billing.md",
          "guides/image-generation.md",
          "guides/model-metadata.md",
          "guides/getting-started.livemd",
          "guides/image-generation.livemd",
          "guides/mix-tasks.md",
          "guides/fixture-testing.md",
          "guides/adding_a_provider.md",
          "guides/anthropic.md",
          "guides/openai.md",
          "guides/google.md",
          "guides/azure.md",
          "guides/google_vertex.md",
          "guides/xai.md",
          "guides/groq.md",
          "guides/openrouter.md",
          "guides/ollama.md",
          "guides/amazon_bedrock.md",
          "guides/cerebras.md",
          "guides/deepseek.md",
          "guides/meta.md",
          "guides/zenmux.md",
          "guides/zai.md",
          "guides/zai_coder.md"
        ],
        groups_for_extras: [
          Overview: [
            "README.md"
          ],
          Guides: [
            "guides/getting-started.md",
            "guides/configuration.md",
            "guides/telemetry.md",
            "guides/core-concepts.md",
            "guides/data-structures.md",
            "guides/pricing-policy.md",
            "guides/model-specs.md",
            "guides/usage-and-billing.md",
            "guides/image-generation.md",
            "guides/model-metadata.md"
          ],
          Livebooks: [
            "guides/getting-started.livemd",
            "guides/image-generation.livemd"
          ],
          "Development & Testing": [
            "guides/mix-tasks.md",
            "guides/fixture-testing.md",
            "guides/adding_a_provider.md"
          ],
          Providers: [
            "guides/anthropic.md",
            "guides/openai.md",
            "guides/google.md",
            "guides/azure.md",
            "guides/google_vertex.md",
            "guides/xai.md",
            "guides/groq.md",
            "guides/openrouter.md",
            "guides/ollama.md",
            "guides/amazon_bedrock.md",
            "guides/cerebras.md",
            "guides/deepseek.md",
            "guides/meta.md",
            "guides/zenmux.md",
            "guides/zai.md",
            "guides/zai_coder.md"
          ],
          Changelog: ["CHANGELOG.md"],
          Contributing: ["CONTRIBUTING.md"]
        ],
        groups_for_modules: [
          "Top-Level API": [
            ReqLLM,
            ReqLLM.Images,
            ReqLLM.Context,
            ReqLLM.Schema
          ],
          Utilities: [
            ReqLLM.ModelHelpers,
            ReqLLM.Model.Metadata,
            ReqLLM.Metadata,
            ReqLLM.Telemetry,
            ReqLLM.Telemetry.OpenTelemetry,
            ReqLLM.OpenTelemetry,
            ReqLLM.Capability,
            ReqLLM.Keys,
            ReqLLM.Usage,
            ReqLLM.Error,
            ReqLLM.Debug,
            ReqLLM.ParamTransform
          ],
          "Data Structures": [
            ReqLLM.Message,
            ReqLLM.Message.ContentPart,
            ReqLLM.Message.ReasoningDetails,
            ReqLLM.Response,
            ReqLLM.Response.Stream,
            ReqLLM.StreamResponse,
            ReqLLM.StreamResponse.MetadataHandle,
            ReqLLM.StreamChunk,
            ReqLLM.Tool,
            ReqLLM.ToolCall,
            ReqLLM.ToolResult,
            ReqLLM.Generation,
            ReqLLM.Embedding
          ],
          Steps: ~r/ReqLLM\.Step\..*/,
          Streaming: [~r/ReqLLM\.Streaming.*/, ReqLLM.StreamServer],
          Transcription: ~r/ReqLLM\.Transcription.*/,
          Speech: ~r/ReqLLM\.Speech.*/,
          "Provider Extension API": [
            ReqLLM.Provider,
            ReqLLM.Provider.DSL,
            ReqLLM.Provider.Registry,
            ReqLLM.Provider.Options,
            ReqLLM.Provider.Utils,
            ReqLLM.Providers,
            ReqLLM.Provider.Defaults,
            ReqLLM.Provider.ResponseBuilder,
            ReqLLM.Provider.Defaults.ResponseBuilder
          ],
          Providers: ~r/ReqLLM\.Providers\..*/
        ]
      ]
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test,
        "coveralls.github": :test
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :xmerl],
      included_applications: [:llm_db],
      mod: {ReqLLM.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:jason, "~> 1.4"},
      {:dotenvy, "~> 1.1"},
      {:nimble_options, "~> 1.1"},
      {:req, "~> 0.5"},
      {:ex_aws_auth, "~> 1.3"},
      {:server_sent_events, "~> 1.0.0"},
      {:splode, "~> 0.3.0"},
      {:uniq, "~> 0.6"},
      {:websockex, "~> 0.5.1"},
      {:zoi, "~> 0.14"},
      {:jsv, "~> 0.11"},
      {:llm_db, "~> 2026.5.0"},

      # Dev/test dependencies
      {:bandit, "~> 1.8", only: [:dev, :test], runtime: false},
      {:tidewave, "~> 0.5", only: :dev, runtime: false},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: [:dev, :test], runtime: false},
      {:plug, "~> 1.0", only: [:dev, :test], runtime: false},
      {:websock_adapter, "~> 0.6.0", only: [:dev, :test], runtime: false},
      {:git_ops, "~> 2.9", only: :dev, runtime: false},
      {:git_hooks, "~> 0.8", only: :dev, runtime: false},

      # Optional
      {:igniter, "~> 0.7", optional: true}
    ]
  end

  defp package do
    [
      description: "Composable Elixir library for LLM interactions built on Req & Finch",
      licenses: ["Apache-2.0"],
      maintainers: ["Mike Hostetler"],
      links: %{
        "Changelog" => "https://hexdocs.pm/req_llm/changelog.html",
        "Discord" => "https://agentjido.xyz/discord",
        "Documentation" => "https://hexdocs.pm/req_llm",
        "GitHub" => @source_url,
        "Website" => "https://agentjido.xyz"
      },
      files:
        ~w(lib priv mix.exs LICENSE README.md CHANGELOG.md CONTRIBUTING.md AGENTS.md usage-rules.md guides .formatter.exs)
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "git_hooks.install"],
      quality: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict",
        "dialyzer"
      ],
      q: ["quality"],
      docs: ["docs --formatter html"],
      mc: ["req_llm.model_compat"],
      llm: ["req_llm.gen"],
      "test.livebooks": ["test.livebooks"]
    ]
  end
end
