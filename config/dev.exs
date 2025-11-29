import Config

config :git_hooks,
  auto_install: false,
  verbose: true,
  hooks: [
    pre_push: [
      tasks: [
        {:mix_task, :format, ["--check-formatted"]}
      ]
    ]
  ]
