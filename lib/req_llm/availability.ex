defmodule ReqLLM.Availability do
  @moduledoc false

  @query_opts [:scope, :prefer, :require, :forbid]

  @azure_api_key_env_vars [
    "AZURE_API_KEY",
    "AZURE_OPENAI_API_KEY",
    "AZURE_ANTHROPIC_API_KEY",
    "AZURE_DEEPSEEK_API_KEY",
    "AZURE_MAI_API_KEY"
  ]

  @azure_base_url_env_vars [
    "AZURE_BASE_URL",
    "AZURE_OPENAI_BASE_URL",
    "AZURE_ANTHROPIC_BASE_URL",
    "AZURE_DEEPSEEK_BASE_URL",
    "AZURE_MAI_BASE_URL"
  ]

  @spec available_models(keyword()) :: [String.t()]
  def available_models(opts \\ []) do
    configured_providers = configured_providers(opts) |> MapSet.new()

    opts
    |> Keyword.take(@query_opts)
    |> LLMDB.Query.candidates()
    |> Enum.filter(fn {provider, _model_id} -> MapSet.member?(configured_providers, provider) end)
    |> Enum.map(&LLMDB.format/1)
  end

  defp configured_providers(opts) do
    opts
    |> providers_to_check()
    |> Enum.filter(&configured_provider?(&1, opts))
  end

  defp providers_to_check(opts) do
    case Keyword.get(opts, :scope, :all) do
      :all -> ReqLLM.Providers.list()
      provider when is_atom(provider) -> [provider]
      _ -> []
    end
  end

  defp configured_provider?(:amazon_bedrock, opts), do: amazon_bedrock_configured?(opts)
  defp configured_provider?(:azure, opts), do: azure_configured?(opts)
  defp configured_provider?(:google_vertex, opts), do: google_vertex_configured?(opts)
  defp configured_provider?(provider, opts), do: auth_resolvable?(provider, opts)

  defp auth_resolvable?(provider, opts) do
    provider
    |> put_default_auth_mode(opts)
    |> then(&match?({:ok, _credential}, ReqLLM.Auth.resolve(provider, &1)))
  end

  defp put_default_auth_mode(provider, opts) do
    with {:ok, provider_module} <- ReqLLM.provider(provider),
         true <- function_exported?(provider_module, :provider_schema, 0),
         schema when is_list(schema) <- provider_module.provider_schema().schema,
         auth_mode_schema when is_list(auth_mode_schema) <- Keyword.get(schema, :auth_mode),
         auth_mode when not is_nil(auth_mode) <- Keyword.get(auth_mode_schema, :default),
         false <- provider_option_present?(opts, :auth_mode) do
      put_provider_option(opts, :auth_mode, auth_mode)
    else
      _ -> opts
    end
  end

  defp amazon_bedrock_configured?(opts) do
    api_key =
      option_value(opts, :api_key) ||
        System.get_env("AWS_BEARER_TOKEN_BEDROCK")

    access_key_id =
      option_value(opts, :access_key_id) ||
        System.get_env("AWS_ACCESS_KEY_ID")

    secret_access_key =
      option_value(opts, :secret_access_key) ||
        System.get_env("AWS_SECRET_ACCESS_KEY")

    present?(api_key) or (present?(access_key_id) and present?(secret_access_key))
  end

  defp azure_configured?(opts) do
    api_key =
      option_value(opts, :api_key) ||
        Application.get_env(:req_llm, :azure_api_key) ||
        first_present_env(@azure_api_key_env_vars)

    base_url =
      option_value(opts, :base_url) ||
        Application.get_env(:req_llm, :azure, []) |> Keyword.get(:base_url) ||
        first_present_env(@azure_base_url_env_vars)

    present?(api_key) and present?(base_url)
  end

  defp google_vertex_configured?(opts) do
    service_account_json =
      option_value(opts, :service_account_json) ||
        System.get_env("GOOGLE_APPLICATION_CREDENTIALS")

    access_token = option_value(opts, :access_token)
    project_id = option_value(opts, :project_id) || System.get_env("GOOGLE_CLOUD_PROJECT")

    present?(project_id) and (present?(service_account_json) or present?(access_token))
  end

  defp first_present_env(vars) do
    Enum.find_value(vars, &present_env/1)
  end

  defp present_env(var) do
    case System.get_env(var) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp option_value(opts, key) do
    Keyword.get(opts, key) || provider_option_value(opts, key)
  end

  defp provider_option_value(opts, key) do
    case Keyword.get(opts, :provider_options, []) do
      provider_opts when is_list(provider_opts) ->
        Keyword.get(provider_opts, key)

      provider_opts when is_map(provider_opts) ->
        Map.get(provider_opts, key) || Map.get(provider_opts, Atom.to_string(key))

      _ ->
        nil
    end
  end

  defp provider_option_present?(opts, key) do
    case Keyword.get(opts, :provider_options, []) do
      provider_opts when is_list(provider_opts) ->
        Keyword.has_key?(provider_opts, key)

      provider_opts when is_map(provider_opts) ->
        Map.has_key?(provider_opts, key) || Map.has_key?(provider_opts, Atom.to_string(key))

      _ ->
        false
    end
  end

  defp put_provider_option(opts, key, value) do
    provider_opts =
      case Keyword.get(opts, :provider_options, []) do
        existing when is_list(existing) -> Keyword.put_new(existing, key, value)
        existing when is_map(existing) -> Map.put_new(existing, key, value)
        _ -> [{key, value}]
      end

    Keyword.put(opts, :provider_options, provider_opts)
  end

  defp present?(value) when is_binary(value), do: value != ""
  defp present?(value), do: not is_nil(value)
end
