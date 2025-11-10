# lib/req_llm/ontology/context.ex
# Purpose: Load and cache the JSON-LD @context so emitters can serialize deterministically.

defmodule ReqLLM.Ontology.Context do
  @moduledoc """
  Minimal loader for the ontology JSON-LD @context used by ggen emitters/parsers.
  Looks under `ontologies/reqllm.context.jsonld` relative to the project root by default.
  """

  @default_path "ontologies/reqllm.context.jsonld"
  @pt_key {__MODULE__, :context}

  @doc """
  Returns the decoded JSON-LD context map. Cached in persistent_term.
  """
  @spec context() :: map()
  def context do
    case :persistent_term.get(@pt_key, :undefined) do
      :undefined ->
        ctx = load_from_env() || load_from_disk!()
        :persistent_term.put(@pt_key, ctx)
        ctx

      cached ->
        cached
    end
  end

  # Purpose: Allow override via env for non-standard layouts or releases.
  defp load_from_env do
    case System.get_env("REQLLM_JSONLD_CONTEXT") do
      nil -> nil
      path -> decode!(File.read!(path))
    end
  end

  # Purpose: Load JSON-LD context from repo; raise clearly on errors to fail fast in CI.
  defp load_from_disk! do
    path = Path.expand(@default_path, File.cwd!())

    unless File.exists?(path) do
      raise """
      JSON-LD context not found at #{path}.
      Ensure ontologies/reqllm.context.jsonld is present (ggen input).
      """
    end

    decode!(File.read!(path))
  end

  defp decode!(json) do
    case Jason.decode(json) do
      {:ok, %{"@context" => ctx} = _full} when is_map(ctx) ->
        ctx
      {:ok, %{"@context" => ctx}} ->
        ctx
      {:ok, ctx} when is_map(ctx) ->
        ctx
      other ->
        raise "Invalid JSON-LD context: #{inspect(other)}"
    end
  end
end
