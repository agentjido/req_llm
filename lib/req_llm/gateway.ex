defmodule ReqLLM.Gateway do
  @moduledoc """
  Optional gateway defaults for routing ReqLLM traffic through an edge service.

  When configured, providers will default to the gateway `base_url` and attach a
  service token header. Direct provider usage is still supported via explicit
  `base_url` option overrides per-request.

  Configuration sources (first non-empty wins):
  - `Application.get_env(:req_llm, :gateway_base_url)`
  - `System.get_env("RUNESTONE_URL")`

  Service token sources (optional):
  - `Application.get_env(:req_llm, :gateway_service_token)`
  - `System.get_env("RUNESTONE_SERVICE_TOKEN")`
  """

  @doc """
  Returns the configured gateway base URL or nil when not set.
  """
  @spec base_url() :: String.t() | nil
  def base_url do
    Application.get_env(:req_llm, :gateway_base_url) ||
      blank_to_nil(System.get_env("RUNESTONE_URL"))
  end

  @doc """
  Returns the configured gateway service token or nil when not set.
  """
  @spec service_token() :: String.t() | nil
  def service_token do
    Application.get_env(:req_llm, :gateway_service_token) ||
      blank_to_nil(System.get_env("RUNESTONE_SERVICE_TOKEN"))
  end

  @doc """
  Returns true if a gateway base_url is configured.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: base_url() != nil

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(val) when is_binary(val) do
    case String.trim(val) do
      "" -> nil
      other -> other
    end
  end
end

