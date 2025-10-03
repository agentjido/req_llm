import Config

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
  )

if config_env() == :test do
  import_config "#{config_env()}.exs"
end
