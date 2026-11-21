defmodule ReqLLM.Providers.Google.InteractionsAPI.Helpers do
  @moduledoc false

  alias ReqLLM.Error.Invalid.Parameter

  @api_revision "2026-05-20"
  @ai_studio_host "https://generativelanguage.googleapis.com"
  @interactions_metadata_key "google_interactions_steps"

  def api_revision, do: @api_revision
  def ai_studio_host, do: @ai_studio_host
  def interactions_metadata_key, do: @interactions_metadata_key

  def resolve_api_version(opts) do
    case get_opt(opts, :google_api_version) do
      version when version in ["v1", "v1beta"] ->
        version

      _ ->
        if non_empty_binary?(get_opt(opts, :agent)) or v1beta_interaction_id_in_opts?(opts) do
          "v1beta"
        else
          "v1"
        end
    end
  end

  defp v1beta_interaction_id_in_opts?(opts) do
    [
      get_opt(opts, :interactions_resume_id),
      get_opt(opts, :previous_interaction_id),
      get_opt(opts, :interaction_id)
    ]
    |> Enum.any?(&(is_binary(&1) and String.starts_with?(&1, "v1beta_")))
  end

  def effective_base_url(opts) do
    base_url = get_opt(opts, :base_url)
    version = resolve_api_version(opts)
    trimmed = if(is_binary(base_url), do: String.trim_trailing(base_url, "/"), else: nil)

    if trimmed in [nil, "", @ai_studio_host] do
      "#{@ai_studio_host}/#{version}"
    else
      trimmed
    end
  end

  def effective_base_url(raw_opts, processed_opts) do
    raw_base = get_opt(raw_opts, :base_url)

    if is_binary(raw_base) and String.trim(raw_base) != "" do
      effective_base_url(Keyword.put(processed_opts, :base_url, raw_base))
    else
      processed_opts
      |> Keyword.delete(:base_url)
      |> update_provider_options_if_present(&delete_option(&1, :base_url))
      |> effective_base_url()
    end
  end

  def use_header_auth?(opts) do
    case get_opt(opts, :google_auth_header) do
      false -> false
      _ -> true
    end
  end

  def redact_api_key(text) when is_binary(text) do
    Regex.replace(~r/([?&]key=)[^&\s"'}\]]+/, text, "\\1[REDACTED]")
  end

  def encode_path_segment(segment) when is_binary(segment) do
    URI.encode(segment, &URI.char_unreserved?/1)
  end

  def lookup_google_model(model_id) when is_binary(model_id) and model_id != "" do
    normalized = normalize_model_id(model_id)

    case LLMDB.model(:google, normalized) do
      {:ok, %LLMDB.Model{} = model} -> model
      _ -> LLMDB.Model.new!(%{id: normalized, provider: :google})
    end
  end

  def normalize_model_id(%LLMDB.Model{} = model) do
    normalize_model_id(model.provider_model_id || model.model || model.id)
  end

  def normalize_model_id(id) when is_binary(id) do
    normalized =
      id
      |> String.replace_prefix("google:", "")
      |> String.replace_prefix("models/", "")

    if normalized == "" do
      raise Parameter, parameter: "Interactions API requires a non-empty model or agent ID"
    end

    normalized
  end

  def normalize_model_id(_other) do
    raise Parameter, parameter: "Interactions API requires a non-empty model or agent ID"
  end

  def model_id_fallback(%LLMDB.Model{id: id}), do: id
  def model_id_fallback(_), do: nil

  def get_opt(opts, key) when is_list(opts) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when not is_nil(value) -> value
      _ -> get_nested_provider_opt(Keyword.get(opts, :provider_options), key)
    end
  end

  def get_opt(opts, key) when is_map(opts) do
    case fetch_map_opt(opts, key) do
      {:ok, value} when not is_nil(value) ->
        value

      _ ->
        case fetch_map_opt(opts, :provider_options) do
          {:ok, provider_opts} -> get_nested_provider_opt(provider_opts, key)
          :error -> nil
        end
    end
  end

  def get_opt(_, _), do: nil

  defp get_nested_provider_opt(provider_opts, key) when is_list(provider_opts),
    do: Keyword.get(provider_opts, key)

  defp get_nested_provider_opt(provider_opts, key) when is_map(provider_opts) do
    case fetch_map_opt(provider_opts, key) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  defp get_nested_provider_opt(_, _), do: nil

  def fetch_map_opt(map, key) when is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, val} when not is_nil(val) -> {:ok, val}
      {:ok, nil} -> Map.fetch(map, Atom.to_string(key))
      :error -> Map.fetch(map, Atom.to_string(key))
    end
  end

  def explicit_option?(opts, key) when is_list(opts) do
    Keyword.get(opts, key) != nil or
      explicit_provider_option?(Keyword.get(opts, :provider_options), key)
  end

  def explicit_option?(opts, key) when is_map(opts) do
    provider_opts =
      case fetch_map_opt(opts, :provider_options) do
        {:ok, val} -> val
        :error -> nil
      end

    has_non_nil_map_key?(opts, key) or explicit_provider_option?(provider_opts, key)
  end

  def explicit_option?(_opts, _key), do: false

  defp explicit_provider_option?(provider_opts, key) when is_list(provider_opts),
    do: Keyword.get(provider_opts, key) != nil

  defp explicit_provider_option?(provider_opts, key) when is_map(provider_opts),
    do: has_non_nil_map_key?(provider_opts, key)

  defp explicit_provider_option?(_, _), do: false

  defp has_non_nil_map_key?(map, key) when is_map(map) and is_atom(key) do
    case fetch_map_opt(map, key) do
      {:ok, value} -> value != nil
      :error -> false
    end
  end

  def update_provider_options_if_present(opts, fun) do
    case Keyword.fetch(opts, :provider_options) do
      {:ok, provider_opts} when is_list(provider_opts) or is_map(provider_opts) ->
        Keyword.put(opts, :provider_options, fun.(provider_opts))

      _ ->
        opts
    end
  end

  def delete_option(opts, key) when is_list(opts), do: Keyword.delete(opts, key)

  def delete_option(opts, key) when is_map(opts) do
    Map.drop(opts, [key, Atom.to_string(key)])
  end

  def truthy_opt?(opts, key), do: get_opt(opts, key) == true

  def non_empty_binary?(val) when is_binary(val), do: String.trim(val) != ""
  def non_empty_binary?(_), do: false

  def strip_schema_meta(nil), do: nil
  def strip_schema_meta(%_{} = struct), do: struct

  def strip_schema_meta(map) when is_map(map) do
    map
    |> Map.drop(["$schema", :"$schema"])
    |> Map.new(fn {k, v} ->
      key = to_string(k)

      val =
        if key in ["properties", "$defs", "definitions"] and is_map(v) do
          Map.new(v, fn {prop_k, prop_v} ->
            {to_string(prop_k), strip_schema_meta(prop_v)}
          end)
        else
          strip_schema_meta(v)
        end

      {key, val}
    end)
  end

  def strip_schema_meta(list) when is_list(list), do: Enum.map(list, &strip_schema_meta/1)
  def strip_schema_meta(value), do: value

  def stringify_keys(%_{} = struct) do
    case Jason.Encoder.impl_for(struct) do
      impl when impl in [nil, Jason.Encoder.Any] ->
        struct |> Map.from_struct() |> stringify_keys()

      _impl ->
        struct
    end
  end

  def stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), stringify_keys(v)} end)
  end

  def stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)

  def stringify_keys(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> stringify_keys()

  def stringify_keys(value), do: value

  def stringify_if_map(val) when is_map(val), do: stringify_keys(val)
  def stringify_if_map(_), do: nil

  def keywords_to_maps(%_{} = struct), do: struct

  def keywords_to_maps(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {k, keywords_to_maps(v)} end)
  end

  def keywords_to_maps(list) when is_list(list) and list != [] do
    if Keyword.keyword?(list) do
      Map.new(list, fn {k, v} -> {k, keywords_to_maps(v)} end)
    else
      Enum.map(list, &keywords_to_maps/1)
    end
  end

  def keywords_to_maps(value), do: value

  def json_response_format?(list) when is_list(list) and list != [] do
    if Keyword.keyword?(list) do
      list |> keywords_to_maps() |> json_response_format?()
    else
      Enum.any?(list, &json_response_format?/1)
    end
  end

  def json_response_format?(%{"mime_type" => "application/json"}), do: true
  def json_response_format?(%{mime_type: "application/json"}), do: true

  def json_response_format?(%{"type" => type})
      when type in ["json_object", :json_object, "json_schema", :json_schema, "object", :object],
      do: true

  def json_response_format?(%{type: type})
      when type in ["json_object", :json_object, "json_schema", :json_schema, "object", :object],
      do: true

  def json_response_format?(%{"properties" => props}) when is_map(props), do: true
  def json_response_format?(%{properties: props}) when is_map(props), do: true
  def json_response_format?(%{"schema" => schema}) when is_map(schema), do: true
  def json_response_format?(%{schema: schema}) when is_map(schema), do: true
  def json_response_format?(_), do: false

  def maybe_put_string(map, key, val) when is_binary(val) do
    if non_empty_binary?(val), do: Map.put(map, key, val), else: map
  end

  def maybe_put_string(map, _key, _val), do: map

  def maybe_put_int(map, key, val) when is_integer(val), do: Map.put(map, key, val)
  def maybe_put_int(map, _key, _val), do: map

  def maybe_put_number(map, key, val) when is_number(val), do: Map.put(map, key, val)
  def maybe_put_number(map, _key, _val), do: map

  def maybe_put_boolean(map, key, val) when is_boolean(val), do: Map.put(map, key, val)
  def maybe_put_boolean(map, _key, _val), do: map

  def maybe_put_true(map, key, true), do: Map.put(map, key, true)
  def maybe_put_true(map, _key, _), do: map

  def maybe_put_map(map, key, val) when is_map(val), do: Map.put(map, key, stringify_keys(val))
  def maybe_put_map(map, _key, _val), do: map

  def maybe_put_non_empty_map(map, key, val) when is_map(val) and map_size(val) > 0,
    do: Map.put(map, key, val)

  def maybe_put_non_empty_map(map, _key, _val), do: map

  def maybe_put_list(map, key, val) when is_list(val), do: Map.put(map, key, stringify_keys(val))
  def maybe_put_list(map, _key, _val), do: map

  def maybe_put_non_empty_list(map, key, val) when is_list(val) and val != [],
    do: Map.put(map, key, val)

  def maybe_put_non_empty_list(map, _key, _val), do: map

  def maybe_put_atom_key(map, _key, nil), do: map
  def maybe_put_atom_key(map, key, val), do: Map.put(map, key, val)

  def maybe_put_finish_reason(map, nil), do: map
  def maybe_put_finish_reason(map, reason), do: Map.put(map, :finish_reason, reason)

  def maybe_put_usage_meta(map, nil), do: map
  def maybe_put_usage_meta(map, usage), do: Map.put(map, :usage, usage)
end
