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
