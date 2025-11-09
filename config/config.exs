import Config

config :llm_db,
  filter: %{
    allow: %{
      amazon_bedrock: ["*"],
      anthropic: ["*"],
      azure: ["*"],
      cerebras: ["*"],
      google: ["*"],
      google_vertex: ["*"],
      google_vertex_anthropic: ["*"],
      groq: ["*"],
      openai: ["*"],
      openrouter: ["*"],
      venice: ["*"],
      xai: ["*"],
      zai: ["*"],
      zai_coder: ["*"]
    },
    deny: %{
      anthropic: [
        "claude-3.7-sonnet"
      ],
      cerebras: [
        "zai-glm-4.6"
      ],
      google: [
        "gemini-2.0-flash-001",
        "gemini-2.0-flash-exp:free",
        "gemini-2.0-flash-lite-001",
        "gemini-2.5-pro-preview",
        "gemma-*"
      ],
      groq: [
        "meta-llama/llama-4-scout-17b-16e-instruct",
        "meta-llama/llama-guard-4-12b"
      ],
      openai: [
        "codex-mini",
        "chatgpt-4o-latest",
        "gpt-3.5-turbo",
        "gpt-3.5-turbo-0613",
        "gpt-3.5-turbo-16k",
        "gpt-3.5-turbo-instruct",
        "gpt-4-0314",
        "gpt-4-1106-preview",
        "gpt-4-turbo-preview",
        "gpt-4o-audio-preview",
        "gpt-4o-mini-2024-07-18",
        "gpt-4o-mini-search-preview",
        "gpt-4o-search-preview",
        "gpt-4o:extended",
        "gpt-5-chat",
        "gpt-5-image",
        "gpt-5-image-mini",
        "gpt-oss-120b",
        "gpt-oss-120b:exacto",
        "gpt-oss-20b",
        "gpt-oss-20b:free",
        "gpt-oss-safeguard-20b",
        "o3-mini-high",
        "o4-mini-high"
      ],
      openrouter: [
        "auto",
        "deepseek/deepseek-chat-v3.1",
        "deepseek/deepseek-v3.1-terminus",
        "minimax/minimax-01",
        "minimax/minimax-m1",
        "minimax/minimax-m2:free",
        "moonshotai/kimi-k2-thinking",
        "nvidia/nemotron-nano-9b-v2",
        "openai/gpt-5-image",
        "openai/gpt-oss-120b:exacto",
        "openrouter/polaris-alpha",
        "polaris-alpha",
        "qwen/qwen3-coder",
        "qwen/qwen3-next-80b-a3b-instruct",
        "x-ai/grok-3",
        "x-ai/grok-3-beta"
      ]
    }
  }

config :req_llm,
  receive_timeout: 120_000,
  stream_receive_timeout: 120_000,
  req_connect_timeout: 60_000,
  req_pool_timeout: 120_000,
  metadata_timeout: 120_000,
  thinking_timeout: 300_000

if System.get_env("REQ_LLM_DEBUG") in ~w(1 true yes on) do
  config :logger, level: :debug

  config :req_llm, :debug, true
end

# Git hooks and git_ops configuration for conventional commits
if config_env() == :dev do
  config :git_hooks,
    auto_install: true,
    verbose: true,
    hooks: [
      commit_msg: [
        tasks: [
          {:cmd, "mix git_ops.check_message", include_hook_args: true}
        ]
      ]
    ]

  config :git_ops,
    mix_project: ReqLLM.MixProject,
    changelog_file: "CHANGELOG.md",
    repository_url: "https://github.com/agentjido/req_llm",
    manage_mix_version?: true,
    version_tag_prefix: "v",
    types: [
      feat: [header: "Features"],
      fix: [header: "Bug Fixes"],
      perf: [header: "Performance"],
      refactor: [header: "Refactoring"],
      docs: [hidden?: true],
      test: [hidden?: true],
      chore: [hidden?: true],
      ci: [hidden?: true]
    ]
end

if config_env() in [:dev, :test] do
  import_config "#{config_env()}.exs"
end
