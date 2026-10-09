defmodule ReqLLM.PricingContext do
  @moduledoc """
  Confirmed request and response facts used for local pricing.

  OpenAI API facts come from the physical endpoint, not model defaults. Only
  known OpenAI hosts establish regional processing; other hosts leave that fact
  to independently confirmed caller context. The returned service tier replaces
  any caller preference. A missing or `auto` tier is unknown, never `default`.
  """

  @doc """
  Merges confirmed OpenAI endpoint and returned metadata into explicit context.

  Accepts a URL string or URI and atom- or string-keyed response metadata. Other
  explicit facts are preserved. No request preference is used as a billed tier.
  """
  @spec from_openai(String.t() | URI.t() | nil, map() | nil, map() | keyword() | nil) :: map()
  def from_openai(url, provider_metadata, explicit_context \\ %{}) do
    context = normalize_context(explicit_context)
    uri = parse_url(url)

    context
    |> put_fact(:api, api(uri))
    |> put_fact(:regional_processing, regional_processing(uri))
    |> Map.delete(:service_tier)
    |> Map.delete("service_tier")
    |> put_fact(:service_tier, returned_tier(provider_metadata))
  end

  defp normalize_context(context) when is_map(context), do: context
  defp normalize_context(context) when is_list(context), do: Map.new(context)
  defp normalize_context(nil), do: %{}

  defp parse_url(%URI{} = uri), do: uri
  defp parse_url(url) when is_binary(url), do: URI.parse(url)
  defp parse_url(nil), do: nil

  defp api(%URI{path: "/v1/chat/completions"}), do: "chat_completions"
  defp api(%URI{path: "/v1/responses"}), do: "responses"
  defp api(%URI{path: "/v1/batches"}), do: "batch"
  defp api(%URI{path: "/v1/batches/" <> id}) when id != "", do: "batch"
  defp api(_), do: nil

  defp regional_processing(%URI{host: host}) when is_binary(host) do
    case String.downcase(host) do
      "api.openai.com" -> false
      host when host in ["us.api.openai.com", "eu.api.openai.com"] -> true
      _ -> nil
    end
  end

  defp regional_processing(_), do: nil

  defp returned_tier(metadata) when is_map(metadata) do
    tier = Map.get(metadata, :service_tier, Map.get(metadata, "service_tier"))

    case tier do
      tier when is_atom(tier) and tier not in [nil, true, false, :auto] -> Atom.to_string(tier)
      tier when is_binary(tier) and tier not in ["", "auto"] -> tier
      _ -> nil
    end
  end

  defp returned_tier(_), do: nil

  defp put_fact(context, _key, nil), do: context

  defp put_fact(context, key, value) do
    context |> Map.delete(Atom.to_string(key)) |> Map.put(key, value)
  end
end
