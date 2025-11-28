defmodule ReqLLM.Keys do
  @moduledoc """
  Handles API key lookup with the following precedence:

  1. `:api_key` option (per-request override)
  2. `Application.get_env(:req_llm, config_key)`
  3. `System.get_env(env_var)` (dotenvy loads .env at startup)

  Happy path: works with ReqLLM.Model structs and provider atoms.
  Uses each provider's `default_env_key/0` callback when available.

  ## Examples

      # From .env file (recommended)
      # ANTHROPIC_API_KEY=sk-ant-...
      ReqLLM.Keys.get(:anthropic, [])
      
      # From application config
      Application.put_env(:req_llm, :anthropic_api_key, "sk-ant-...")
      ReqLLM.Keys.get(:anthropic, [])
      
      # Per-request override
      ReqLLM.Keys.get(:anthropic, api_key: "sk-ant-...")

      # Works with models (extracts provider automatically)
      model = ReqLLM.model("anthropic:claude-3-sonnet")
      key = ReqLLM.Keys.get!(model)

      # Debug key source
      {:ok, key, source} = ReqLLM.Keys.get(model)
      Logger.debug("Using key from \#{source}")

  """

  @type key_source :: :option | :application | :system

  @doc """
  Retrieves API key for a provider/model, raising on failure.
  """
  @spec get!(LLMDB.Model.t() | atom, keyword) :: String.t() | no_return
  def get!(provider_or_model, opts \\ []) do
    case get(provider_or_model, opts) do
      {:ok, key, _source} -> key
      {:error, msg} -> raise ReqLLM.Error.Invalid.Parameter.exception(parameter: msg)
    end
  end

  @doc """
  Retrieves API key for a provider/model with source information.
  """
  @spec get(LLMDB.Model.t() | atom, keyword) ::
          {:ok, String.t(), key_source} | {:error, String.t()}
  def get(%LLMDB.Model{provider: provider}, opts), do: get(provider, opts)

  def get(provider, opts) when is_atom(provider) do
    env_var = env_var_name(provider)
    config_key = config_key(provider)

    with nil <- Keyword.get(opts, :api_key),
         nil <- Application.get_env(:req_llm, config_key),
         nil <- System.get_env(env_var) do
      {:error,
       ":api_key option, config :req_llm, #{config_key}, or #{env_var} env var (.env via dotenvy)"}
    else
      key when key in [nil, ""] ->
        {:error, "#{env_var} was found but is empty"}

      key when is_binary(key) ->
        source = detect_source(key, env_var, config_key, opts)
        {:ok, key, source}
    end
  end

  @doc """
  Returns the application config key for a provider.

  ## Examples

      iex> ReqLLM.Keys.config_key(:anthropic)
      :anthropic_api_key

  """
  @spec config_key(atom) :: atom
  def config_key(provider) when is_atom(provider), do: :"#{provider}_api_key"

  @doc """
  Returns the expected environment variable name for a provider.

  Uses the provider's default_env_key callback if available, otherwise
  uses the provider registry.

  ## Examples

      iex> ReqLLM.Keys.env_var_name(:anthropic)
      "ANTHROPIC_API_KEY"

  """
  @spec env_var_name(atom) :: String.t()
  def env_var_name(provider) when is_atom(provider) do
    # Try provider's default_env_key callback first
    case ReqLLM.provider(provider) do
      {:ok, module} ->
        if function_exported?(module, :default_env_key, 0) do
          module.default_env_key()
        else
          # Fall back to registry
          ReqLLM.Providers.get_env_key(provider) ||
            "#{provider |> Atom.to_string() |> String.upcase()}_API_KEY"
        end

      {:error, _} ->
        # Provider not found, use conventional name
        "#{provider |> Atom.to_string() |> String.upcase()}_API_KEY"
    end
  end

  # Backward compatibility - deprecated
  @deprecated "Use ReqLLM.Keys.get!/2 instead"
  defdelegate fetch!(provider_id, opts \\ []), to: __MODULE__, as: :get!

  @deprecated "Use ReqLLM.Keys.get/2 instead"
  defdelegate fetch(provider_id, opts \\ []), to: __MODULE__, as: :get

  # Private helpers

  defp detect_source(key, env_var, config_key, opts) do
    cond do
      Keyword.get(opts, :api_key) == key -> :option
      Application.get_env(:req_llm, config_key) == key -> :application
      System.get_env(env_var) == key -> :system
      true -> :system
    end
  end
end
