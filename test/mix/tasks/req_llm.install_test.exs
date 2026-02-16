defmodule Mix.Tasks.ReqLlm.InstallTest do
  use ExUnit.Case, async: true
  import Igniter.Test

  test "installer posts correct notice" do
    test_project()
    |> Igniter.compose_task("req_llm.install", [])
    |> assert_has_notice("""
    ReqLLM installed successfully !

    Next Steps:
      1. Check out the Quickstart guide: 
        https://hexdocs.pm/req_llm/getting-started.html

      2. Explore demo usage:
        https://github.com/agentjido/req_llm/tree/main/lib/examples
    """)
  end
end
