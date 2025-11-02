import Config

config :req_llm, :catalog_enabled?, true

import_config "catalog_allow.exs"

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
