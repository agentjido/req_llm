defmodule ReqLLM.Parity.OpenAIChatParityTest do
  use ExUnit.Case, async: true

  import ReqLLM.Parity.TestHelper

  @moduletag :parity
  @moduletag :openai
  @moduletag :integration

  parity_contract(model: "openai:gpt-4-turbo")
end
