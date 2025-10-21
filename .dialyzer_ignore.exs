[
  # False positive in Elixir 1.19 - IO.inspect/2 with label option is valid
  # The call will never return since it differs in the 2nd argument
  {"lib/mix/tasks/gen.ex", :call},
  # False positive - Usage.handle/1 correctly handles request/response tuple
  {"lib/req_llm/response.ex", :call}
]
