defmodule ReqLLM.Providers.Alibaba.Shared do
  @moduledoc """
  Shared logic for Alibaba Cloud Bailian (DashScope) providers.

  Contains the DashScope-specific provider schema, option translation,
  and body construction used by both the international (`ReqLLM.Providers.Alibaba`)
  and China/Beijing (`ReqLLM.Providers.AlibabaCN`) providers.
  """

  import ReqLLM.Provider.Utils, only: [maybe_put: 3]

  @provider_schema [
    enable_search: [
      type: :boolean,
      doc: "Enable internet search integration during generation."
    ],
    search_options: [
      type: :map,
      doc:
        "Search configuration map: search_strategy (\"agent\" or \"agent_max\"), enable_source (boolean)."
    ],
    enable_thinking: [
      type: :boolean,
      doc: "Activate deep thinking mode for hybrid reasoning models."
    ],
    thinking_budget: [
      type: :pos_integer,
      doc: "Maximum token length for the thinking process."
    ],
    repetition_penalty: [
      type: :float,
      doc: "Penalise repeated tokens; >1.0 reduces repetition (default 1.0)."
    ],
    enable_code_interpreter: [
      type: :boolean,
      doc: "Activate code execution for thinking-mode Qwen3.5/3-max."
    ],
    vl_high_resolution_images: [
      type: :boolean,
      doc: "Increase max pixel limit for vision input."
    ],
    incremental_output: [
      type: :boolean,
      doc: "Streaming: send incremental chunks only (no prior content)."
    ],
    response_format: [
      type: :map,
      doc: "The response_format object (e.g., type: json_schema)."
    ]
  ]

  # Exclude 'response_format' here because it's not unique to DashScope but is instead a general provider option
  @dashscope_keys Keyword.keys(@provider_schema) -- [:response_format]

  @doc """
  Returns the DashScope-specific provider schema.
  """
  def provider_schema, do: @provider_schema

  @doc """
  Returns the list of DashScope-specific option keys.
  """
  def dashscope_keys, do: @dashscope_keys

  @doc """
  Returns the provider option keys that must be registered on requests.
  """
  def supported_provider_options, do: @dashscope_keys ++ [:dashscope_parameters, :response_format]

  @doc """
  Translates provider-specific options into DashScope parameters.

  Extracts DashScope-specific keys from the options and collects them
  into a `:dashscope_parameters` keyword, leaving standard OpenAI options
  untouched.
  """
  def translate_options(_operation, _model, opts) do
    dashscope_opts = Keyword.take(opts, @dashscope_keys)
    remaining_opts = Keyword.drop(opts, @dashscope_keys)

    dashscope_params =
      dashscope_opts
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    opts_with_dashscope =
      if map_size(dashscope_params) > 0 do
        Keyword.put(remaining_opts, :dashscope_parameters, dashscope_params)
      else
        remaining_opts
      end

    {opts_with_dashscope, []}
  end

  @doc """
  Overrides the default request preparation for :object operations to inject
  the appropriate `response_format` for DashScope's native structured output (JSON output).
  """
  def prepare_request(provider_mod, operation, model_spec, prompt, opts) do
    case operation do
      :object ->
        prepare_object_request(provider_mod, model_spec, prompt, opts)

      _ ->
        ReqLLM.Provider.Defaults.prepare_request(
          provider_mod,
          operation,
          model_spec,
          prompt,
          opts
        )
    end
  end

  defp prepare_object_request(provider_mod, model_spec, prompt, opts) do
    # Fetch schema and options
    compiled_schema = Keyword.fetch!(opts, :compiled_schema)

    # Build json schema from the provided schema struct
    json_schema = ReqLLM.Schema.to_json(compiled_schema.schema)
    final_schema = enforce_strict_schema_requirements(json_schema)

    schema_name = Map.get(compiled_schema, :name, "output_schema")

    # Construct response_format
    response_format = %{
      type: "json_schema",
      json_schema: %{
        name: schema_name,
        schema: final_schema,
        strict: true
      }
    }

    # Inject 'response_format' into :provider_options so they are passed to the API.
    opts_with_format =
      opts
      |> Keyword.update(
        :provider_options,
        [response_format: response_format],
        fn existing ->
          existing
          |> Keyword.put(:response_format, response_format)
        end
      )
      |> Keyword.put(:operation, :object)

    # Note: Fully qualified call to Defaults
    ReqLLM.Provider.Defaults.prepare_chat_request(
      provider_mod,
      model_spec,
      prompt,
      opts_with_format
    )
  end

  @doc """
  Builds the request body map with DashScope-specific parameters merged in.
  """
  def build_body(request) do
    dashscope_params = request.options[:dashscope_parameters]

    ReqLLM.Provider.Defaults.default_build_body(request)
    |> maybe_put(:top_k, request.options[:top_k])
    |> maybe_put(:enable_search, dashscope_params[:enable_search])
    |> maybe_put(:search_options, encode_map_param(dashscope_params[:search_options]))
    |> maybe_put(:enable_thinking, dashscope_params[:enable_thinking])
    |> maybe_put(:thinking_budget, dashscope_params[:thinking_budget])
    |> maybe_put(:repetition_penalty, dashscope_params[:repetition_penalty])
    |> maybe_put(:enable_code_interpreter, dashscope_params[:enable_code_interpreter])
    |> maybe_put(:vl_high_resolution_images, dashscope_params[:vl_high_resolution_images])
    |> maybe_put(:incremental_output, dashscope_params[:incremental_output])
  end

  @doc """
  Encodes the request body using the DashScope body builder.
  """
  def encode_body(request) do
    body = build_body(request)
    ReqLLM.Provider.Defaults.encode_body_from_map(request, body)
  end

  @doc """
  Builds a streaming request with validated and translated options.
  """
  def attach_stream(provider_mod, model, context, opts, finch_name) do
    processed_opts =
      ReqLLM.Provider.Options.process_stream!(
        provider_mod,
        :chat,
        model,
        context,
        opts
      )

    ReqLLM.Provider.Defaults.default_attach_stream(
      provider_mod,
      model,
      context,
      processed_opts,
      finch_name
    )
  end

  defp encode_map_param(nil), do: nil

  defp encode_map_param(params) when is_map(params) do
    Map.new(params, fn {k, v} -> {to_string(k), v} end)
  end

  defp enforce_strict_schema_requirements(
         %{"type" => "object", "properties" => properties} = schema
       ) do
    all_property_names = Map.keys(properties)

    schema
    |> Map.put("required", all_property_names)
    |> Map.put("additionalProperties", false)
  end

  defp enforce_strict_schema_requirements(schema), do: schema
end
