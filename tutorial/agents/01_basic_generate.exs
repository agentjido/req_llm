# tutorial/agents/01_basic_generate.exs
#
# Chapter 1: LLM as a function
# Goal: Show that an LLM call is just a pure function: prompt -> text.
#
# Run with:
#   iex -S mix run tutorial/agents/01_basic_generate.exs

# We are running in the :dev environment of the project, so `req_llm` is already available.
# If running as a standalone script, you would use Mix.install/1.

require IEx

# Ensure dotenvy loads .env file if present
_ = Dotenvy.source(".env")

model = System.get_env("REQ_LLM_MODEL", "anthropic:claude-haiku-4.5")

IO.puts(">> 1. Asking the model a simple question (Model: #{model})...")
IO.puts("   (Pausing for inspection. Type `continue` or `respawn` to proceed.)")

# A simple synchronous call.
# No tools, no streaming, just a prompt string.
{:ok, response} = ReqLLM.generate_text(model, "Explain why Elixir is great in one sentence.")

IO.puts(">> 2. Response received.")
IEx.pry()

# Extract the text from the response
text = ReqLLM.Response.text(response)

IO.puts("\n>> Answer:\n")
IO.puts(text)
