defmodule ReqLLM.Providers.OpenAI.AdapterHelpers do
  @moduledoc """
  Shared helper functions for OpenAI-compatible model adapters (Azure, etc.).

  These functions handle OpenAI-specific request formatting that is shared
  across providers hosting OpenAI models.
  """

  @doc """
  Translates ReqLLM's tool_choice format to OpenAI's function format.

  ReqLLM uses `%{type: "tool", name: "tool_name"}` for specific tool selection.
  OpenAI requires `%{type: "function", function: %{name: "tool_name"}}`.

  Handles both atom and string key maps.
  """
  @spec translate_tool_choice_format(map()) :: map()
  def translate_tool_choice_format(body) do
    {tool_choice, body_key} =
      cond do
        Map.has_key?(body, :tool_choice) -> {Map.get(body, :tool_choice), :tool_choice}
        Map.has_key?(body, "tool_choice") -> {Map.get(body, "tool_choice"), "tool_choice"}
        true -> {nil, nil}
      end

    {type, name} =
      if is_map(tool_choice) do
        {Map.get(tool_choice, :type) || Map.get(tool_choice, "type"),
         Map.get(tool_choice, :name) || Map.get(tool_choice, "name")}
      else
        {nil, nil}
      end

    if type == "tool" && name do
      replacement =
        if is_map_key(tool_choice, :type) do
          %{type: "function", function: %{name: name}}
        else
          %{"type" => "function", "function" => %{"name" => name}}
        end

      Map.put(body, body_key, replacement)
    else
      body
    end
  end

  @doc """
  Adds strict mode settings to tools that have `strict: true` on their function.

  For tools with strict mode enabled:
  - Sets `additionalProperties: false` on the parameters schema
  - Makes all properties required
  """
  @spec add_strict_to_tools(map()) :: map()
  def add_strict_to_tools(body) do
    tools = body[:tools] || body["tools"]

    if tools && is_list(tools) do
      updated_tools =
        Enum.map(tools, fn tool ->
          function = tool[:function] || tool["function"]

          if function && (function[:strict] || function["strict"]) do
            function_with_strict =
              if is_map_key(tool, :function) do
                function
                |> Map.put(:strict, true)
                |> ensure_all_properties_required()
              else
                function
                |> Map.put("strict", true)
                |> ensure_all_properties_required()
              end

            if is_map_key(tool, :function) do
              Map.put(tool, :function, function_with_strict)
            else
              Map.put(tool, "function", function_with_strict)
            end
          else
            tool
          end
        end)

      if is_map_key(body, :tools) do
        Map.put(body, :tools, updated_tools)
      else
        Map.put(body, "tools", updated_tools)
      end
    else
      body
    end
  end

  @doc """
  Ensures all properties in a function's parameters schema are required.

  Also sets `additionalProperties: false` for strict JSON schema compliance.
  """
  @spec ensure_all_properties_required(map()) :: map()
  def ensure_all_properties_required(function) do
    params = function[:parameters] || function["parameters"]

    if params do
      properties = params[:properties] || params["properties"]

      if properties && is_map(properties) do
        all_property_names = Map.keys(properties)

        updated_params =
          if is_map_key(params, :properties) do
            params
            |> Map.put(:required, all_property_names)
            |> Map.put(:additionalProperties, false)
          else
            params
            |> Map.put("required", Enum.map(all_property_names, &to_string/1))
            |> Map.put("additionalProperties", false)
          end

        if is_map_key(function, :parameters) do
          Map.put(function, :parameters, updated_params)
        else
          Map.put(function, "parameters", updated_params)
        end
      else
        function
      end
    else
      function
    end
  end

  @doc """
  Checks if a model ID corresponds to an OpenAI reasoning model.

  Reasoning models (o-series, gpt-4.1, gpt-5, codex) require special handling:
  - Use `max_completion_tokens` instead of `max_tokens`
  - Support `reasoning_effort` parameter

  Note: gpt-5-chat-latest is a non-reasoning variant that uses standard conventions.
  """
  @spec reasoning_model?(term()) :: boolean()
  def reasoning_model?(model_id) when is_binary(model_id) do
    o_series_model?(model_id) || gpt41_model?(model_id) || gpt5_model?(model_id) ||
      codex_model?(model_id)
  end

  def reasoning_model?(_), do: false

  @doc "Checks if model is an o-series reasoning model (o1, o3, o4)."
  @spec o_series_model?(term()) :: boolean()
  def o_series_model?(<<"o1", _::binary>>), do: true
  def o_series_model?(<<"o3", _::binary>>), do: true
  def o_series_model?(<<"o4", _::binary>>), do: true
  def o_series_model?(_), do: false

  @doc "Checks if model is a GPT-4.1 model."
  @spec gpt41_model?(term()) :: boolean()
  def gpt41_model?(<<"gpt-4.1", _::binary>>), do: true
  def gpt41_model?(_), do: false

  @doc "Checks if model is a GPT-5 reasoning model (excludes gpt-5-chat-latest)."
  @spec gpt5_model?(term()) :: boolean()
  def gpt5_model?("gpt-5-chat-latest"), do: false
  def gpt5_model?(<<"gpt-5", _::binary>>), do: true
  def gpt5_model?(_), do: false

  @doc "Checks if model is a Codex model (codex-mini, gpt-5-codex, etc.)."
  @spec codex_model?(term()) :: boolean()
  def codex_model?(<<"codex", _::binary>>), do: true
  def codex_model?(model_id) when is_binary(model_id), do: String.contains?(model_id, "-codex")
  def codex_model?(_), do: false

  @doc "Checks if model is a DeepSeek model."
  @spec deepseek_model?(term()) :: boolean()
  def deepseek_model?(<<"deepseek", _::binary>>), do: true
  def deepseek_model?(_), do: false

  @doc """
  Adds appropriate token limit parameters based on model type.

  For reasoning models (o1, o3, o4, gpt-4.1, gpt-5):
  - Uses `max_completion_tokens` instead of `max_tokens`
  - Falls back to `max_tokens` value if `max_completion_tokens` not specified

  For standard models:
  - Uses `max_tokens` and optionally `max_completion_tokens`

  Cleans up any existing token limit keys to ensure consistent state.
  """
  @spec add_token_limits(map(), String.t(), keyword()) :: map()
  def add_token_limits(body, model_id, opts) do
    body =
      body
      |> Map.drop([:max_tokens, "max_tokens", :max_completion_tokens, "max_completion_tokens"])

    if reasoning_model?(model_id) do
      maybe_put(body, :max_completion_tokens, opts[:max_completion_tokens] || opts[:max_tokens])
    else
      body
      |> maybe_put(:max_tokens, opts[:max_tokens])
      |> maybe_put(:max_completion_tokens, opts[:max_completion_tokens])
    end
  end

  @doc """
  Adds parallel_tool_calls option to the request body.

  Checks multiple option sources for the value:
  - `opts[:parallel_tool_calls]`
  - `provider_opts[:openai_parallel_tool_calls]`
  - `provider_opts[:parallel_tool_calls]`
  """
  @spec add_parallel_tool_calls(map(), keyword(), keyword()) :: map()
  def add_parallel_tool_calls(body, opts, provider_opts) do
    ptc =
      opts[:parallel_tool_calls] ||
        provider_opts[:openai_parallel_tool_calls] ||
        provider_opts[:parallel_tool_calls]

    maybe_put(body, :parallel_tool_calls, ptc)
  end

  @doc """
  Adds response_format to the request body with schema normalization.

  Handles json_schema response formats by converting ReqLLM schema DSL
  to JSON Schema format. Supports both atom and string key maps.
  """
  @spec add_response_format(map(), keyword()) :: map()
  def add_response_format(body, provider_opts) do
    response_format = provider_opts[:response_format]

    normalized =
      case response_format do
        %{type: "json_schema", json_schema: %{schema: schema}} = m when is_list(schema) ->
          put_in(m, [:json_schema, :schema], ReqLLM.Schema.to_json(schema))

        %{"type" => "json_schema", "json_schema" => %{"schema" => schema}} = m
        when is_list(schema) ->
          js = ReqLLM.Schema.to_json(schema)
          %{m | "json_schema" => Map.put(m["json_schema"], "schema", js)}

        _ ->
          response_format
      end

    body
    |> Map.drop(["response_format", :response_format])
    |> maybe_put(:response_format, normalized)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
