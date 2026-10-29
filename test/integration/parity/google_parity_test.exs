defmodule ReqLLM.Parity.GoogleParityTest do
  use ExUnit.Case, async: true

  import ReqLLM.Parity.TestHelper

  @moduletag :parity
  @moduletag :google
  @moduletag :integration

  parity_contract(model: "google:gemini-2.0-flash")
end
