import Config

config :req_llm, :catalog,
  allow: %{},
  overrides: [],
  custom: []

config :req_llm, :catalog_enabled?, false
config :req_llm, :sample_embedding_models, ~w(
    openai:text-embedding-3-small
    google:text-embedding-004
  )
config :req_llm, :sample_text_models, ~w(
    anthropic:claude-3-5-haiku-20241022
    anthropic:claude-3-5-sonnet-20241022
    amazon_bedrock:global.anthropic.claude-sonnet-4-5-20250929-v1:0
    amazon_bedrock:global.anthropic.claude-haiku-4-5-20251001-v1:0
    amazon_bedrock:us.anthropic.claude-opus-4-1-20250805-v1:0
    amazon_bedrock:openai.gpt-oss-20b-1:0
    amazon_bedrock:openai.gpt-oss-120b-1:0
    amazon_bedrock:us.meta.llama3-2-3b-instruct-v1:0
    amazon_bedrock:cohere.command-r-v1:0
    amazon_bedrock:cohere.command-r-plus-v1:0
    google_vertex_anthropic:claude-haiku-4-5@20251001
    google_vertex_anthropic:claude-sonnet-4-5@20250929
    google_vertex_anthropic:claude-opus-4-1@20250805
    openai:gpt-4o-mini
    openai:gpt-4-turbo
    google:gemini-2.0-flash
    google:gemini-2.5-flash
    groq:llama-3.3-70b-versatile
    groq:deepseek-r1-distill-llama-70b
    xai:grok-2-latest
    xai:grok-3-mini
    openrouter:x-ai/grok-4-fast
    openrouter:anthropic/claude-sonnet-4
  )

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

if config_env() == :test do
  import_config "#{config_env()}.exs"
end
