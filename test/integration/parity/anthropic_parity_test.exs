defmodule ReqLLM.Parity.AnthropicParityTest do
  use ExUnit.Case, async: true

  import ReqLLM.Parity.TestHelper

  @moduletag :parity
  @moduletag :anthropic
  @moduletag :integration

  parity_contract(model: "anthropic:claude-3-haiku-20240307")
end
