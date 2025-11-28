defmodule ReqLLM.Test.FakeRegistry do
  @moduledoc """
  Deterministic fake registry for testing ModelMatrix without global state.

  Provides a stable, predictable catalog of models that matches the default
  models used in coverage tests, ensuring tests are reproducible.

  Returns minimal LLMDB.Model structs to match LLMDB's API.
  """

  @catalog %{
    anthropic: ~w(claude-sonnet-4-5-20250929 claude-3-5-haiku-20241022),
    openai: ~w(gpt-4o gpt-4o-mini),
    google: ~w(gemini-2.0-flash-exp gemini-1.5-flash),
    groq: ~w(llama-3.3-70b-versatile gemma2-9b-it),
    xai: ~w(grok-2-latest grok-beta)
  }

  @spec list_providers() :: [atom()]
  def list_providers, do: Map.keys(@catalog)

  @spec list_models(atom()) :: {:ok, [LLMDB.Model.t()]} | {:error, :unknown_provider}
  def list_models(provider) do
    case Map.fetch(@catalog, provider) do
      {:ok, model_ids} ->
        models =
          Enum.map(model_ids, fn id ->
            %LLMDB.Model{
              id: id,
              provider: provider
            }
          end)

        {:ok, models}

      :error ->
        {:error, :unknown_provider}
    end
  end
end
