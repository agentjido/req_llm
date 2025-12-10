import Config

config :llm_db,
  compile_embed: false,
  integrity_policy: :warn,
  custom: %{
    anthropic: [
      name: "Anthropic",
      base_url: "https://api.anthropic.com",
      env: ["ANTHROPIC_API_KEY"],
      doc: "https://docs.anthropic.com",
      models: %{
        "claude-sonnet-4-5-20250929" => %{
          name: "Claude Sonnet 4.5",
          family: "claude-4.5",
          capabilities: %{chat: true, tools: %{enabled: true, streaming: true}},
          limits: %{context: 200_000, output: 8192},
          cost: %{input: 3.0, output: 15.0}
        },
        "claude-3-5-haiku-20241022" => %{
          name: "Claude 3.5 Haiku",
          family: "claude-3.5",
          capabilities: %{chat: true, tools: %{enabled: true, streaming: true}},
          limits: %{context: 200_000, output: 8192},
          cost: %{input: 0.8, output: 4.0}
        },
        "claude-3-sonnet-20240229" => %{
          name: "Claude 3 Sonnet",
          family: "claude-3",
          capabilities: %{chat: true, tools: %{enabled: true}},
          limits: %{context: 200_000, output: 4096}
        },
        "claude-3-haiku-20240307" => %{
          name: "Claude 3 Haiku",
          family: "claude-3",
          capabilities: %{chat: true, tools: %{enabled: true}},
          limits: %{context: 200_000, output: 4096},
          aliases: ["claude-3-haiku"]
        }
      }
    ],
    openai: [
      name: "OpenAI",
      base_url: "https://api.openai.com/v1",
      env: ["OPENAI_API_KEY"],
      doc: "https://platform.openai.com/docs",
      models: %{
        "gpt-4o-mini" => %{
          name: "GPT-4o mini",
          family: "gpt-4o",
          capabilities: %{chat: true, tools: %{enabled: true, streaming: true}},
          limits: %{context: 128_000, output: 16_384},
          cost: %{input: 0.15, output: 0.60}
        },
        "gpt-3.5-turbo" => %{
          name: "GPT-3.5 Turbo",
          family: "gpt-3.5",
          capabilities: %{chat: true, tools: %{enabled: true, streaming: true}},
          limits: %{context: 16_385, output: 4096},
          cost: %{input: 0.50, output: 1.50}
        },
        "gpt-4" => %{
          name: "GPT-4",
          family: "gpt-4",
          capabilities: %{chat: true, tools: %{enabled: true}},
          limits: %{context: 8192, output: 8192}
        },
        "gpt-4o" => %{
          name: "GPT-4o",
          family: "gpt-4o",
          capabilities: %{chat: true, tools: %{enabled: true, streaming: true}},
          limits: %{context: 128_000, output: 16_384}
        },
        "o1-mini" => %{
          name: "o1-mini",
          family: "o1",
          capabilities: %{chat: true, reasoning: %{enabled: true}},
          limits: %{context: 128_000, output: 65_536},
          extra: %{api: "responses"}
        },
        "o3-mini" => %{
          name: "o3-mini",
          family: "o3",
          capabilities: %{chat: true, reasoning: %{enabled: true}},
          limits: %{context: 200_000, output: 100_000},
          extra: %{api: "responses"}
        },
        "o4-mini" => %{
          name: "o4-mini",
          family: "o4",
          capabilities: %{
            chat: true,
            reasoning: %{enabled: true},
            tools: %{enabled: true, streaming: true}
          },
          limits: %{context: 200_000, output: 100_000},
          extra: %{api: "responses"}
        },
        "gpt-5" => %{
          name: "GPT-5",
          family: "gpt-5",
          capabilities: %{chat: true, tools: %{enabled: true}},
          limits: %{context: 200_000, output: 32_768},
          extra: %{api: "responses"}
        },
        "gpt-5-mini" => %{
          name: "GPT-5 mini",
          family: "gpt-5",
          capabilities: %{chat: true, tools: %{enabled: true}},
          limits: %{context: 128_000, output: 16_384},
          extra: %{api: "responses"}
        },
        "gpt-5-nano" => %{
          name: "GPT-5 nano",
          family: "gpt-5",
          capabilities: %{chat: true, tools: %{enabled: true}},
          limits: %{context: 64_000, output: 8192},
          extra: %{api: "responses"}
        },
        "text-embedding-3-small" => %{
          name: "Text Embedding 3 Small",
          family: "embedding",
          capabilities: %{embeddings: true}
        },
        "text-embedding-3-large" => %{
          name: "Text Embedding 3 Large",
          family: "embedding",
          capabilities: %{embeddings: true}
        }
      }
    ],
    google: [
      name: "Google",
      base_url: "https://generativelanguage.googleapis.com",
      env: ["GOOGLE_API_KEY"],
      models: %{
        "gemini-2.0-flash" => %{
          name: "Gemini 2.0 Flash",
          family: "gemini-2",
          capabilities: %{chat: true, tools: %{enabled: true, streaming: true}},
          limits: %{context: 1_000_000, output: 8192}
        },
        "gemini-2.0-flash-exp" => %{
          name: "Gemini 2.0 Flash Exp",
          family: "gemini-2",
          capabilities: %{chat: true, tools: %{enabled: true, streaming: true}},
          limits: %{context: 1_000_000, output: 8192}
        },
        "gemini-1.5-pro" => %{
          name: "Gemini 1.5 Pro",
          family: "gemini-1.5",
          capabilities: %{chat: true, tools: %{enabled: true}},
          limits: %{context: 2_000_000, output: 8192}
        },
        "gemini-1.5-flash" => %{
          name: "Gemini 1.5 Flash",
          family: "gemini-1.5",
          capabilities: %{chat: true, tools: %{enabled: true, streaming: true}},
          limits: %{context: 1_000_000, output: 8192}
        },
        "text-embedding-004" => %{
          name: "Text Embedding 004",
          family: "embedding",
          capabilities: %{embeddings: true}
        },
        "gemini-embedding-001" => %{
          name: "Gemini Embedding 001",
          family: "embedding",
          capabilities: %{embeddings: true}
        }
      }
    ],
    groq: [
      name: "Groq",
      base_url: "https://api.groq.com",
      env: ["GROQ_API_KEY"],
      models: %{
        "llama3-8b-8192" => %{
          name: "Llama 3 8B",
          family: "llama3",
          capabilities: %{chat: true},
          limits: %{context: 8192, output: 8192}
        },
        "llama-3.1-8b-instant" => %{
          name: "Llama 3.1 8B Instant",
          family: "llama3",
          capabilities: %{chat: true, tools: %{enabled: true}},
          limits: %{context: 8192, output: 8192}
        }
      }
    ],
    xai: [
      name: "xAI",
      base_url: "https://api.x.ai",
      env: ["XAI_API_KEY"],
      models: %{
        "grok-2" => %{
          name: "Grok 2",
          family: "grok",
          capabilities: %{chat: true, tools: %{enabled: true}},
          limits: %{context: 131_072, output: 8192}
        },
        "grok-2-1212" => %{
          name: "Grok 2 1212",
          family: "grok",
          capabilities: %{chat: true, tools: %{enabled: true}},
          limits: %{context: 131_072, output: 8192}
        },
        "grok-3" => %{
          name: "Grok 3",
          family: "grok",
          capabilities: %{chat: true, tools: %{enabled: true}},
          limits: %{context: 131_072, output: 8192}
        },
        "grok-3-mini" => %{
          name: "Grok 3 mini",
          family: "grok",
          capabilities: %{chat: true, tools: %{enabled: true}},
          limits: %{context: 131_072, output: 8192}
        },
        "grok-4" => %{
          name: "Grok 4",
          family: "grok",
          capabilities: %{chat: true, tools: %{enabled: true}},
          limits: %{context: 131_072, output: 8192}
        },
        "grok-beta" => %{
          name: "Grok Beta",
          family: "grok",
          capabilities: %{chat: true, tools: %{enabled: true}},
          limits: %{context: 131_072, output: 8192}
        }
      }
    ],
    openrouter: [
      name: "OpenRouter",
      base_url: "https://openrouter.ai/api/v1",
      env: ["OPENROUTER_API_KEY"],
      models: %{
        "openai/gpt-4" => %{
          name: "OpenAI GPT-4",
          family: "gpt-4",
          capabilities: %{chat: true, tools: %{enabled: true}},
          limits: %{context: 8192, output: 8192}
        },
        "anthropic/claude-3-haiku" => %{
          name: "Claude 3 Haiku",
          family: "claude-3",
          capabilities: %{chat: true, tools: %{enabled: true}},
          limits: %{context: 200_000, output: 4096},
          aliases: []
        }
      }
    ],
    amazon_bedrock: [
      name: "Amazon Bedrock",
      base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
      env: ["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"],
      models: %{
        "anthropic.claude-3-haiku-20240307-v1:0" => %{
          name: "Claude 3 Haiku",
          family: "claude-3",
          capabilities: %{chat: true, tools: %{enabled: true}},
          limits: %{context: 200_000, output: 4096}
        },
        "cohere.command-text-v14" => %{
          name: "Cohere Command Text v14",
          family: "command",
          capabilities: %{chat: true},
          limits: %{context: 4096, output: 4096}
        }
      }
    ]
  }

config :logger, :console,
  level: :warning,
  format: "$time $metadata[$level] $message\n",
  metadata: [:req_llm, :component]

config :req_llm, :sample_embedding_models, ~w(
    openai:text-embedding-3-small
    google:text-embedding-004
  )
config :req_llm, :sample_text_models, ~w(
    anthropic:claude-3-5-haiku-20241022
    openai:gpt-4o-mini
    google:gemini-2.0-flash
  )
config :req_llm, :test_sample_per_provider, 1
