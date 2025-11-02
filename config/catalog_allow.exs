import Config

# Anthropic - All Claude models
anthropic_models = :all

# OpenAI - Selected GPT models
openai_models = ~w(
  gpt-4o-mini
  gpt-4-turbo
  gpt-4o
  o1-mini
  o1-preview
)

# Google - Gemini 2.x series
google_models = ~w(
  gemini-2.0-*
  gemini-2.5-*
)

# Groq - LLaMA and DeepSeek models
groq_models = ~w(
  llama-3.3-70b-versatile
  deepseek-r1-*
)

# xAI - Grok models
xai_models = ~w(
  grok-2-latest
  grok-3-mini
)

# OpenRouter - Proxied models
openrouter_models = ~w(
  x-ai/grok-4-fast
  anthropic/claude-sonnet-4
)

# Amazon Bedrock - Various models
amazon_bedrock_models = ~w(
  global.anthropic.*
  us.anthropic.*
  openai.gpt-oss-20b-1:0
  openai.gpt-oss-120b-1:0
  us.meta.llama3-2-3b-instruct-v1:0
  cohere.command-r-v1:0
  cohere.command-r-plus-v1:0
)

# Google Vertex AI (Anthropic models)
google_vertex_anthropic_models = ~w(
  claude-*-4-5*@*
)

config :req_llm, :catalog,
  allow: %{
    anthropic: anthropic_models,
    openai: openai_models,
    google: google_models,
    groq: groq_models,
    xai: xai_models,
    openrouter: openrouter_models,
    amazon_bedrock: amazon_bedrock_models,
    google_vertex_anthropic: google_vertex_anthropic_models
  },
  overrides: [],
  custom: []
