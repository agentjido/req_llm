defmodule ReqLLM.Utils do
  @moduledoc false
  # Internal utility functions shared between ReqLLM modules

  # ---------------------------------------------------------------------------
  # Request processing utilities
  # ---------------------------------------------------------------------------

  @doc """
  Merges req_options into a Req.Request.
  """
  def merge_req_options(request, opts) do
    case Keyword.get(opts, :req_options, []) do
      [] -> request
      nil -> request
      opts when is_map(opts) -> Req.Request.merge_options(request, Map.to_list(opts))
      opts when is_list(opts) -> Req.Request.merge_options(request, opts)
    end
  end

  @doc """
  Attaches fixture step to request if fixture option is present.
  """
  def attach_fixture(request, model, opts) do
    case normalize_fixture_tuple(model, opts[:fixture]) do
      {:ok, {provider, name}} ->
        attach_fixture_step(request, provider, name)

      :error ->
        request
    end
  end

  defp normalize_fixture_tuple(_, nil), do: :error

  defp normalize_fixture_tuple(_, {provider, name}) when is_atom(provider) and is_binary(name) do
    {:ok, {provider, name}}
  end

  defp normalize_fixture_tuple(model, name) when is_binary(name) do
    {:ok, {model.provider, name}}
  end

  defp normalize_fixture_tuple(_, _), do: :error

  @compile {:nowarn_unused_function, attach_fixture_step: 3}
  defp attach_fixture_step(request, provider, name) do
    case Code.ensure_loaded(LLMFixture) do
      {:module, LLMFixture} ->
        # LLMFixture.step/2 only exists in test environment
        step_fn = apply(LLMFixture, :step, [provider, name])
        Req.Request.append_request_steps(request, llm_fixture: step_fn)

      {:error, _} ->
        # No-op if LLMFixture not available
        request
    end
  end

  # ---------------------------------------------------------------------------
  # Schema composition utilities  
  # ---------------------------------------------------------------------------

  @doc """
  Builds a dynamic schema by composing a base schema with provider-specific options.

  This function takes a base schema and provider module, creating a unified schema where 
  provider-specific options are nested under the :provider_options key with proper validation.
  """
  def compose_schema(base_schema, provider_mod) do
    if function_exported?(provider_mod, :provider_schema, 0) do
      provider_keys = provider_mod.provider_schema().schema

      # Update the :provider_options key with provider-specific nested schema
      updated_schema =
        Keyword.update!(base_schema.schema, :provider_options, fn opt ->
          Keyword.merge(opt,
            type: :keyword_list,
            keys: provider_keys,
            default: []
          )
        end)

      NimbleOptions.new!(updated_schema)
    else
      base_schema
    end
  end
end
