import Config

config :req_llm, :sample_embedding_models, ~w(
    openai:text-embedding-3-small
    google:text-embedding-004
  )
config :req_llm, :sample_text_models, ~w(
    openai:gpt-4o-mini
    anthropic:claude-3-5-haiku-20241022
    google:gemini-1.5-flash
  )
config :req_llm, :test_embedding_models, ~w(
    openai:text-embedding-3-small
    openai:text-embedding-3-large
    openai:text-embedding-ada-002
    google:text-embedding-004
    google:gemini-embedding-001
  )
config :req_llm, :test_models, ~w(
    anthropic:claude-3-5-haiku-20241022
    anthropic:claude-3-5-sonnet-20241022
    openai:gpt-4o-mini
    openai:gpt-3.5-turbo
    google:gemini-1.5-flash
    google:gemini-1.5-pro
    groq:gemma2-9b-it
    groq:llama-3.1-8b-instant
    xai:grok-2-latest
    xai:grok-3-fast
    openrouter:x-ai/grok-4-fast:free
  )

if config_env() == :test do
  import_config "#{config_env()}.exs"
end
