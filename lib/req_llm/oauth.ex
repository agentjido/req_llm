defmodule ReqLLM.OAuth do
  @moduledoc false

  @default_files ["oauth.json", "auth.json"]

  @type resolved_credential :: %{
          token: String.t(),
          account_id: String.t() | nil,
          source: :oauth_file | :oauth_refresh,
          oauth_file: String.t(),
          provider_key: String.t()
        }

  @spec resolve(LLMDB.Model.t() | atom, keyword() | map()) ::
          {:ok, resolved_credential()} | {:error, String.t()}
  def resolve(provider_or_model, opts \\ []) do
    provider_opts = get_option(opts, :provider_options) || []

    with {:ok, provider, provider_mod} <- fetch_provider(provider_or_model),
         {:ok, oauth_file} <- oauth_file_path(opts, provider_opts),
         {:ok, payload} <- read_oauth_file(oauth_file),
         {:ok, provider_key, credentials} <- fetch_credentials(payload, provider, provider_mod),
         {:ok, normalized} <- normalize_credentials(credentials, provider_key, oauth_file),
         {:ok, refreshed, source} <-
           maybe_refresh(
             normalized,
             provider_mod,
             provider_key,
             oauth_file,
             payload,
             opts,
             provider_opts
           ) do
      {:ok,
       %{
         token: refreshed.access,
         account_id: refreshed.account_id || derive_account_id(provider_mod, refreshed.access),
         source: source,
         oauth_file: oauth_file,
         provider_key: provider_key
       }}
    end
  end

  defp fetch_provider(%LLMDB.Model{provider: provider}) do
    with {:ok, provider_mod} <- ReqLLM.provider(provider) do
      {:ok, provider, provider_mod}
    end
  end

  defp fetch_provider(provider) when is_atom(provider) do
    with {:ok, provider_mod} <- ReqLLM.provider(provider) do
      {:ok, provider, provider_mod}
    end
  end

  defp fetch_provider(_provider_or_model) do
    {:error, "OAuth file authentication requires a provider atom or model struct"}
  end

  defp oauth_file_path(opts, provider_opts) do
    explicit_path =
      first_present_path([
        get_option(opts, :oauth_file),
        get_option(provider_opts, :oauth_file),
        get_option(opts, :auth_file),
        get_option(provider_opts, :auth_file),
        Application.get_env(:req_llm, :oauth_file),
        Application.get_env(:req_llm, :auth_file),
        System.get_env("REQ_LLM_OAUTH_FILE"),
        System.get_env("REQ_LLM_AUTH_FILE")
      ])

    if is_binary(explicit_path) do
      expanded_path = Path.expand(explicit_path)

      if File.exists?(expanded_path) do
        {:ok, expanded_path}
      else
        {:error, "OAuth file not found: #{expanded_path}"}
      end
    else
      case Enum.find_value(@default_files, fn path ->
             expanded_path = Path.expand(path)

             if File.exists?(expanded_path) do
               expanded_path
             end
           end) do
        nil ->
          {:error,
           "OAuth mode requires :access_token or an oauth file. Looked for oauth.json and auth.json"}

        path ->
          {:ok, path}
      end
    end
  end

  defp read_oauth_file(path) do
    with {:ok, body} <- File.read(path),
         {:ok, payload} <- Jason.decode(body) do
      {:ok, payload}
    else
      {:error, :enoent} ->
        {:error, "OAuth file not found: #{path}"}

      {:error, reason} when is_atom(reason) ->
        {:error, "Unable to read OAuth file #{path}: #{inspect(reason)}"}

      {:error, %Jason.DecodeError{} = error} ->
        {:error, "OAuth file #{path} is not valid JSON: #{Exception.message(error)}"}
    end
  end

  defp fetch_credentials(payload, provider, provider_mod) when is_map(payload) do
    candidate_keys =
      [
        provider_oauth_id(provider, provider_mod),
        Atom.to_string(provider)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case Enum.find_value(candidate_keys, fn key ->
           case Map.get(payload, key) do
             nil -> nil
             credentials -> {key, credentials}
           end
         end) do
      {provider_key, credentials} ->
        {:ok, provider_key, credentials}

      nil ->
        {:error,
         "OAuth file does not contain credentials for #{Enum.join(candidate_keys, " or ")}"}
    end
  end

  defp fetch_credentials(_payload, _provider, _provider_mod) do
    {:error, "OAuth file must contain a top-level JSON object"}
  end

  defp provider_oauth_id(provider, provider_mod) do
    if function_exported?(provider_mod, :oauth_provider_id, 0) do
      provider_mod.oauth_provider_id()
    else
      Atom.to_string(provider)
    end
  end

  defp derive_account_id(provider_mod, access_token) when is_binary(access_token) do
    if function_exported?(provider_mod, :account_id_from_token, 1) do
      provider_mod.account_id_from_token(access_token)
    end
  end

  defp derive_account_id(_provider_mod, _access_token), do: nil

  defp normalize_credentials(credentials, provider_key, oauth_file) when is_map(credentials) do
    access = fetch_field(credentials, ["access", "access_token"])
    refresh = fetch_field(credentials, ["refresh", "refresh_token"])
    expires = normalize_expiry(fetch_field(credentials, ["expires", "expires_at"]))
    account_id = fetch_field(credentials, ["accountId", "account_id"])
    type = fetch_field(credentials, ["type"]) || "oauth"

    if blank?(access) and blank?(refresh) do
      {:error,
       "OAuth credentials for #{provider_key} in #{oauth_file} do not include access or refresh tokens"}
    else
      {:ok,
       %{
         type: type,
         access: normalize_blank(access),
         refresh: normalize_blank(refresh),
         expires: expires,
         account_id: normalize_blank(account_id)
       }}
    end
  end

  defp normalize_credentials(_credentials, provider_key, oauth_file) do
    {:error, "OAuth credentials for #{provider_key} in #{oauth_file} must be a JSON object"}
  end

  defp maybe_refresh(
         credentials,
         provider_mod,
         provider_key,
         oauth_file,
         payload,
         opts,
         provider_opts
       ) do
    cond do
      needs_refresh?(credentials) and blank?(credentials.refresh) ->
        {:error,
         "OAuth credentials for #{provider_key} in #{oauth_file} are expired and do not include a refresh token"}

      needs_refresh?(credentials) and
          not function_exported?(provider_mod, :refresh_oauth_credentials, 2) ->
        {:error, "Provider #{provider_key} does not support OAuth token refresh in req_llm"}

      needs_refresh?(credentials) ->
        refresh_opts = oauth_refresh_opts(opts, provider_opts)

        with {:ok, refreshed} <-
               provider_mod.refresh_oauth_credentials(credentials, refresh_opts),
             {:ok, normalized} <- normalize_credentials(refreshed, provider_key, oauth_file),
             :ok <- persist_credentials(payload, oauth_file, provider_key, normalized) do
          {:ok, normalized, :oauth_refresh}
        end

      blank?(credentials.access) ->
        {:error,
         "OAuth credentials for #{provider_key} in #{oauth_file} do not include a non-empty access token"}

      true ->
        {:ok, credentials, :oauth_file}
    end
  end

  defp persist_credentials(payload, oauth_file, provider_key, credentials) do
    updated_payload =
      Map.put(payload, provider_key, %{
        "type" => credentials.type || "oauth",
        "access" => credentials.access,
        "refresh" => credentials.refresh,
        "expires" => credentials.expires,
        "accountId" => credentials.account_id
      })

    serialized =
      updated_payload
      |> drop_nil_values()
      |> Jason.encode_to_iodata!(pretty: true)

    case File.write(oauth_file, serialized) do
      :ok -> :ok
      {:error, reason} -> {:error, "Unable to write OAuth file #{oauth_file}: #{inspect(reason)}"}
    end
  end

  defp oauth_refresh_opts(opts, provider_opts) do
    []
    |> put_opt(:oauth_http_options, get_option(opts, :oauth_http_options))
    |> put_opt(:oauth_http_options, get_option(provider_opts, :oauth_http_options))
  end

  defp fetch_field(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn key ->
      Map.get(map, key) || Map.get(map, matching_atom_key(map, key))
    end)
  end

  defp fetch_field(_map, _keys), do: nil

  defp matching_atom_key(map, key) when is_map(map) and is_binary(key) do
    Enum.find(Map.keys(map), fn candidate ->
      is_atom(candidate) and Atom.to_string(candidate) == key
    end)
  end

  defp matching_atom_key(_map, _key), do: nil

  defp normalize_expiry(nil), do: nil

  defp normalize_expiry(value) when is_integer(value) and value > 0 and value < 10_000_000_000 do
    value * 1000
  end

  defp normalize_expiry(value) when is_integer(value) and value > 0, do: value

  defp normalize_expiry(value) when is_float(value) and value > 0 do
    value
    |> round()
    |> normalize_expiry()
  end

  defp normalize_expiry(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> normalize_expiry(integer)
      _ -> nil
    end
  end

  defp normalize_expiry(_value), do: nil

  defp needs_refresh?(credentials) do
    blank?(credentials.access) or
      (is_integer(credentials.expires) and System.system_time(:millisecond) >= credentials.expires)
  end

  defp drop_nil_values(map) when is_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new(fn {key, value} ->
      new_value = if is_map(value), do: drop_nil_values(value), else: value

      {key, new_value}
    end)
  end

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: Keyword.put_new(opts, key, value)

  defp first_present_path(paths) do
    Enum.find_value(paths, fn
      path when is_binary(path) and path != "" -> path
      _ -> nil
    end)
  end

  defp blank?(value), do: normalize_blank(value) == nil

  defp normalize_blank(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_blank(value), do: value

  defp get_option(opts, key) when is_list(opts), do: Keyword.get(opts, key)

  defp get_option(opts, key) when is_map(opts) do
    Map.get(opts, key) || Map.get(opts, Atom.to_string(key))
  end

  defp get_option(_opts, _key), do: nil
end
