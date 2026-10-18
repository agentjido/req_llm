defmodule ReqLLM.PricingContext do
  @moduledoc """
  Confirmed request and response facts used for local pricing.

  OpenAI API facts come from the physical endpoint, not model defaults. Only
  known OpenAI hosts establish regional processing; other hosts leave that fact
  to independently confirmed caller context. The returned service tier replaces
  any caller preference. A missing or `auto` tier is unknown, never `default`.

  Anthropic API facts come from the endpoint and returned usage metadata.
  Standard speed can also be confirmed from a Messages request sent directly
  to Anthropic. Missing region and gateway speed facts require explicit context.
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

  @doc """
  Merges confirmed Anthropic endpoint and returned usage facts into context.

  Returned region, speed, and service tier replace conflicting explicit facts.
  Invalid returned facts clear the corresponding explicit value. Missing facts
  preserve independently confirmed explicit context. For first-party Messages
  requests, an encoded request body without speed confirms standard speed.
  """
  @spec from_anthropic(
          String.t() | URI.t() | nil,
          map() | nil,
          map() | keyword() | nil,
          map() | String.t() | nil
        ) :: map()
  def from_anthropic(url, metadata, explicit_context \\ %{}, request_body \\ nil) do
    uri = parse_url(url)

    explicit_context
    |> normalize_context()
    |> put_fact(:api, anthropic_api(uri))
    |> put_returned_fact(metadata, :inference_geo, ["global", "us"])
    |> put_returned_fact(metadata, :service_tier, ["standard", "priority", "batch"])
    |> put_anthropic_speed(metadata, uri, request_body)
  end

  defp anthropic_api(%URI{path: "/v1/messages"}), do: "messages"
  defp anthropic_api(%URI{path: "/v1/messages/batches"}), do: "batch"
  defp anthropic_api(%URI{path: "/v1/messages/batches/" <> id}) when id != "", do: "batch"
  defp anthropic_api(_), do: nil

  defp put_returned_fact(context, metadata, key, allowed) do
    if has_fact?(metadata, key) do
      context
      |> Map.drop([key, Atom.to_string(key)])
      |> put_fact(key, known_fact(ReqLLM.MapAccess.get_raw(metadata, key), allowed))
    else
      context
    end
  end

  defp put_anthropic_speed(context, metadata, uri, request_body) do
    cond do
      has_fact?(metadata, :speed) ->
        put_speed(context, ReqLLM.MapAccess.get_raw(metadata, :speed))

      first_party_messages?(uri) ->
        case decoded_request_body(request_body) do
          body when is_map(body) ->
            speed =
              if has_fact?(body, :speed),
                do: ReqLLM.MapAccess.get_raw(body, :speed),
                else: "standard"

            put_speed(context, speed)

          _ ->
            context
        end

      true ->
        context
    end
  end

  defp put_speed(context, value) do
    body = ReqLLM.MapAccess.get_raw(context, :request_body, %{})
    body = if is_map(body), do: Map.drop(body, [:speed, "speed"]), else: %{}
    body = put_fact(body, :speed, known_fact(value, ["standard", "fast"]))
    put_fact(context, :request_body, body)
  end

  defp known_fact(value, allowed) when is_atom(value),
    do: known_fact(Atom.to_string(value), allowed)

  defp known_fact(value, allowed), do: if(value in allowed, do: value)

  defp has_fact?(metadata, key) when is_map(metadata),
    do: Map.has_key?(metadata, key) or Map.has_key?(metadata, Atom.to_string(key))

  defp has_fact?(_metadata, _key), do: false

  defp first_party_messages?(%URI{host: host, path: "/v1/messages"}) when is_binary(host),
    do: String.downcase(host) == "api.anthropic.com"

  defp first_party_messages?(_), do: false

  defp decoded_request_body(body) when is_map(body), do: body

  defp decoded_request_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> nil
    end
  end

  defp decoded_request_body(_), do: nil

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
