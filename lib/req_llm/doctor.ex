defmodule ReqLLM.Doctor do
  @moduledoc """
  Read-only installation and runtime diagnostics for ReqLLM.

  `run/1` never performs provider requests. By default it also never starts applications
  or changes runtime configuration. Callers may explicitly opt into normal ReqLLM startup
  with `start_application?: true`, which is useful for short-lived command processes. Its
  result is JSON-serializable and contains no credential values, request payloads, or
  provider response data.

  The result uses schema version `1` and has three top-level fields:

    * `"schema_version"` - the integer result schema version
    * `"status"` - `"ok"`, `"warning"`, or `"error"`
    * `"checks"` - ordered diagnostic checks with stable common fields

  Warning-only results are successful. An error result should produce a non-zero exit
  status when used from a command-line tool.
  """

  @schema_version 1
  @status_order %{"ok" => 0, "warning" => 1, "error" => 2}
  @operations [:chat, :object]
  @version_apps [:req_llm, :llm_db, :req, :finch]
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
  @oauth_default_files ["oauth.json", "auth.json"]

  @type status :: String.t()
  @type check :: %{
          required(String.t()) => String.t() | map() | nil
        }
  @type result :: %{
          required(String.t()) => pos_integer() | status() | [check()]
        }

  @doc """
  Runs safe ReqLLM diagnostics.

  ## Options

    * `:model` - optional model input to resolve and inspect
    * `:provider` - optional provider atom or provider-name string to require
    * `:operation` - `:chat` or `:object`; defaults to `:chat` when a model is supplied
    * `:start_application?` - explicitly allow ReqLLM startup; defaults to `false`

  When ReqLLM is not already running, the default returns warnings for runtime-only
  checks instead of starting applications or changing runtime configuration.
  """
  @spec run(keyword()) :: result()
  def run(opts \\ [])

  def run(opts) when is_list(opts) do
    case validate_options(opts) do
      :ok ->
        run_checks(opts)

      {:error, message} ->
        result([check("input", "configuration", "error", message, input_remediation())])
    end
  end

  def run(_opts) do
    result([
      check(
        "input",
        "configuration",
        "error",
        "Doctor options must be a keyword list.",
        input_remediation()
      )
    ])
  end

  @doc """
  Returns `0` for ok and warning results and `1` for error results.
  """
  @spec exit_status(result()) :: 0 | 1
  def exit_status(%{"status" => "error"}), do: 1
  def exit_status(_result), do: 0

  @doc false
  @spec format_human(result()) :: String.t()
  def format_human(%{"status" => status, "checks" => checks}) do
    lines =
      Enum.map(checks, fn check ->
        line =
          "#{status_icon(check["status"])} #{check["id"]}: #{check["message"]}"

        case check["remediation"] do
          nil -> line
          remediation -> line <> "\n  Remedy: " <> remediation
        end
      end)

    counts = Enum.frequencies_by(checks, & &1["status"])

    summary =
      "#{Map.get(counts, "error", 0)} errors, #{Map.get(counts, "warning", 0)} warnings"

    Enum.join(["ReqLLM doctor: #{String.upcase(status)}" | lines] ++ [summary], "\n")
  end

  defp run_checks(opts) do
    {application_check, application_state} = application_check(opts)
    {model_check, model} = model_check(opts, application_state)
    {provider_check, provider} = provider_check(opts, model, application_state)

    checks =
      [versions_check(), application_check] ++
        optional_check(model_check) ++
        [provider_check] ++
        credential_checks(provider, application_state) ++
        surface_checks(model, opts, application_state) ++
        [finch_configuration_check(), finch_runtime_check(application_state)]

    result(checks)
  end

  defp validate_options(opts) do
    allowed = [:model, :provider, :operation, :start_application?]

    if Keyword.keyword?(opts) do
      unknown = Keyword.keys(opts) -- allowed
      operation = Keyword.get(opts, :operation, :chat)

      cond do
        unknown != [] ->
          {:error, "Unknown doctor options were provided."}

        operation not in @operations ->
          {:error, "Operation must be :chat or :object."}

        not is_boolean(Keyword.get(opts, :start_application?, false)) ->
          {:error, ":start_application? must be a boolean."}

        Keyword.has_key?(opts, :operation) and not Keyword.has_key?(opts, :model) ->
          {:error, "Operation inspection requires a model."}

        true ->
          :ok
      end
    else
      {:error, "Doctor options must be a keyword list."}
    end
  end

  defp versions_check do
    versions =
      Map.new(@version_apps, fn app ->
        {Atom.to_string(app), application_version(app)}
      end)
      |> Map.merge(%{
        "elixir" => System.version(),
        "otp" => System.otp_release()
      })

    check(
      "runtime.versions",
      "runtime",
      "ok",
      "Runtime and dependency versions are available.",
      nil,
      versions
    )
  end

  defp application_check(opts) do
    cond do
      application_running?() ->
        {application_running_check(), :running}

      Keyword.get(opts, :start_application?, false) ->
        start_application_check()

      true ->
        {check(
           "runtime.application",
           "runtime",
           "warning",
           "ReqLLM is not running; runtime-only checks were not performed.",
           "Start :req_llm or pass start_application?: true to explicitly allow startup."
         ), :not_running}
    end
  end

  defp start_application_check do
    case safe_start_application() do
      {:ok, _applications} ->
        {application_running_check(), :running}

      {:error, _reason} ->
        {check(
           "runtime.application",
           "runtime",
           "error",
           "ReqLLM could not start.",
           "Review application configuration and startup logs, then rerun mix req_llm.doctor."
         ), :startup_error}
    end
  end

  defp application_running_check do
    check(
      "runtime.application",
      "runtime",
      "ok",
      "ReqLLM and its supervision tree are running."
    )
  end

  defp application_running? do
    Enum.any?(Application.started_applications(), fn {app, _description, _version} ->
      app == :req_llm
    end)
  end

  defp safe_start_application do
    Application.ensure_all_started(:req_llm)
  rescue
    _error -> {:error, :startup_exception}
  catch
    _kind, _reason -> {:error, :startup_failure}
  end

  defp model_check(opts, :running) do
    case Keyword.fetch(opts, :model) do
      :error ->
        {nil, nil}

      {:ok, model_input} ->
        case ReqLLM.model(model_input) do
          {:ok, %LLMDB.Model{} = model} ->
            {check(
               "model.resolution",
               "model",
               "ok",
               "Model resolved to #{model.provider}:#{model.id}.",
               nil,
               %{"id" => model.id, "provider" => Atom.to_string(model.provider)}
             ), model}

          {:error, _reason} ->
            {check(
               "model.resolution",
               "model",
               "error",
               "The requested model could not be resolved.",
               "Use a catalog provider:model value or a complete inline model specification."
             ), nil}
        end
    end
  end

  defp model_check(opts, _application_state) do
    if Keyword.has_key?(opts, :model) do
      {check(
         "model.resolution",
         "model",
         "warning",
         "Model resolution was not inspected because ReqLLM is not running.",
         "Start :req_llm or explicitly allow diagnostic startup."
       ), nil}
    else
      {nil, nil}
    end
  end

  defp provider_check(_opts, _model, :not_running) do
    {check(
       "providers.registry",
       "provider",
       "warning",
       "Provider registration was not inspected because ReqLLM is not running.",
       "Start :req_llm or explicitly allow diagnostic startup."
     ), nil}
  end

  defp provider_check(_opts, _model, :startup_error) do
    {check(
       "providers.registry",
       "provider",
       "error",
       "Provider registration could not be inspected because ReqLLM failed to start.",
       "Resolve the application startup error first."
     ), nil}
  end

  defp provider_check(opts, model, :running) do
    providers = ReqLLM.Providers.list()
    requested = requested_provider(opts, model, providers)

    cond do
      match?({:error, _name}, requested) ->
        {check(
           "providers.registry",
           "provider",
           "error",
           "The requested provider is not registered.",
           "Choose one of the registered providers reported by mix req_llm.doctor."
         ), nil}

      match?({:mismatch, _, _}, requested) ->
        {check(
           "providers.registry",
           "provider",
           "error",
           "The requested provider does not match the resolved model provider.",
           "Remove --provider or select the provider named by the model specification."
         ), nil}

      providers == [] ->
        {check(
           "providers.registry",
           "provider",
           "error",
           "No provider implementations are registered.",
           "Restart ReqLLM and verify custom provider registration configuration."
         ), nil}

      true ->
        provider = requested_provider_value(requested)

        details = %{
          "count" => length(providers),
          "providers" => Enum.map(providers, &Atom.to_string/1),
          "selected" => optional_atom_string(provider)
        }

        message =
          if provider do
            "Provider #{provider} is registered."
          else
            "#{length(providers)} provider implementations are registered."
          end

        {check("providers.registry", "provider", "ok", message, nil, details), provider}
    end
  end

  defp requested_provider(opts, model, providers) do
    option_provider = provider_option(Keyword.get(opts, :provider), providers)
    model_provider = if model, do: model.provider

    case {option_provider, model_provider} do
      {{:error, name}, _model_provider} -> {:error, name}
      {{:ok, provider}, nil} -> {:ok, provider}
      {{:ok, provider}, provider} -> {:ok, provider}
      {{:ok, provider}, model_provider} -> {:mismatch, provider, model_provider}
      {nil, nil} -> nil
      {nil, model_provider} -> {:ok, model_provider}
    end
  end

  defp provider_option(nil, _providers), do: nil

  defp provider_option(provider, providers) when is_atom(provider),
    do: provider_match(provider, providers)

  defp provider_option(provider, providers) when is_binary(provider) do
    case Enum.find(providers, &(Atom.to_string(&1) == provider)) do
      nil -> {:error, provider}
      matched -> {:ok, matched}
    end
  end

  defp provider_option(_provider, _providers), do: {:error, :invalid}

  defp provider_match(provider, providers) do
    if provider in providers, do: {:ok, provider}, else: {:error, provider}
  end

  defp requested_provider_value({:ok, provider}), do: provider
  defp requested_provider_value(_requested), do: nil

  defp credential_checks(_provider, application_state) when application_state != :running, do: []

  defp credential_checks(nil, :running) do
    configured = configured_credential_providers()

    if configured == [] do
      [
        check(
          "credentials.configuration",
          "credentials",
          "warning",
          "No optional provider credentials were detected; credential-free providers may still be usable.",
          "Configure a provider credential when you are ready to make provider requests.",
          %{"configured_providers" => [], "credential_free_providers" => ["ollama"]}
        )
      ]
    else
      [
        check(
          "credentials.configuration",
          "credentials",
          "ok",
          "Configuration is present for #{length(configured)} providers.",
          nil,
          %{"configured_providers" => Enum.map(configured, &Atom.to_string/1)}
        )
      ]
    end
  end

  defp credential_checks(provider, :running) do
    case credential_requirement(provider) do
      :none ->
        [
          check(
            "credentials.selected_provider",
            "credentials",
            "ok",
            "Provider #{provider} does not require credentials.",
            nil,
            %{"provider" => Atom.to_string(provider), "required" => false}
          )
        ]

      :unknown ->
        [
          check(
            "credentials.selected_provider",
            "credentials",
            "warning",
            "Provider #{provider} does not declare a credential source ReqLLM can inspect.",
            "Verify the custom provider's credential configuration before making a request.",
            %{"provider" => Atom.to_string(provider), "required" => nil}
          )
        ]

      :required ->
        required_credential_check(provider)
    end
  end

  defp required_credential_check(provider) do
    if configured_provider?(provider) do
      [
        check(
          "credentials.selected_provider",
          "credentials",
          "ok",
          "Credential configuration for provider #{provider} is present.",
          nil,
          %{"provider" => Atom.to_string(provider), "required" => true}
        )
      ]
    else
      [
        check(
          "credentials.selected_provider",
          "credentials",
          "error",
          "Required configuration for provider #{provider} was not detected.",
          credential_remediation(provider),
          %{"provider" => Atom.to_string(provider), "required" => true}
        )
      ]
    end
  end

  defp configured_credential_providers do
    ReqLLM.Providers.list()
    |> Enum.reject(&(&1 == :ollama))
    |> Enum.filter(&configured_provider?/1)
  end

  defp configured_provider?(:amazon_bedrock) do
    present?(System.get_env("AWS_BEARER_TOKEN_BEDROCK")) or
      (present?(System.get_env("AWS_ACCESS_KEY_ID")) and
         present?(System.get_env("AWS_SECRET_ACCESS_KEY")))
  end

  defp configured_provider?(:azure) do
    azure_config = Application.get_env(:req_llm, :azure, [])

    key_present? =
      present?(Application.get_env(:req_llm, :azure_api_key)) or
        any_env_present?(@azure_api_key_env_vars)

    base_url_present? =
      present?(config_value(azure_config, :base_url)) or
        any_env_present?(@azure_base_url_env_vars)

    key_present? and base_url_present?
  end

  defp configured_provider?(:github_copilot) do
    present?(Application.get_env(:req_llm, :github_copilot_api_key)) or
      any_env_present?(["COPILOT_GITHUB_TOKEN", "GH_TOKEN", "GITHUB_TOKEN"])
  end

  defp configured_provider?(:google_vertex) do
    config = Application.get_env(:req_llm, :google_vertex, [])

    project_present? =
      present?(config_value(config, :project_id)) or
        present?(System.get_env("GOOGLE_CLOUD_PROJECT"))

    credential_present? =
      present?(config_value(config, :service_account_json)) or
        present?(config_value(config, :access_token)) or
        ReqLLM.Providers.GoogleVertex.Auth.adc_credentials_present?()

    project_present? and credential_present?
  end

  defp configured_provider?(:ollama), do: true

  defp configured_provider?(:openai_codex), do: oauth_credential_present?(:openai_codex)

  defp configured_provider?(provider) do
    api_key_present?(provider) or
      (default_oauth_mode?(provider) and oauth_credential_present?(provider))
  rescue
    _error -> false
  end

  defp api_key_present?(provider) do
    env_var = ReqLLM.Keys.env_var_name(provider)
    config_key = ReqLLM.Keys.config_key(provider)

    present?(System.get_env(env_var)) or present?(Application.get_env(:req_llm, config_key))
  end

  defp oauth_credential_present?(provider) do
    if oauth_supported?(provider) do
      with path when is_binary(path) <- oauth_file_path(),
           {:ok, body} <- File.read(path),
           {:ok, payload} when is_map(payload) <- Jason.decode(body) do
        oauth_provider_keys(provider)
        |> Enum.any?(fn key -> credential_record_present?(Map.get(payload, key)) end)
      else
        _missing_or_invalid -> false
      end
    else
      false
    end
  end

  defp oauth_supported?(provider) do
    case ReqLLM.provider(provider) do
      {:ok, module} ->
        function_exported?(module, :oauth_provider_id, 0) or auth_mode_declared?(module)

      {:error, _reason} ->
        false
    end
  end

  defp auth_mode_declared?(module) do
    function_exported?(module, :provider_schema, 0) and
      Keyword.has_key?(module.provider_schema().schema, :auth_mode)
  rescue
    _error -> false
  end

  defp default_oauth_mode?(provider) do
    with {:ok, module} <- ReqLLM.provider(provider),
         true <- function_exported?(module, :provider_schema, 0),
         schema when is_list(schema) <- module.provider_schema().schema,
         auth_mode when is_list(auth_mode) <- Keyword.get(schema, :auth_mode) do
      Keyword.get(auth_mode, :default) == :oauth
    else
      _not_default_oauth -> false
    end
  rescue
    _error -> false
  end

  defp oauth_provider_keys(provider) do
    {:ok, module} = ReqLLM.provider(provider)

    [
      if(function_exported?(module, :oauth_provider_id, 0), do: module.oauth_provider_id()),
      Atom.to_string(provider)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp credential_record_present?(credentials) when is_map(credentials) do
    ["access", "access_token", "refresh", "refresh_token"]
    |> Enum.any?(fn key -> present?(Map.get(credentials, key)) end)
  end

  defp credential_record_present?(_credentials), do: false

  defp oauth_file_path do
    configured =
      [
        Application.get_env(:req_llm, :oauth_file),
        Application.get_env(:req_llm, :auth_file),
        System.get_env("REQ_LLM_OAUTH_FILE"),
        System.get_env("REQ_LLM_AUTH_FILE")
      ]
      |> Enum.find(&present?/1)

    if configured do
      Path.expand(configured)
    else
      Enum.find_value(@oauth_default_files, fn path ->
        expanded = Path.expand(path)
        if File.exists?(expanded), do: expanded
      end)
    end
  end

  defp credential_requirement(:ollama), do: :none
  defp credential_requirement(:openai_codex), do: :required

  defp credential_requirement(provider) do
    case ReqLLM.provider(provider) do
      {:ok, module} ->
        if function_exported?(module, :default_env_key, 0) or oauth_supported?(provider),
          do: :required,
          else: :unknown

      {:error, _reason} ->
        :unknown
    end
  end

  defp credential_remediation(:openai_codex) do
    "Configure an openai-codex entry in oauth.json, auth.json, or REQ_LLM_OAUTH_FILE."
  end

  defp credential_remediation(provider) do
    env_var = ReqLLM.Keys.env_var_name(provider)
    config_key = ReqLLM.Keys.config_key(provider)

    "Configure #{env_var} or config :req_llm, :#{config_key}; provider-specific auth may require additional settings."
  end

  defp any_env_present?(names), do: Enum.any?(names, &present?(System.get_env(&1)))

  defp config_value(config, key) when is_list(config), do: Keyword.get(config, key)

  defp config_value(config, key) when is_map(config) do
    Map.get(config, key) || Map.get(config, Atom.to_string(key))
  end

  defp config_value(_config, _key), do: nil

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value) when is_map(value), do: map_size(value) > 0
  defp present?(_value), do: false

  defp surface_checks(nil, _opts, _application_state), do: []
  defp surface_checks(_model, _opts, application_state) when application_state != :running, do: []

  defp surface_checks(%LLMDB.Model{provider: provider} = model, opts, :running)
       when provider in [:openai, :anthropic] do
    operation = Keyword.get(opts, :operation, :chat)

    case ReqLLM.plan(model, operation) do
      {:ok, plan} ->
        [
          check(
            "model.surface",
            "model",
            "ok",
            "The selected #{operation} surface is available.",
            nil,
            %{
              "operation" => Atom.to_string(operation),
              "surface" => Atom.to_string(plan.surface),
              "transport" => Atom.to_string(plan.transport)
            }
          )
        ]

      {:error, _reason} ->
        [
          check(
            "model.surface",
            "model",
            "error",
            "The selected #{operation} surface is unavailable for this model.",
            "Inspect ReqLLM.plan/3 with this model and operation for a sanitized route diagnosis."
          )
        ]
    end
  end

  defp surface_checks(%LLMDB.Model{provider: provider}, opts, :running) do
    operation = Keyword.get(opts, :operation, :chat)

    case ReqLLM.provider(provider) do
      {:ok, module} ->
        [
          check(
            "model.surface",
            "model",
            "ok",
            "The registered provider owns the selected #{operation} operation.",
            nil,
            %{
              "operation" => Atom.to_string(operation),
              "surface" => "provider_default",
              "provider" => Atom.to_string(provider),
              "implementation" => inspect(module)
            }
          )
        ]

      {:error, _reason} ->
        []
    end
  end

  defp finch_configuration_check do
    case safe_finch_config() do
      {:ok, config} ->
        case validate_finch_config(config) do
          :ok ->
            check(
              "finch.configuration",
              "finch",
              "ok",
              "Finch pool configuration is valid.",
              nil,
              safe_finch_details(config)
            )

          {:error, message} ->
            check(
              "finch.configuration",
              "finch",
              "error",
              message,
              "Use positive pool size/count values and only :http1 and :http2 protocols."
            )
        end

      {:error, _reason} ->
        check(
          "finch.configuration",
          "finch",
          "error",
          "Finch pool configuration could not be loaded.",
          "Review config :req_llm Finch and stream pool settings."
        )
    end
  end

  defp safe_finch_config do
    {:ok, ReqLLM.Application.get_finch_config()}
  rescue
    _error -> {:error, :invalid_config}
  end

  defp validate_finch_config(config) when is_list(config) do
    with true <- Keyword.keyword?(config),
         name when is_atom(name) <- Keyword.get(config, :name),
         pools when is_map(pools) <- Keyword.get(config, :pools),
         true <- map_size(pools) > 0,
         true <- Enum.all?(pools, fn {_name, pool} -> valid_pool_config?(pool) end) do
      :ok
    else
      _invalid -> {:error, "Finch pool configuration is invalid."}
    end
  end

  defp valid_pool_config?(pool) when is_list(pool) do
    protocols = Keyword.get(pool, :protocols, [:http1])
    size = Keyword.get(pool, :size, 50)
    count = Keyword.get(pool, :count, 1)

    Keyword.keyword?(pool) and is_list(protocols) and protocols != [] and
      Enum.all?(protocols, &(&1 in [:http1, :http2])) and
      is_integer(size) and size > 0 and is_integer(count) and count > 0
  end

  defp valid_pool_config?(_pool), do: false

  defp safe_finch_details(config) do
    pools = Keyword.fetch!(config, :pools)

    %{
      "name" => safe_finch_name(Keyword.fetch!(config, :name)),
      "pools" =>
        pools
        |> Enum.map(fn {name, pool} ->
          %{
            "name" => safe_pool_name(name),
            "protocols" => Enum.map(Keyword.get(pool, :protocols, [:http1]), &Atom.to_string/1),
            "size" => Keyword.get(pool, :size, 50),
            "count" => Keyword.get(pool, :count, 1)
          }
        end)
        |> Enum.sort_by(& &1["name"])
    }
  end

  defp safe_finch_name(name) when is_atom(name), do: Atom.to_string(name)
  defp safe_finch_name(_name), do: "custom"

  defp safe_pool_name(:default), do: "default"
  defp safe_pool_name(name) when is_atom(name), do: Atom.to_string(name)
  defp safe_pool_name(_name), do: "configured_origin"

  defp finch_runtime_check(:not_running) do
    check(
      "finch.runtime",
      "finch",
      "warning",
      "Finch runtime availability was not inspected because ReqLLM is not running.",
      "Start :req_llm or explicitly allow diagnostic startup."
    )
  end

  defp finch_runtime_check(:startup_error) do
    check(
      "finch.runtime",
      "finch",
      "error",
      "Finch runtime availability could not be inspected because ReqLLM failed to start.",
      "Resolve the application startup error first."
    )
  end

  defp finch_runtime_check(:running) do
    name = ReqLLM.Application.finch_name()

    case GenServer.whereis(name) do
      pid when is_pid(pid) ->
        check(
          "finch.runtime",
          "finch",
          "ok",
          "The configured Finch process is reachable locally.",
          nil,
          %{"name" => safe_finch_name(name), "network_probe" => false}
        )

      nil ->
        check(
          "finch.runtime",
          "finch",
          "error",
          "The configured Finch process is not running.",
          "Ensure ReqLLM owns or starts the configured Finch name."
        )
    end
  rescue
    _error ->
      check(
        "finch.runtime",
        "finch",
        "error",
        "The configured Finch process name is invalid.",
        "Configure Finch with a valid registered process name."
      )
  end

  defp result(checks) do
    status =
      checks
      |> Enum.map(& &1["status"])
      |> Enum.max_by(&Map.fetch!(@status_order, &1), fn -> "ok" end)

    %{
      "schema_version" => @schema_version,
      "status" => status,
      "checks" => checks
    }
  end

  defp check(id, layer, status, message, remediation \\ nil, details \\ %{}) do
    %{
      "id" => id,
      "layer" => layer,
      "status" => status,
      "message" => message,
      "remediation" => remediation,
      "details" => details
    }
  end

  defp application_version(app) do
    case Application.spec(app, :vsn) do
      nil -> "unavailable"
      version -> to_string(version)
    end
  end

  defp optional_check(nil), do: []
  defp optional_check(check), do: [check]

  defp optional_atom_string(nil), do: nil
  defp optional_atom_string(value), do: Atom.to_string(value)

  defp status_icon("ok"), do: "OK"
  defp status_icon("warning"), do: "WARN"
  defp status_icon("error"), do: "ERROR"

  defp input_remediation do
    "Use :model, :provider, :operation, and :start_application? options supported by ReqLLM.Doctor.run/1."
  end
end
