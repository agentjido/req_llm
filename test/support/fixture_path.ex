defmodule ReqLLM.Test.FixturePath do
  @moduledoc """
  Single source of truth for fixture file paths.

  Converts model specs to sanitized fixture directory paths and handles
  all path construction for both streaming and non-streaming fixtures.
  """

  @root Path.expand("test/support/fixtures")

  @doc "Root directory for all fixtures"
  @spec root() :: String.t()
  def root, do: @root

  @doc """
  Build absolute fixture file path from model and test name.

  Accepts either a %LLMDB.Model{} struct or a "provider:model" string.

  ## Examples

      iex> {:ok, model} = ReqLLM.model("anthropic:claude-3-5-haiku-20241022")
      iex> ReqLLM.Test.FixturePath.file(model, "basic")
      ".../test/support/fixtures/anthropic/claude_3_5_haiku_20241022/basic.json"

      iex> ReqLLM.Test.FixturePath.file("openai:gpt-4o", "streaming")
      ".../test/support/fixtures/openai/gpt_4o/streaming.json"
  """
  @spec file(LLMDB.Model.t() | String.t(), String.t()) :: String.t()
  def file(%LLMDB.Model{provider: provider, id: model}, test_name) when is_binary(test_name) do
    Path.join([@root, to_string(provider), slug(model), "#{test_name}.json"])
  end

  def file(model_spec, test_name) when is_binary(model_spec) and is_binary(test_name) do
    {:ok, model} = ReqLLM.model(model_spec)
    file(model, test_name)
  end

  @doc """
  Convert model name to filesystem-safe slug.

  ## Examples

      iex> ReqLLM.Test.FixturePath.slug("claude-3-5-haiku-20241022")
      "claude_3_5_haiku_20241022"

      iex> ReqLLM.Test.FixturePath.slug("GPT-4o")
      "gpt_4o"
  """
  @spec slug(String.t()) :: String.t()
  def slug(model_name) when is_binary(model_name) do
    model_name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "_")
    |> String.trim("_")
  end
end
