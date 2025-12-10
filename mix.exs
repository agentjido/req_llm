defmodule ReqLLM.MixProject do
  use Mix.Project

  @version "1.0.0"
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
        plt_add_apps: [:mix],
        ignore_warnings: ".dialyzer_ignore.exs"
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
          "guides/core-concepts.md",
          "guides/data-structures.md",
          "guides/model-metadata.md",
          "guides/mix-tasks.md",
          "guides/fixture-testing.md",
          "guides/adding_a_provider.md",
          "guides/anthropic.md",
          "guides/openai.md",
          "guides/google.md",
          "guides/google_vertex.md",
          "guides/xai.md",
          "guides/groq.md",
          "guides/openrouter.md",
          "guides/amazon_bedrock.md",
          "guides/cerebras.md",
          "guides/meta.md",
          "guides/zai.md",
          "guides/zai_coder.md"
        ],
        groups_for_extras: [
          Overview: [
            "README.md"
          ],
          Guides: [
            "guides/getting-started.md",
            "guides/core-concepts.md",
            "guides/data-structures.md",
            "guides/model-metadata.md"
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
            "guides/google_vertex.md",
            "guides/xai.md",
            "guides/groq.md",
            "guides/openrouter.md",
            "guides/amazon_bedrock.md",
            "guides/cerebras.md",
            "guides/meta.md",
            "guides/zai.md",
            "guides/zai_coder.md"
          ],
          Changelog: ["CHANGELOG.md"],
          Contributing: ["CONTRIBUTING.md"]
        ],
        groups_for_modules: [
          Providers: ~r/ReqLLM\.Providers\..*/,
          Steps: ~r/ReqLLM\.Step\..*/,
          Streaming: ~r/ReqLLM\.Streaming.*/,
          "Data Structures": [
            ReqLLM.Message,
            ReqLLM.Message.ContentPart,
            ReqLLM.Response,
            ReqLLM.Response.Stream,
            ReqLLM.StreamResponse,
            ReqLLM.StreamChunk,
            ReqLLM.Tool,
            ReqLLM.ToolCall,
            ReqLLM.Generation,
            ReqLLM.Embedding,
            ReqLLM.Context,
            ReqLLM.Schema
          ],
          "Provider API": [
            ReqLLM.Provider,
            ReqLLM.Provider.DSL,
            ReqLLM.Provider.Registry,
            ReqLLM.Provider.Options,
            ReqLLM.Provider.Utils,
            ReqLLM.Provider.Defaults,
            ReqLLM.Provider.ResponseBuilder,
            ReqLLM.Provider.Defaults.ResponseBuilder
          ],
          Core: [
            ReqLLM,
            ReqLLM.ModelHelpers,
            ReqLLM.Model.Metadata,
            ReqLLM.Metadata,
            ReqLLM.Capability,
            ReqLLM.Keys,
            ReqLLM.Error,
            ReqLLM.Debug,
            ReqLLM.ParamTransform
          ]
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
      {:server_sent_events, "~> 0.2"},
      {:splode, "~> 0.2.3"},
      {:typedstruct, "~> 0.5"},
      {:uniq, "~> 0.6"},
      {:zoi, "~> 0.10"},
      {:jsv, "~> 0.11"},
      {:llm_db, github: "agentjido/llm_db", branch: "main", override: true},

      # Dev/test dependencies
      {:bandit, "~> 1.8", only: :dev, runtime: false},
      {:tidewave, "~> 0.5", only: :dev, runtime: false},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:quokka, "== 2.11.2", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: [:dev, :test], runtime: false},
      {:plug, "~> 1.0", only: [:dev, :test], runtime: false},
      {:git_hooks, "~> 0.8", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      description: "Composable Elixir library for LLM interactions built on Req & Finch",
      licenses: ["Apache-2.0"],
      maintainers: ["Mike Hostetler"],
      links: %{
        "Changelog" => "https://hexdocs.pm/req_llm/changelog.html",
        "GitHub" => @source_url,
        "Elixir AI Discord" => "https://agentjido.xyz/discord"
      },
      files:
        ~w(lib priv mix.exs LICENSE README.md CHANGELOG.md CONTRIBUTING.md AGENTS.md usage-rules.md guides .formatter.exs)
    ]
  end

  defp aliases do
    [
      quality: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "dialyzer",
        "credo --strict"
      ],
      q: ["quality"],
      docs: ["docs --formatter html"],
      mc: ["req_llm.model_compat"],
      llm: ["req_llm.gen"]
    ]
  end
end
