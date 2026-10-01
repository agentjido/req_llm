defmodule ReqLLM.Auth do
  @moduledoc false

  # Resolves authentication credentials for provider requests.

  # Supports three credential modes:

  # - API key (`:api_key`) via `ReqLLM.Keys`
  # - OAuth access token (`:oauth_access_token`) via `:access_token`
  # - Anonymous access (`:none`) without credential lookup

  # Access token lookup precedence:

  # 1. Top-level `:access_token` option
  # 2. `:provider_options[:access_token]`

  # If `:auth_mode` is set to `:oauth`, an `:access_token` is required.
  # If it is set to `:none`, credential sources are not read.

  @type credential_kind :: :api_key | :oauth_access_token

  @type credential :: %{
          kind: credential_kind(),
          token: String.t(),
          source: atom(),
          account_id: String.t() | nil
        }

  @spec resolve!(LLMDB.Model.t() | atom, keyword() | map()) :: credential() | :none | no_return()
  def resolve!(provider_or_model, opts \\ []) do
    case resolve(provider_or_model, opts) do
      {:ok, credential} -> credential
      {:error, msg} -> raise ReqLLM.Error.Invalid.Parameter.exception(parameter: msg)
    end
  end

  @spec resolve(LLMDB.Model.t() | atom, keyword() | map()) ::
          {:ok, credential() | :none} | {:error, String.t()}
  def resolve(provider_or_model, opts \\ []) do
    provider_opts = get_option(opts, :provider_options) || []

    case auth_mode(opts, provider_opts) do
      :none ->
        resolve_anonymous(provider_or_model, opts)

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

  @doc false
  @spec validate_request!(Req.Request.t(), credential() | :none) :: Req.Request.t()
  def validate_request!(%Req.Request{} = request, :none) do
    if request.options[:auth] != nil or Req.Request.get_header(request, "authorization") != [] do
      raise ReqLLM.Error.Invalid.Parameter,
        parameter: "Anonymous authentication cannot use a preconfigured authenticated request"
    end

    request
  end

  def validate_request!(%Req.Request{} = request, _credential), do: request

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

  defp resolve_anonymous(%LLMDB.Model{provider: provider}, opts),
    do: resolve_anonymous(provider, opts)

  defp resolve_anonymous(:openai, opts) do
    http_opts = get_option(opts, :req_http_options) || []

    if authenticated_http_options?(opts) or authenticated_http_options?(http_opts) do
      {:error,
       "Anonymous authentication cannot include HTTP authentication options or Authorization headers"}
    else
      {:ok, :none}
    end
  end

  defp resolve_anonymous(_provider, _opts),
    do: {:error, "Anonymous authentication is supported only by the OpenAI provider"}

  defp authenticated_http_options?(opts) do
    get_option(opts, :auth) != nil or authorization_headers?(get_option(opts, :headers))
  end

  defp authorization_headers?(nil), do: false

  defp authorization_headers?(headers) when is_list(headers) or is_map(headers) do
    Enum.any?(headers, fn
      {name, _value} when is_binary(name) or is_atom(name) ->
        String.downcase(to_string(name)) == "authorization"

      _ ->
        true
    end)
  end

  defp authorization_headers?(_), do: true

  defp auth_mode(opts, provider_opts) do
    mode = get_option(opts, :auth_mode) || get_option(provider_opts, :auth_mode) || :api_key

    case mode do
      mode when mode in [:none, "none"] -> :none
      mode when mode in [:oauth, "oauth"] -> :oauth
      _mode -> :api_key
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
