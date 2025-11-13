[
  # False positive in Elixir 1.19 - IO.inspect/2 with label option is valid
  # The call will never return since it differs in the 2nd argument
  {"lib/mix/tasks/gen.ex", :call},
  # LLMDB.Model is a compile-time only dependency (runtime: false)
  {"lib/req_llm/model.ex", :unknown_type}
]
