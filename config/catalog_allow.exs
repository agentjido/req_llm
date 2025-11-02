import Config

anthropic_models = :all

# OpenAI
# Excluded models:
#   - codex-mini-latest (broken usage/streaming fixtures)
#   - gpt-5-chat-latest (no tool support)
#   - gpt-5-codex (broken object_streaming fixture)
#   - gpt-5-pro (missing fixtures)
#   - o3-pro (broken tool_round_trip fixtures)
#   - o4-mini (broken tool_round_trip fixtures)
openai_models = ~w(
  gpt-3.5-turbo
  gpt-4
  gpt-4.1
  gpt-4.1-mini
  gpt-4.1-nano
  gpt-4-turbo
  gpt-4o
  gpt-4o-2024-05-13
  gpt-4o-2024-08-06
  gpt-4o-2024-11-20
  gpt-4o-mini
  gpt-5
  gpt-5-mini
  gpt-5-nano
  o1
  o3
  o3-mini
)

# Google
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

# OpenRouter - Working models only (53/67 passing, 79.1% coverage)
# Excluded models:
#   - deepseek/deepseek-chat-v3.1 (broken reasoning fixtures)
#   - deepseek/deepseek-v3.1-terminus (broken tool_round_trip_1 fixture)
#   - minimax/minimax-m1 (broken object/reasoning/tool fixtures)
#   - minimax/minimax-01 (404 error, multiple broken fixtures)
#   - minimax/minimax-m2:free (broken object/tool fixtures)
#   - openai/gpt-5-image (fixture not found errors)
#   - x-ai/grok-3 (broken tool/object fixtures)
#   - x-ai/grok-3-beta (broken tool/object fixtures)
#   - x-ai/grok-3-mini (broken tool/object fixtures)
#   - x-ai/grok-3-mini-beta (broken tool/object fixtures)
#   - qwen/qwen3-next-80b-a3b-instruct (broken tool_round_trip_1 fixture)
#   - openai/gpt-oss-120b:exacto (broken tool_round_trip_1 fixture)
#   - z-ai/glm-4.6:exacto (broken object fixtures)
#   - qwen/qwen3-coder (broken object_streaming/basic fixtures)
openrouter_models = ~w(
  anthropic/claude-3.5-haiku
  anthropic/claude-3.7-sonnet
  anthropic/claude-haiku-4.5
  anthropic/claude-opus-4
  anthropic/claude-opus-4.1
  anthropic/claude-sonnet-4
  anthropic/claude-sonnet-4.5
  deepseek/deepseek-chat-v3-0324
  deepseek/deepseek-r1-distill-llama-70b
  deepseek/deepseek-r1-distill-qwen-14b
  deepseek/deepseek-v3.1-terminus:exacto
  google/gemini-2.0-flash-001
  google/gemini-2.5-flash
  google/gemini-2.5-flash-lite
  google/gemini-2.5-flash-lite-preview-09-2025
  google/gemini-2.5-flash-preview-09-2025
  google/gemini-2.5-pro
  google/gemini-2.5-pro-preview-05-06
  google/gemini-2.5-pro-preview-06-05
  google/gemma-3n-e4b-it
  meta-llama/llama-3.2-11b-vision-instruct
  mistralai/codestral-2508
  mistralai/devstral-small-2507
  mistralai/mistral-medium-3
  mistralai/mistral-medium-3.1
  moonshotai/kimi-k2
  moonshotai/kimi-k2-0905
  moonshotai/kimi-k2-0905:exacto
  nousresearch/hermes-4-70b
  openai/gpt-4o-mini
  openai/gpt-5
  openai/gpt-5-codex
  openai/gpt-5-mini
  openai/gpt-5-nano
  openai/gpt-5-pro
  openai/gpt-oss-120b
  openai/gpt-oss-20b
  openai/o4-mini
  qwen/qwen-2.5-coder-32b-instruct
  qwen/qwen2.5-vl-72b-instruct
  qwen/qwen3-235b-a22b-07-25
  qwen/qwen3-235b-a22b-thinking-2507
  qwen/qwen3-30b-a3b-instruct-2507
  qwen/qwen3-30b-a3b-thinking-2507
  qwen/qwen3-coder:exacto
  qwen/qwen3-next-80b-a3b-thinking
  x-ai/grok-4
  x-ai/grok-code-fast-1
  x-ai/grok-4-fast
  z-ai/glm-4.5
  z-ai/glm-4.5-air
  z-ai/glm-4.5v
  z-ai/glm-4.6
)

# Amazon Bedrock - Cohere models only (other patterns need credentials)
amazon_bedrock_models = ~w(
  cohere.command-r-v1:0
  cohere.command-r-plus-v1:0
)

# Google Vertex AI - Disabled (requires GCP project ID)
google_vertex_anthropic_models = []

# zAI - All models
zai_models = :all

# zAI Coder - All models
zai_coder_models = :all

# Cerebras - All models
cerebras_models = :all

config :req_llm, :catalog,
  allow: %{
    anthropic: anthropic_models,
    openai: openai_models,
    google: google_models,
    groq: groq_models,
    xai: xai_models,
    openrouter: openrouter_models,
    amazon_bedrock: amazon_bedrock_models,
    google_vertex_anthropic: google_vertex_anthropic_models,
    zai: zai_models,
    zai_coder: zai_coder_models,
    cerebras: cerebras_models
  },
  overrides: [],
  custom: []
