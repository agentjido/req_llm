defmodule ReqLLM.Providers.AnthropicTest do
  @moduledoc """
  Provider contract tests for the Anthropic implementation.
  """

  use ReqLLM.ProviderCase, provider: ReqLLM.Providers.Anthropic, async: true
end
