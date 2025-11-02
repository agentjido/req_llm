import Config

# Anthropic - All Claude models (all passing)
anthropic_models = :all

# OpenAI - GPT models (all passing)
openai_models = ~w(
  gpt-4o-mini
  gpt-4-turbo
  gpt-4o
  o1-mini
  o1-preview
)

# Google - Gemini 2.5 series only (2.0 models have fixture issues)
google_models = :all

# Groq - Working models only (exclude llama-guard-4-12b and llama-4-scout)
groq_models = ~w(
  llama-3.1-8b-instant
  llama-3.3-70b-versatile
  meta-llama/llama-4-maverick-17b-128e-instruct
  moonshotai/kimi-k2-instruct-0905
  openai/gpt-oss-120b
  openai/gpt-oss-20b
  qwen/qwen3-32b
)

# xAI - All Grok models (all passing)
xai_models = :all

# OpenRouter - Proxied models (all passing)
openrouter_models = ~w(
  x-ai/grok-4-fast
  anthropic/claude-sonnet-4
)

# Amazon Bedrock - Cohere models only (other patterns need credentials)
amazon_bedrock_models = ~w(
  cohere.command-r-v1:0
  cohere.command-r-plus-v1:0
)

# Google Vertex AI - Disabled (requires GCP project ID)
google_vertex_anthropic_models = []

config :req_llm, :catalog,
  allow: %{
    anthropic: anthropic_models,
    openai: :all,
    google: google_models,
    groq: groq_models,
    xai: xai_models,
    openrouter: openrouter_models,
    amazon_bedrock: amazon_bedrock_models,
    google_vertex_anthropic: google_vertex_anthropic_models
  },
  overrides: [],
  custom: []
