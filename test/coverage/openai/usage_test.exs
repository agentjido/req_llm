defmodule ReqLLM.Coverage.OpenAI.UsageTest do
  @moduledoc """
  OpenAI provider usage calculation tests.

  Tests cost calculations, cached token handling, and usage metrics 
  for OpenAI models using live/fixture mode.
  """

  use ReqLLM.ProviderTest.Usage, provider: :openai, model: "openai:gpt-4o-mini"
end
