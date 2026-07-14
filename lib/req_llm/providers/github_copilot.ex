defmodule ReqLLM.Providers.GitHubCopilot do
  @moduledoc """
  GitHub Copilot provider using Copilot's OpenAI-compatible Chat Completions API.

  GitHub Copilot exposes chat models through `https://api.githubcopilot.com`.
  ReqLLM sends OpenAI Chat Completions-compatible requests and includes the
  `Copilot-Integration-Id` header required by Copilot clients.

  ## Configuration

      COPILOT_GITHUB_TOKEN=gho_...

  When no explicit token or environment token is configured, the provider falls
  back to `gh auth token`, matching GitHub Copilot CLI's GitHub CLI fallback.

  ## Examples

      ReqLLM.generate_text("github_copilot:gpt-4o-mini", "Hello!")

      {:ok, response} =
        ReqLLM.stream_text("github_copilot:gpt-4o-mini", "Tell me a story")

      response
      |> ReqLLM.StreamResponse.tokens()
      |> Enum.each(&IO.write/1)
  """

  use ReqLLM.Provider,
    id: :github_copilot,
    default_base_url: "https://api.githubcopilot.com",
    default_env_key: "COPILOT_GITHUB_TOKEN"

  use ReqLLM.Provider.Defaults

  @default_integration_id "vscode-chat"

  @provider_schema [
    github_copilot_auth: [
      type: {:in, [:auto, :token, :gh]},
      default: :auto,
      doc: "Authentication source. :auto checks configured tokens first, then gh auth token."
    ],
    github_copilot_integration_id: [
      type: :string,
      default: @default_integration_id,
      doc: "Value for the Copilot-Integration-Id request header."
    ]
  ]

  @doc false
  def display_name, do: "GitHub Copilot"

  @impl ReqLLM.Provider
  def build_body(request) do
    ReqLLM.Provider.Defaults.default_build_body(request)
    |> ReqLLM.Providers.OpenAI.AdapterHelpers.translate_tool_choice_format()
  end

  @impl ReqLLM.Provider
  def attach(request, model_input, user_opts) do
    {:ok, %LLMDB.Model{} = model} = ReqLLM.model(model_input)

    if model.provider != __MODULE__.provider_id() do
      raise ReqLLM.Error.Invalid.Provider.exception(provider: model.provider)
    end

    token = resolve_token!(user_opts)
    extra_option_keys = ReqLLM.Provider.Defaults.extra_option_keys(__MODULE__)

    request
    |> Req.Request.put_header("content-type", "application/json")
    |> Req.Request.put_header("authorization", "Bearer #{token}")
    |> Req.Request.put_header("copilot-integration-id", integration_id(user_opts))
    |> Req.Request.register_options(extra_option_keys)
    |> Req.Request.merge_options(
      ReqLLM.Provider.Defaults.finch_option(request) ++
        [
          model: model.provider_model_id || model.id,
          auth: {:bearer, token}
        ] ++ user_opts
    )
    |> ReqLLM.Step.Retry.attach(user_opts)
    |> ReqLLM.Step.Error.attach()
    |> Req.Request.prepend_request_steps(llm_encode_body: &encode_body/1)
    |> Req.Request.append_response_steps(llm_decode_response: &decode_response/1)
    |> ReqLLM.Step.Usage.attach(model)
    |> ReqLLM.Step.Telemetry.attach(model, user_opts)
    |> ReqLLM.Step.Fixture.maybe_attach(model, user_opts)
  end

  @impl ReqLLM.Provider
  def attach_stream(model, context, opts, finch_name) do
    opts = Keyword.put(opts, :api_key, resolve_token!(opts))

    processed_opts =
      ReqLLM.Provider.Options.process_stream!(
        __MODULE__,
        opts[:operation] || :chat,
        model,
        context,
        opts
      )

    ReqLLM.Provider.Defaults.default_attach_stream(
      __MODULE__,
      model,
      context,
      processed_opts,
      finch_name
    )
  end

  @doc false
  def streaming_http(_model, api_key, opts) do
    %{
      path: "/chat/completions",
      headers: [
        {"Authorization", "Bearer #{api_key}"},
        {"Content-Type", "application/json"},
        {"Copilot-Integration-Id", integration_id(opts)}
      ]
    }
  end

  @doc false
  def resolve_token!(opts) do
    case resolve_token(opts) do
      {:ok, token, _source} -> token
      {:error, reason} -> raise ReqLLM.Error.Invalid.Parameter.exception(parameter: reason)
    end
  end

  @doc false
  def resolve_token(opts) do
    provider_opts = Keyword.get(opts, :provider_options, [])

    case auth_mode(opts, provider_opts) do
      :token -> configured_token(opts)
      :gh -> gh_token()
      :auto -> configured_token(opts) |> fallback_to_gh_token()
    end
  end

  defp fallback_to_gh_token({:ok, _token, _source} = result), do: result
  defp fallback_to_gh_token({:error, _reason}), do: gh_token()

  defp configured_token(opts) do
    cond do
      valid_token?(Keyword.get(opts, :api_key)) ->
        {:ok, Keyword.fetch!(opts, :api_key), :api_key}

      valid_token?(Application.get_env(:req_llm, :github_copilot_api_key)) ->
        {:ok, Application.fetch_env!(:req_llm, :github_copilot_api_key), :application}

      valid_token?(System.get_env("COPILOT_GITHUB_TOKEN")) ->
        {:ok, System.fetch_env!("COPILOT_GITHUB_TOKEN"), :copilot_github_token}

      valid_token?(System.get_env("GH_TOKEN")) ->
        {:ok, System.fetch_env!("GH_TOKEN"), :gh_token}

      valid_token?(System.get_env("GITHUB_TOKEN")) ->
        {:ok, System.fetch_env!("GITHUB_TOKEN"), :github_token}

      true ->
        {:error,
         ":api_key option, config :req_llm, :github_copilot_api_key, COPILOT_GITHUB_TOKEN, GH_TOKEN, or GITHUB_TOKEN"}
    end
  end

  defp gh_token do
    case System.cmd("gh", ["auth", "token"], stderr_to_stdout: true) do
      {token, 0} ->
        token = String.trim(token)

        if valid_token?(token) do
          {:ok, token, :gh_cli}
        else
          {:error, "`gh auth token` returned an empty token"}
        end

      {output, _status} ->
        {:error,
         "GitHub Copilot credentials were not found and `gh auth token` failed: #{String.trim(output)}"}
    end
  rescue
    ErlangError ->
      {:error,
       "GitHub Copilot credentials were not found and the `gh` executable is unavailable. Set COPILOT_GITHUB_TOKEN or pass :api_key."}
  end

  defp auth_mode(opts, provider_opts) do
    mode = provider_option(opts, provider_opts, :github_copilot_auth, :auto)

    case mode do
      "token" -> :token
      "gh" -> :gh
      "auto" -> :auto
      other when other in [:token, :gh, :auto] -> other
      _ -> :auto
    end
  end

  defp integration_id(opts) do
    provider_opts = Keyword.get(opts, :provider_options, [])
    provider_option(opts, provider_opts, :github_copilot_integration_id, @default_integration_id)
  end

  defp provider_option(opts, provider_opts, key, default) do
    value_from_opts = Keyword.get(opts, key)
    value_from_provider_opts = option_from_container(provider_opts, key)
    value_from_opts || value_from_provider_opts || default
  end

  defp option_from_container(opts, key) when is_list(opts) do
    Keyword.get(opts, key) || list_value(opts, Atom.to_string(key))
  end

  defp option_from_container(opts, key) when is_map(opts) do
    Map.get(opts, key) || Map.get(opts, Atom.to_string(key))
  end

  defp option_from_container(_opts, _key), do: nil

  defp list_value(opts, key) do
    case Enum.find(opts, fn {option_key, _value} -> option_key == key end) do
      {_key, value} -> value
      nil -> nil
    end
  end

  defp valid_token?(token), do: is_binary(token) and String.trim(token) != ""
end
