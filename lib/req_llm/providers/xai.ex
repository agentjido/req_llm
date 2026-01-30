defmodule ReqLLM.Providers.XAI do
  @moduledoc """
  xAI (Grok) provider – OpenAI Chat Completions compatible with xAI's models and features.

  ## Implementation

  Uses built-in OpenAI-style encoding/decoding defaults with xAI-specific enhancements.

  ## Structured Outputs

  The provider supports two modes for structured outputs via `ReqLLM.generate_object/4`:

  ### Native Structured Outputs (Recommended)

  For models >= grok-2-1212, uses xAI's native `response_format` with `json_schema`:
  - **Guaranteed schema compliance** enforced at generation time
  - Lower token overhead (no tool definitions in prompt)
  - More reliable than tool calling approach

  Supported models:
  - `grok-2-1212` and `grok-2-vision-1212`
  - `grok-beta`
  - All grok-3 and grok-4 variants
  - All future models

  ### Tool Calling Fallback

  For legacy models or when other tools are present:
  - Uses a synthetic `structured_output` tool with forced `tool_choice`
  - Works on all models as fallback
  - Automatically used for `grok-2` and `grok-2-vision` (pre-1212 versions)

  The mode is automatically selected based on model capabilities, or can be explicitly
  controlled via `:xai_structured_output_mode` option.

  ## xAI-Specific Extensions

  Beyond standard OpenAI parameters, xAI supports:
  - `max_completion_tokens` - Preferred over max_tokens for Grok-4 models
  - `reasoning_effort` - Reasoning level (low, medium, high) for Grok-3 mini models only
  - `xai_tools` - Agent tools configuration (e.g., web_search, x_search)
  - `parallel_tool_calls` - Allow parallel function calls (default: true)
  - `stream_options` - Streaming configuration (include_usage)
  - `xai_structured_output_mode` - Control structured output implementation (:auto, :json_schema, :tool_strict)

  ## Model Compatibility Notes

  - Native structured outputs supported on models >= `grok-2-1212` and `grok-2-vision-1212`
  - `reasoning_effort` is only supported for grok-3-mini and grok-3-mini-fast models
  - Grok-4 models do not support `stop`, `presence_penalty`, or `frequency_penalty`
  - Agent tools (e.g., web_search) incur additional costs per source

  ## Schema Constraints (Native Mode)

  xAI's native structured outputs have these JSON Schema limitations:
  - No `minLength`/`maxLength` for strings
  - No `minItems`/`maxItems`/`minContains`/`maxContains` for arrays
  - No `pattern` constraints
  - No `allOf` (must be expanded/flattened)
  - `anyOf` is supported

  The provider automatically sanitizes schemas by removing unsupported constraints
  and enforcing `additionalProperties: false` on root objects.

  See `provider_schema/0` for the complete xAI-specific schema and
  `ReqLLM.Provider.Options` for inherited OpenAI parameters.

  ## Configuration

      # Add to .env file (automatically loaded)
      XAI_API_KEY=xai-...

  ## Examples

      # Automatic mode selection (recommended)
      {:ok, response} =
        ReqLLM.generate_object(
          "xai:grok-4",
          "Generate a person profile",
          %{
            type: :object,
            properties: %{
              name: %{type: :string},
              age: %{type: :integer}
            }
          }
        )

      # Explicit mode control
      {:ok, response} =
        ReqLLM.generate_object(
          "xai:grok-4",
          "Generate a person profile",
          schema,
          provider_options: [xai_structured_output_mode: :json_schema]
        )
  """

  use ReqLLM.Provider,
    id: :xai,
    default_base_url: "https://api.x.ai/v1",
    default_env_key: "XAI_API_KEY"

  use ReqLLM.Provider.Defaults

  import ReqLLM.Provider.Utils,
    only: [maybe_put: 3, maybe_put_skip: 4, ensure_parsed_body: 1, stringify_keys: 1]

  @provider_schema [
    max_completion_tokens: [
      type: :integer,
      doc: "Maximum completion tokens (preferred over max_tokens for Grok-4)"
    ],
    search_parameters: [
      type: :map,
      doc:
        "Deprecated search parameters configuration. Use xai_tools with %{type: \"web_search\"} instead."
    ],
    xai_tools: [
      type: {:list, :map},
      doc: "Agent tools configuration (e.g., [%{type: \"web_search\"}])"
    ],
    parallel_tool_calls: [
      type: :boolean,
      doc: "Allow parallel function calls (default: true)"
    ],
    stream_options: [
      type: :map,
      doc: "Streaming options including usage reporting"
    ],
    xai_structured_output_mode: [
      type: {:in, [:auto, :json_schema, :tool_strict]},
      default: :auto,
      doc: """
      Structured output mode for xAI models:
      - `:auto` - Automatic selection based on model capabilities and context
      - `:json_schema` - Use native response_format with json_schema (requires support)
      - `:tool_strict` - Use strict tool calling with synthetic structured_output tool
      """
    ],
    response_format: [
      type: :map,
      doc: "Response format configuration (e.g., json_schema for structured output)"
    ]
  ]

  @doc """
  Custom prepare_request for :object operations using xAI native structured outputs.

  Determines the appropriate mode (:json_schema or :tool_strict) and delegates to
  the corresponding preparation function. Ensures adequate token limits for structured outputs.
  """
  @impl ReqLLM.Provider
  def prepare_request(:object, model_spec, prompt, opts) do
    compiled_schema = Keyword.fetch!(opts, :compiled_schema)
    {:ok, model} = ReqLLM.model(model_spec)

    opts_with_tokens = ensure_min_tokens(opts)
    mode = determine_output_mode(model, opts_with_tokens)

    case mode do
      :json_schema ->
        prepare_json_schema_request(model_spec, prompt, compiled_schema, opts_with_tokens)

      :tool_strict ->
        prepare_tool_strict_request(model_spec, prompt, compiled_schema, opts_with_tokens)
    end
  end

  @impl ReqLLM.Provider
  def prepare_request(:embedding, _model_spec, _input, _opts) do
    supported_operations = [:chat, :object]

    {:error,
     ReqLLM.Error.Invalid.Parameter.exception(
       parameter:
         "operation: :embedding not supported by #{inspect(__MODULE__)}. Supported operations: #{inspect(supported_operations)}"
     )}
  end

  @impl ReqLLM.Provider
  def prepare_request(:chat, model_spec, input, opts) do
    prepare_chat_request(model_spec, input, opts)
  end

  @impl ReqLLM.Provider
  def prepare_request(operation, model_spec, input, opts) do
    ReqLLM.Provider.Defaults.prepare_request(__MODULE__, operation, model_spec, input, opts)
  end

  defp prepare_chat_request(model_spec, prompt, opts) do
    with {:ok, model} <- ReqLLM.model(model_spec),
         {:ok, context} <- ReqLLM.Context.normalize(prompt, opts),
         opts_with_context = Keyword.put(opts, :context, context),
         http_opts = Keyword.get(opts, :req_http_options, []),
         {:ok, processed_opts} <-
           ReqLLM.Provider.Options.process(__MODULE__, :chat, model, opts_with_context) do
      use_responses = use_responses_api?(processed_opts)

      req_keys =
        supported_provider_options() ++
          [:context, :operation, :text, :stream, :model, :provider_options, :xai_api_type]

      path = if use_responses, do: "/responses", else: "/chat/completions"

      request =
        Req.new(
          [
            url: path,
            method: :post,
            receive_timeout: Keyword.get(processed_opts, :receive_timeout, 30_000)
          ] ++ http_opts
        )
        |> Req.Request.register_options(req_keys)
        |> Req.Request.merge_options(
          Keyword.take(processed_opts, req_keys) ++
            [
              model: model.id,
              base_url: Keyword.get(processed_opts, :base_url, default_base_url()),
              xai_api_type: if(use_responses, do: :responses, else: :chat)
            ]
        )
        |> attach(model, processed_opts)

      {:ok, request}
    end
  end

  defp use_responses_api?(opts) do
    xai_tools = Keyword.get(opts, :xai_tools, [])

    Enum.any?(xai_tools, fn tool ->
      tool_type = normalize_tool_type(Map.get(tool, "type") || Map.get(tool, :type))
      tool_type in ["web_search", "x_search"]
    end)
  end

  defp ensure_min_tokens(opts) do
    max_tokens = Keyword.get(opts, :max_tokens) || Keyword.get(opts, :max_completion_tokens)

    case max_tokens do
      nil ->
        Keyword.put(opts, :max_tokens, 4096)

      tokens when tokens < 200 ->
        Keyword.put(opts, :max_tokens, 200)

      _tokens ->
        opts
    end
  end

  @dialyzer {:nowarn_function, prepare_json_schema_request: 4}
  @spec prepare_json_schema_request(term(), term(), map(), keyword()) ::
          {:ok, Req.Request.t()} | {:error, ReqLLM.Error.t()}
  defp prepare_json_schema_request(model_spec, prompt, compiled_schema, opts) do
    schema_name = Map.get(compiled_schema, :name, "output_schema")
    json_schema = ReqLLM.Schema.to_json(compiled_schema.schema)

    case sanitize_schema_for_xai(json_schema) do
      {:ok, sanitized_schema} ->
        opts_with_format =
          opts
          |> Keyword.update(
            :provider_options,
            [
              response_format: %{
                type: "json_schema",
                json_schema: %{
                  name: schema_name,
                  strict: true,
                  schema: sanitized_schema
                }
              },
              parallel_tool_calls: false
            ],
            fn provider_opts ->
              provider_opts
              |> Keyword.put(:response_format, %{
                type: "json_schema",
                json_schema: %{
                  name: schema_name,
                  strict: true,
                  schema: sanitized_schema
                }
              })
              |> Keyword.put(:parallel_tool_calls, false)
            end
          )
          |> Keyword.delete(:tools)
          |> Keyword.delete(:tool_choice)
          |> Keyword.put(:operation, :object)

        prepare_request(:chat, model_spec, prompt, opts_with_format)

      {:error, error} ->
        {:error, error}
    end
  end

  @dialyzer {:nowarn_function, prepare_tool_strict_request: 4}
  @spec prepare_tool_strict_request(term(), term(), map(), keyword()) ::
          {:ok, Req.Request.t()} | {:error, ReqLLM.Error.t()}
  defp prepare_tool_strict_request(model_spec, prompt, compiled_schema, opts) do
    structured_output_tool =
      ReqLLM.Tool.new!(
        name: "structured_output",
        description: "Generate structured output matching the provided schema",
        parameter_schema: compiled_schema.schema,
        strict: true,
        callback: fn _args -> {:ok, "structured output generated"} end
      )

    opts_with_tool =
      opts
      |> Keyword.update(:tools, [structured_output_tool], &[structured_output_tool | &1])
      |> Keyword.put(:tool_choice, %{
        type: "function",
        function: %{name: "structured_output"}
      })
      |> Keyword.update(
        :provider_options,
        [parallel_tool_calls: false],
        &Keyword.put(&1, :parallel_tool_calls, false)
      )
      |> Keyword.put(:operation, :object)

    prepare_request(:chat, model_spec, prompt, opts_with_tool)
  end

  @impl ReqLLM.Provider
  def extract_usage(body, _model) when is_map(body) do
    case body do
      %{"usage" => usage} ->
        normalized_usage = Map.put_new(usage, "cached_tokens", 0)
        normalized_usage = maybe_add_xai_tool_usage(normalized_usage, body)
        {:ok, normalized_usage}

      _ ->
        {:error, :no_usage_found}
    end
  end

  def extract_usage(_, _), do: {:error, :invalid_body}

  defp maybe_add_xai_tool_usage(usage, body) when is_map(usage) do
    sources =
      Map.get(usage, "num_sources_used") ||
        Map.get(usage, :num_sources_used) ||
        extract_server_tool_usage(body)

    web_search_calls = extract_web_search_calls(usage)

    cond do
      is_number(web_search_calls) and web_search_calls > 0 ->
        Map.put(usage, :tool_usage, ReqLLM.Usage.Tool.build(:web_search, web_search_calls, :call))

      is_number(sources) and sources > 0 ->
        Map.put(usage, :tool_usage, ReqLLM.Usage.Tool.build(:web_search, sources, :source))

      true ->
        usage
    end
  end

  defp extract_web_search_calls(usage) when is_map(usage) do
    details = ReqLLM.MapAccess.get(usage, :server_side_tool_usage_details, %{})
    ReqLLM.MapAccess.get(details, :web_search_calls)
  end

  defp extract_server_tool_usage(body) when is_map(body) do
    tool_usage =
      Map.get(body, "server_side_tool_usage") ||
        Map.get(body, :server_side_tool_usage) ||
        Map.get(body, "server_side_tool_use") ||
        Map.get(body, :server_side_tool_use)

    case tool_usage do
      %{} = usage ->
        Map.get(usage, "web_search") ||
          Map.get(usage, :web_search) ||
          Map.get(usage, "SERVER_SIDE_TOOL_WEB_SEARCH") ||
          Map.get(usage, :SERVER_SIDE_TOOL_WEB_SEARCH) ||
          Map.get(usage, "x_search") ||
          Map.get(usage, :x_search) ||
          Map.get(usage, "SERVER_SIDE_TOOL_X_SEARCH") ||
          Map.get(usage, :SERVER_SIDE_TOOL_X_SEARCH)

      _ ->
        nil
    end
  end

  @doc """
  Check if a model supports native structured outputs via response_format with json_schema.

  Prefers metadata flags when available, with heuristic fallback for models without metadata.

  ## Heuristic Rules
  - Exact "grok-2" or "grok-2-vision" → false (legacy models)
  - Model starting with "grok-2-" or "grok-2-vision-" with suffix < "1212" → false
  - Everything else → true (grok-3+, grok-4+, grok-beta, grok-2-1212+)

  ## Examples

      iex> supports_native_structured_outputs?(%LLMDB.Model{model: "grok-2"})
      false

      iex> supports_native_structured_outputs?(%LLMDB.Model{model: "grok-2-1212"})
      true

      iex> supports_native_structured_outputs?("grok-3")
      true
  """
  @spec supports_native_structured_outputs?(LLMDB.Model.t() | binary()) :: boolean()
  def supports_native_structured_outputs?(%LLMDB.Model{} = model) do
    case get_in(model, [Access.key(:capabilities, %{}), :native_json_schema]) do
      nil -> supports_native_structured_outputs?(model.id)
      value -> value
    end
  end

  def supports_native_structured_outputs?(model_name) when is_binary(model_name) do
    cond do
      model_name in ["grok-2", "grok-2-vision"] ->
        false

      String.starts_with?(model_name, "grok-2-") or
          String.starts_with?(model_name, "grok-2-vision-") ->
        suffix =
          cond do
            String.starts_with?(model_name, "grok-2-vision-") ->
              String.replace_prefix(model_name, "grok-2-vision-", "")

            String.starts_with?(model_name, "grok-2-") ->
              String.replace_prefix(model_name, "grok-2-", "")

            true ->
              ""
          end

        suffix >= "1212"

      true ->
        true
    end
  end

  @doc """
  Check if a model supports strict tool calling.

  All xAI models support strict tools.
  """
  @spec supports_strict_tools?(LLMDB.Model.t() | binary()) :: boolean()
  def supports_strict_tools?(_model), do: true

  @doc """
  Determine the structured output mode for a model and options.

  ## Mode Selection Logic
  1. If explicit `xai_structured_output_mode` is set, validate and use it
  2. If `response_format` with `json_schema` is present in options, force `:json_schema`
  3. If `:auto`:
     - Use `:json_schema` when model supports it AND no other tools present
     - Otherwise use `:tool_strict`

  ## Examples

      iex> determine_output_mode(%LLMDB.Model{model: "grok-3"}, [])
      :json_schema

      iex> determine_output_mode(%LLMDB.Model{model: "grok-2"}, [])
      :tool_strict

      iex> determine_output_mode(%LLMDB.Model{model: "grok-3"}, tools: [%{name: "other"}])
      :tool_strict
  """
  @spec determine_output_mode(LLMDB.Model.t(), keyword()) :: :json_schema | :tool_strict
  def determine_output_mode(model, opts) do
    explicit_mode =
      opts
      |> Keyword.get(:provider_options, [])
      |> Keyword.get(:xai_structured_output_mode)

    has_response_format_json_schema =
      opts
      |> Keyword.get(:response_format)
      |> case do
        %{json_schema: _} -> true
        _ -> false
      end

    cond do
      explicit_mode && explicit_mode != :auto ->
        validate_output_mode!(model, explicit_mode)
        explicit_mode

      has_response_format_json_schema ->
        :json_schema

      true ->
        auto_select_mode(model, opts)
    end
  end

  defp auto_select_mode(model, opts) do
    has_native_support = supports_native_structured_outputs?(model)
    has_other_tools = has_other_tools?(opts)

    if has_native_support and not has_other_tools do
      :json_schema
    else
      :tool_strict
    end
  end

  defp has_other_tools?(opts) do
    tools = Keyword.get(opts, :tools, [])

    Enum.any?(tools, fn tool ->
      name =
        case tool do
          %{name: n} -> n
          _ -> nil
        end

      name != "structured_output"
    end)
  end

  defp validate_output_mode!(model, mode) do
    case mode do
      :json_schema ->
        if !supports_native_structured_outputs?(model) do
          raise ArgumentError,
                "Model #{model.id} does not support :json_schema mode. Use :tool_strict or :auto instead."
        end

      :tool_strict ->
        :ok

      _ ->
        raise ArgumentError,
              "Invalid xai_structured_output_mode: #{inspect(mode)}. Must be :auto, :json_schema, or :tool_strict"
    end
  end

  @doc """
  Custom attach_stream that ensures translate_options is called for streaming requests.

  This is necessary because the default streaming path doesn't call translate_options,
  which means xAI-specific option normalization (max_tokens -> max_completion_tokens,
  reasoning_effort translation, etc.) wouldn't be applied to streaming requests.
  """
  @impl ReqLLM.Provider
  def attach_stream(model, context, opts, finch_name) do
    {translated_opts, _warnings} = translate_options(:chat, model, opts)
    base_url = ReqLLM.Provider.Options.effective_base_url(__MODULE__, model, translated_opts)
    opts_with_base_url = Keyword.put(translated_opts, :base_url, base_url)
    use_responses = use_responses_api?(opts_with_base_url)

    opts_with_base_url =
      if use_responses do
        tools = List.wrap(Keyword.get(opts_with_base_url, :tools, []))
        xai_tools = List.wrap(Keyword.get(opts_with_base_url, :xai_tools, []))
        merged_tools = tools ++ xai_tools

        if merged_tools == [] do
          opts_with_base_url
        else
          Keyword.put(opts_with_base_url, :tools, merged_tools)
        end
      else
        opts_with_base_url
      end

    if use_responses do
      ReqLLM.Providers.OpenAI.ResponsesAPI.attach_stream(
        model,
        context,
        opts_with_base_url,
        finch_name
      )
    else
      ReqLLM.Provider.Defaults.default_attach_stream(
        __MODULE__,
        model,
        context,
        opts_with_base_url,
        finch_name
      )
    end
  end

  @impl ReqLLM.Provider
  def translate_options(_operation, model, opts) do
    warnings = []

    {stream_value, opts} = Keyword.pop(opts, :stream?)
    opts = if stream_value, do: Keyword.put(opts, :stream, stream_value), else: opts

    {reasoning_effort, opts} = Keyword.pop(opts, :reasoning_effort)

    opts =
      case reasoning_effort do
        :low -> Keyword.put(opts, :reasoning_effort, "low")
        :medium -> Keyword.put(opts, :reasoning_effort, "medium")
        :high -> Keyword.put(opts, :reasoning_effort, "high")
        :default -> Keyword.put(opts, :reasoning_effort, "default")
        nil -> opts
        other -> Keyword.put(opts, :reasoning_effort, other)
      end

    opts = Keyword.delete(opts, :reasoning_token_budget)

    {xai_tools, opts} = Keyword.pop(opts, :xai_tools, [])
    {tools, opts} = Keyword.pop(opts, :tools, [])
    {xai_tools_from_tools, tools} = split_xai_tools(tools)
    xai_tools = List.wrap(xai_tools) ++ xai_tools_from_tools
    opts = if tools == [], do: opts, else: Keyword.put(opts, :tools, tools)

    {search_parameters, opts} = Keyword.pop(opts, :search_parameters)
    {web_search_options, opts} = Keyword.pop(opts, :web_search_options)

    {xai_tools, warnings} =
      maybe_add_web_search_tool(xai_tools, search_parameters, web_search_options, warnings)

    opts = if xai_tools == [], do: opts, else: Keyword.put(opts, :xai_tools, xai_tools)

    {max_tokens_value, opts} = Keyword.pop(opts, :max_tokens)

    {opts, warnings} =
      if max_tokens_value && !Keyword.has_key?(opts, :max_completion_tokens) do
        warning =
          "xAI prefers max_completion_tokens over max_tokens. Translated max_tokens to max_completion_tokens."

        {Keyword.put(opts, :max_completion_tokens, max_tokens_value), [warning | warnings]}
      else
        {opts, warnings}
      end

    unsupported_params = [:logit_bias, :service_tier]

    {opts, warnings} =
      Enum.reduce(unsupported_params, {opts, warnings}, fn param, {acc_opts, acc_warnings} ->
        case Keyword.pop(acc_opts, param) do
          {nil, remaining_opts} ->
            {remaining_opts, acc_warnings}

          {_value, remaining_opts} ->
            warning = "#{param} is not supported by xAI and will be ignored"
            {remaining_opts, [warning | acc_warnings]}
        end
      end)

    {reasoning_effort, opts} = Keyword.pop(opts, :reasoning_effort)

    {opts, warnings} =
      if reasoning_effort do
        model_name = model.id

        if String.contains?(model_name, "grok-4") do
          warning = "reasoning_effort is not supported for Grok-4 models and will be ignored"
          {opts, [warning | warnings]}
        else
          {Keyword.put(opts, :reasoning_effort, reasoning_effort), warnings}
        end
      else
        {opts, warnings}
      end

    {opts, Enum.reverse(warnings)}
  end

  defp split_xai_tools(nil), do: {[], []}

  defp split_xai_tools(tools) when is_list(tools) do
    tools =
      Enum.reject(tools, fn tool ->
        tool_type = normalize_tool_type(Map.get(tool, "type") || Map.get(tool, :type))
        tool_type == "live_search"
      end)

    {xai_tools, other_tools} = Enum.split_with(tools, &xai_tool_entry?/1)
    {normalize_xai_tools(xai_tools), other_tools}
  end

  defp split_xai_tools(tool), do: split_xai_tools([tool])

  defp xai_tool_entry?(%{} = tool) do
    tool_type = normalize_tool_type(Map.get(tool, "type") || Map.get(tool, :type))
    tool_type in ["web_search", "x_search"]
  end

  defp xai_tool_entry?(_), do: false

  defp normalize_tool_type(type) when is_atom(type), do: Atom.to_string(type)
  defp normalize_tool_type(type) when is_binary(type), do: type
  defp normalize_tool_type(_), do: nil

  defp normalize_xai_tools(tools) do
    tools
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> Enum.map(&normalize_xai_tool/1)
    |> Enum.reject(&live_search_tool?/1)
  end

  defp live_search_tool?(%{} = tool) do
    tool_type = normalize_tool_type(Map.get(tool, "type") || Map.get(tool, :type))
    tool_type == "live_search"
  end

  defp live_search_tool?(_), do: false

  defp normalize_xai_tool(tool) do
    normalized = stringify_keys(tool)
    tool_type = normalize_tool_type(Map.get(normalized, "type"))

    if is_binary(tool_type) do
      Map.put(normalized, "type", tool_type)
    else
      normalized
    end
  end

  defp maybe_add_web_search_tool(xai_tools, search_parameters, web_search_options, warnings) do
    if search_parameters != nil or web_search_options != nil do
      warning =
        "search_parameters is deprecated. Use xai_tools with %{type: \"web_search\"} instead."

      updated_tools = ensure_xai_tool(xai_tools, %{"type" => "web_search"})
      {updated_tools, [warning | warnings]}
    else
      {xai_tools, warnings}
    end
  end

  defp ensure_xai_tool(xai_tools, tool) do
    normalized = normalize_xai_tools(xai_tools)
    normalized_tool = normalize_xai_tool(tool)
    tool_type = normalize_tool_type(Map.get(normalized_tool, "type"))

    if Enum.any?(normalized, fn existing -> Map.get(existing, "type") == tool_type end) do
      normalized
    else
      normalized ++ [normalized_tool]
    end
  end

  defp merge_xai_tools(existing, xai_tools) do
    existing_tools = List.wrap(existing)
    new_tools = normalize_xai_tools(xai_tools)

    case {existing_tools, new_tools} do
      {[], []} -> nil
      _ -> existing_tools ++ new_tools
    end
  end

  @impl ReqLLM.Provider
  def decode_stream_event(event, model) do
    {chunks, _state} = decode_stream_event(event, model, nil)
    chunks
  end

  @impl ReqLLM.Provider
  def decode_stream_event(event, model, state) do
    if responses_stream_event?(event) do
      ReqLLM.Providers.OpenAI.ResponsesAPI.decode_stream_event(event, model, state)
    else
      chunks = ReqLLM.Provider.Defaults.default_decode_stream_event(event, model)
      {chunks, state}
    end
  end

  defp responses_stream_event?(%{event: event}) when is_binary(event) do
    String.starts_with?(event, "response.")
  end

  defp responses_stream_event?(%{data: %{"event" => event}}) when is_binary(event) do
    String.starts_with?(event, "response.")
  end

  defp responses_stream_event?(%{data: %{"type" => type}}) when is_binary(type) do
    String.starts_with?(type, "response.")
  end

  defp responses_stream_event?(_), do: false

  @doc """
  Custom body encoding that adds xAI-specific extensions to the default OpenAI-compatible format.

  Adds support for:
  - max_completion_tokens (preferred over max_tokens for Grok-4)
  - reasoning_effort (low, medium, high) for grok-3-mini models
  - xai_tools (agent tool configuration)
  - parallel_tool_calls (with skip for true default)
  - stream_options (streaming configuration)
  """
  @impl ReqLLM.Provider
  def encode_body(request) do
    case request.options[:xai_api_type] do
      :responses ->
        encode_responses_body(request)

      _ ->
        body = build_body(request)
        ReqLLM.Provider.Defaults.encode_body_from_map(request, body)
    end
  end

  @impl ReqLLM.Provider
  def build_body(request) do
    body = ReqLLM.Provider.Defaults.default_build_body(request)
    tools = merge_xai_tools(body[:tools], request.options[:xai_tools])

    body
    |> maybe_put(:max_completion_tokens, request.options[:max_completion_tokens])
    |> maybe_put(:reasoning_effort, request.options[:reasoning_effort])
    |> maybe_put_skip(:parallel_tool_calls, request.options[:parallel_tool_calls], [true])
    |> maybe_put(:stream_options, request.options[:stream_options])
    |> maybe_put(:tools, tools)
  end

  defp encode_responses_body(request) do
    request
    |> merge_xai_tools_for_responses()
    |> normalize_responses_token_limit()
    |> ReqLLM.Providers.OpenAI.ResponsesAPI.encode_body()
  end

  defp merge_xai_tools_for_responses(%Req.Request{} = request) do
    opts = request.options
    tools = List.wrap(opts_get(opts, :tools, []))
    xai_tools = normalize_xai_tools(opts_get(opts, :xai_tools, []))
    merged_tools = tools ++ xai_tools

    opts =
      opts
      |> opts_delete(:xai_tools)
      |> maybe_put_tools(merged_tools)

    %{request | options: opts}
  end

  defp maybe_put_tools(opts, []), do: opts_delete(opts, :tools)
  defp maybe_put_tools(opts, tools), do: opts_put(opts, :tools, tools)

  defp normalize_responses_token_limit(%Req.Request{} = request) do
    opts = request.options
    max_output_tokens = opts_get(opts, :max_output_tokens)
    max_completion_tokens = opts_get(opts, :max_completion_tokens)

    opts =
      if is_nil(max_output_tokens) and is_number(max_completion_tokens) do
        opts_put(opts, :max_output_tokens, max_completion_tokens)
      else
        opts
      end

    opts = opts_delete(opts, :max_completion_tokens)
    %{request | options: opts}
  end

  defp opts_get(opts, key, default \\ nil) do
    cond do
      is_list(opts) -> Keyword.get(opts, key, default)
      is_map(opts) -> ReqLLM.MapAccess.get(opts, key, default)
      true -> default
    end
  end

  defp opts_put(opts, key, value) do
    cond do
      is_list(opts) -> Keyword.put(opts, key, value)
      is_map(opts) -> Map.put(opts, key, value)
      true -> opts
    end
  end

  defp opts_delete(opts, key) do
    cond do
      is_list(opts) -> Keyword.delete(opts, key)
      is_map(opts) -> Map.delete(opts, key)
      true -> opts
    end
  end

  @doc """
  Decodes xAI API responses based on operation type and streaming mode.

  ## Response Handling

  - **Chat operations**: Converts to ReqLLM.Response struct
  - **Streaming**: Creates response with chunk stream
  - **Non-streaming**: Merges context with assistant response

  ## Error Handling

  Non-200 status codes are converted to ReqLLM.Error.API.Response exceptions.
  """
  @impl ReqLLM.Provider
  def decode_response({req, resp}) do
    if req.options[:xai_api_type] == :responses do
      raw_body = resp.body

      case ReqLLM.Providers.OpenAI.ResponsesAPI.decode_response({req, resp}) do
        {req, %Req.Response{} = decoded_resp} ->
          {req, merge_responses_tool_usage(decoded_resp, raw_body)}

        other ->
          other
      end
    else
      case resp.status do
        200 ->
          decode_success_response(req, resp)

        status ->
          decode_error_response(req, resp, status)
      end
    end
  end

  defp merge_responses_tool_usage(%Req.Response{} = resp, raw_body) do
    case extract_usage(raw_body, nil) do
      {:ok, usage} ->
        normalized = ReqLLM.Usage.Normalize.normalize(usage)
        tool_usage = normalized[:tool_usage]

        case resp.body do
          %ReqLLM.Response{usage: response_usage}
          when is_map(response_usage) and is_map(tool_usage) ->
            updated_usage = Map.put(response_usage, :tool_usage, tool_usage)
            %{resp | body: %{resp.body | usage: updated_usage}}

          _ ->
            resp
        end

      _ ->
        resp
    end
  end

  defp decode_success_response(req, resp) do
    operation = req.options[:operation]
    decode_chat_response(req, resp, operation)
  end

  defp decode_error_response(req, resp, status) do
    err =
      ReqLLM.Error.API.Response.exception(
        reason: "xAI API error",
        status: status,
        response_body: resp.body
      )

    {req, err}
  end

  defp decode_chat_response(req, resp, operation) do
    model_name = ReqLLM.ModelId.normalize(req.options[:model], "xai")
    model = LLMDB.Model.new!(%{id: model_name, provider: :xai})
    is_streaming = req.options[:stream] == true

    if is_streaming do
      decode_streaming_response(req, resp, model_name)
    else
      decode_non_streaming_response(req, resp, model, operation)
    end
  end

  defp decode_streaming_response(req, resp, model_name) do
    # Real-time streaming - use the stream created by Stream step
    # The request has already been initiated by the initial Req.request call
    # We just need to return the configured stream, not make another request
    real_time_stream = Req.Request.get_private(req, :real_time_stream, [])

    response = %ReqLLM.Response{
      id: "stream-#{System.unique_integer([:positive])}",
      model: model_name,
      context: req.options[:context] || %ReqLLM.Context{messages: []},
      message: nil,
      stream?: true,
      stream: real_time_stream,
      usage: %{
        input_tokens: 0,
        output_tokens: 0,
        total_tokens: 0,
        cached_tokens: 0,
        reasoning_tokens: 0
      },
      finish_reason: nil,
      provider_meta: %{}
    }

    {req, %{resp | body: response}}
  end

  defp decode_non_streaming_response(req, resp, model, operation) do
    body = ensure_parsed_body(resp.body)

    case body do
      body when is_map(body) ->
        {:ok, response} = ReqLLM.Provider.Defaults.decode_response_body_openai_format(body, model)

        final_response =
          case operation do
            :object ->
              extract_and_set_object(response)

            _ ->
              response
          end

        merged_response = merge_response_with_context(req, final_response)
        {req, %{resp | body: merged_response}}

      _ ->
        error =
          ReqLLM.Error.API.Response.exception(
            reason: "xAI response decode error: invalid body",
            response_body: body
          )

        {req, error}
    end
  end

  defp extract_and_set_object(response) do
    extracted_object =
      case ReqLLM.Response.tool_calls(response) do
        [] ->
          extract_from_content(response)

        tool_calls ->
          ReqLLM.ToolCall.find_args(tool_calls, "structured_output")
      end

    %{response | object: extracted_object}
  end

  defp extract_from_content(response) do
    %ReqLLM.Message{content: content_parts} = response.message

    content_parts
    |> Enum.find_value(fn
      %ReqLLM.Message.ContentPart{type: :text, text: text} when is_binary(text) ->
        parse_json_defensively(text)

      _ ->
        nil
    end)
  end

  @dialyzer {:nowarn_function, parse_json_defensively: 1}
  @spec parse_json_defensively(term()) :: map() | nil
  defp parse_json_defensively(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, parsed_object} when is_map(parsed_object) -> parsed_object
      _ -> nil
    end
  end

  defp parse_json_defensively(_), do: nil

  defp merge_response_with_context(req, response) do
    context = req.options[:context] || %ReqLLM.Context{messages: []}
    ReqLLM.Context.merge_response(context, response)
  end

  @spec sanitize_schema_for_xai(map()) ::
          {:ok, map()} | {:error, ReqLLM.Error.t()}
  defp sanitize_schema_for_xai(schema) when is_map(schema) do
    if Map.has_key?(schema, "allOf") do
      {:error,
       ReqLLM.Error.Invalid.Schema.exception(
         reason:
           "xAI does not support allOf in JSON schemas. Please use a simpler schema structure without schema composition."
       )}
    else
      sanitized = do_sanitize_schema(schema, _is_root = true)
      {:ok, sanitized}
    end
  end

  @unsupported_constraints ~w(minLength maxLength minItems maxItems minContains maxContains pattern)

  defp do_sanitize_schema(schema, is_root) when is_map(schema) do
    schema
    |> Map.drop(@unsupported_constraints)
    |> Map.new(fn {key, value} -> {key, sanitize_value(value)} end)
    |> maybe_add_additional_properties(is_root)
  end

  defp sanitize_value(value) when is_map(value) do
    do_sanitize_schema(value, _is_root = false)
  end

  defp sanitize_value(value) when is_list(value) do
    Enum.map(value, &sanitize_value/1)
  end

  defp sanitize_value(value), do: value

  defp maybe_add_additional_properties(schema, true) do
    if schema["type"] == "object" and not Map.has_key?(schema, "additionalProperties") do
      Map.put(schema, "additionalProperties", false)
    else
      schema
    end
  end

  defp maybe_add_additional_properties(schema, false), do: schema
end
