defmodule ReqLLM.Key do
  @moduledoc """
  Fetches provider API keys.

  Order of precedence (stop at the first successful match):

    1. `:api_key` passed in the per-request options
    2. `Application.get_env/2`
    3. `System.get_env/1`
    4. [`JidoKeys.get/1`] if the library is loaded

  Raise `ReqLLM.Error.Invalid.Parameter` when the key cannot be found.

  ## Examples

      # Per-request key (highest priority)
      ReqLLM.generate_text(model, "hi", api_key: "sk-live-...")

      # Application config
      Application.put_env(:req_llm, :anthropic_api_key, "sk-ant-...")

      # Environment variable
      System.put_env("ANTHROPIC_API_KEY", "sk-ant-...")

      # JidoKeys (if available)
      JidoKeys.put("ANTHROPIC_API_KEY", "sk-ant-...")

  """

  @spec fetch!(atom(), keyword()) :: String.t() | no_return()
  def fetch!(provider_id, opts \\ []) do
    env_key = env_var_name(provider_id)

    key =
      Keyword.get(opts, :api_key) ||
        Application.get_env(:req_llm, String.to_atom(String.downcase(env_key))) ||
        System.get_env(env_key) ||
        jidokeys_get(env_key)

    if key && key != "" do
      key
    else
      raise ReqLLM.Error.Invalid.Parameter.exception(
              parameter:
                ":api_key option or #{env_key} env var " <>
                  "(optionally via JidoKeys.put/2)"
            )
    end
  end

  ## Helpers

  # Default convention: :anthropic -> "ANTHROPIC_API_KEY"
  defp env_var_name(provider_id) do
    "#{provider_id |> to_string() |> String.upcase()}_API_KEY"
  end

  defp jidokeys_get(env_key) do
    if Code.ensure_loaded?(JidoKeys), do: JidoKeys.get(env_key)
  end
end
