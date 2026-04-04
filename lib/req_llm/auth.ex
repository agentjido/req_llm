defmodule ReqLLM.Auth do
  @moduledoc false

  # Resolves authentication credentials for provider requests.

  # Supports two credential modes:

  # - API key (`:api_key`) via `ReqLLM.Keys`
  # - OAuth access token (`:oauth_access_token`) via `:access_token`

  # Access token lookup precedence:

  # 1. Top-level `:access_token` option
  # 2. `:provider_options[:access_token]`

  # If `:auth_mode` is set to `:oauth`, an `:access_token` is required.

  @type credential_kind :: :api_key | :oauth_access_token

  @type credential :: %{
          kind: credential_kind(),
          token: String.t(),
          source: atom(),
          account_id: String.t() | nil
        }

  @spec resolve!(LLMDB.Model.t() | atom, keyword() | map()) :: credential() | no_return()
  def resolve!(provider_or_model, opts \\ []) do
    case resolve(provider_or_model, opts) do
      {:ok, credential} -> credential
      {:error, msg} -> raise ReqLLM.Error.Invalid.Parameter.exception(parameter: msg)
    end
  end

  @spec resolve(LLMDB.Model.t() | atom, keyword() | map()) ::
          {:ok, credential()} | {:error, String.t()}
  def resolve(provider_or_model, opts \\ []) do
    provider_opts = get_option(opts, :provider_options) || []

    case auth_mode(opts, provider_opts) do
      :oauth ->
        case fetch_access_token(opts, provider_opts) do
          {:ok, token, source} ->
            {:ok,
             %{
               kind: :oauth_access_token,
               token: token,
               source: source,
               account_id: resolve_account_id(provider_or_model, token, opts, provider_opts)
             }}

          :none ->
            case ReqLLM.OAuth.resolve(provider_or_model, opts) do
              {:ok, credential} ->
                {:ok,
                 %{
                   kind: :oauth_access_token,
                   token: credential.token,
                   source: credential.source,
                   account_id: credential.account_id
                 }}

              {:error, msg} ->
                {:error, msg}
            end

          {:error, msg} ->
            {:error, msg}
        end

      :api_key ->
        key_opts =
          case get_option(opts, :api_key) do
            nil -> []
            api_key -> [api_key: api_key]
          end

        case ReqLLM.Keys.get(provider_or_model, key_opts) do
          {:ok, key, source} ->
            {:ok, %{kind: :api_key, token: key, source: source, account_id: nil}}

          {:error, msg} ->
            {:error, msg}
        end
    end
  end

  defp fetch_access_token(opts, provider_opts) do
    cond do
      is_binary(get_option(opts, :access_token)) ->
        token = get_option(opts, :access_token)

        if token == "" do
          {:error, ":access_token was provided but is empty"}
        else
          {:ok, token, :option}
        end

      is_binary(get_option(provider_opts, :access_token)) ->
        token = get_option(provider_opts, :access_token)

        if token == "" do
          {:error, ":provider_options[:access_token] was provided but is empty"}
        else
          {:ok, token, :provider_options}
        end

      true ->
        :none
    end
  end

  defp auth_mode(opts, provider_opts) do
    mode = get_option(opts, :auth_mode) || get_option(provider_opts, :auth_mode) || :api_key

    case mode do
      :oauth -> :oauth
      "oauth" -> :oauth
      _ -> :api_key
    end
  end

  defp resolve_account_id(provider_or_model, token, opts, provider_opts) do
    get_option(opts, :chatgpt_account_id) ||
      get_option(provider_opts, :chatgpt_account_id) ||
      derive_account_id(provider_or_model, token)
  end

  defp derive_account_id(provider_or_model, token) do
    with {:ok, provider_mod} <- fetch_provider_module(provider_or_model),
         true <- function_exported?(provider_mod, :account_id_from_token, 1) do
      provider_mod.account_id_from_token(token)
    else
      _ -> nil
    end
  end

  defp fetch_provider_module(%LLMDB.Model{provider: provider}), do: ReqLLM.provider(provider)
  defp fetch_provider_module(provider) when is_atom(provider), do: ReqLLM.provider(provider)
  defp fetch_provider_module(_provider_or_model), do: {:error, :invalid_provider}

  defp get_option(opts, key) when is_list(opts), do: Keyword.get(opts, key)

  defp get_option(opts, key) when is_map(opts) do
    Map.get(opts, key) || Map.get(opts, Atom.to_string(key))
  end

  defp get_option(_opts, _key), do: nil
end
