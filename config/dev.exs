import Config

config :git_hooks,
  auto_install: false,
  verbose: true,
  hooks: [
    pre_push: [
      tasks: [
        {ReqLLM.GitHooks.BdWrapper, :pre_push},
        {:mix_task, :format, ["--check-formatted"]}
      ]
    ],
    pre_commit: [
      tasks: [
        {ReqLLM.GitHooks.BdWrapper, :pre_commit}
      ]
    ]
  ]
