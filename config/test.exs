import Config

config :logger, :console,
  level: :warning,
  format: "$time $metadata[$level] $message\n",
  metadata: [:req_llm, :component]

config :req_llm, :catalog,
  allow: %{},
  overrides: [],
  custom: []
