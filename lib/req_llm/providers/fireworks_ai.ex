defmodule ReqLLM.Providers.FireworksAI do
  @moduledoc """
  Fireworks AI provider – OpenAI-compatible Chat Completions API.

  ## Implementation

  Uses built-in OpenAI-style encoding/decoding defaults. Fireworks exposes an
  OpenAI-compatible endpoint, so request/response handling reuses the standard
  OpenAI wire format. Fireworks-specific extensions are added via `build_body/1`.

  Model identifiers follow the canonical `accounts/fireworks/models/<slug>` form
  (e.g. `fireworks_ai:accounts/fireworks/models/kimi-k2-instruct`).

  ## Fireworks-Specific Extensions

  Beyond standard OpenAI parameters, Fireworks supports:
  - `reasoning_effort` - Reasoning level (none, low, medium, high, xhigh, max)
  - `prompt_cache_key` / `prompt_cache_isolation_key` - Session affinity for KV cache
  - `prompt_truncate_len` - Truncate prompts to a specified token length
  - `safe_tokenization` - Prevent prompt injection via special tokens
  - `min_p`, `repetition_penalty`, `typical_p` - Extended sampling controls
  - `mirostat_target`, `mirostat_lr` - Mirostat sampling parameters
  - `perf_metrics_in_response` - Include performance metrics in the response body
  - `raw_output` - Return low-level model interaction details
  - `metadata` - Arbitrary metadata for tracing/distillation
  - `speculation` / `prediction` - Speculative decoding hints
  - `parallel_tool_calls` - Control concurrent tool invocations
  - `max_completion_tokens` - Reasoning-aware token budget

  ## Structured Output

  Two strategies for generating structured objects, selected via
  `fireworks_structured_output_mode`:

  - `:auto` (default) - Use native `response_format: json_schema` with strict
    enforcement
  - `:json_schema` - Force native `response_format: json_schema`
  - `:tool` - Use the tool-calling workaround (compatible with older models)

  Strict JSON schema enforcement (adds `additionalProperties: false` and marks
  every property required) can be disabled with `fireworks_json_schema_strict: false`.

  ## Constraints

  Fireworks rejects non-streaming chat requests with `max_tokens > 4096`.
  `translate_options/3` caps `max_tokens` to 4096 when `stream: false`.

  See `provider_schema/0` for the complete Fireworks-specific schema and
  `ReqLLM.Provider.Options` for inherited OpenAI parameters.

  ## Configuration

      # Add to .env file (automatically loaded)
      FIREWORKS_API_KEY=fw_...
  """

  use ReqLLM.Provider,
    id: :fireworks_ai,
    default_base_url: "https://api.fireworks.ai/inference/v1",
    default_env_key: "FIREWORKS_API_KEY"

  use ReqLLM.Provider.Defaults

  import ReqLLM.Provider.Utils, only: [maybe_put: 3]

  @non_streaming_max_tokens 4096
  @default_receive_timeout 300_000

  @provider_schema [
    prompt_cache_key: [
      type: :string,
      doc: "Session affinity key for KV cache optimization"
    ],
    prompt_cache_isolation_key: [
      type: :string,
      doc: "Isolation key for KV cache namespacing"
    ],
    prompt_truncate_len: [
      type: :pos_integer,
      doc: "Maximum number of tokens to keep in the prompt"
    ],
    safe_tokenization: [
      type: :boolean,
      doc: "Disallow special tokens in user content"
    ],
    min_p: [
      type: :float,
      doc: "Minimum probability sampling parameter"
    ],
    repetition_penalty: [
      type: :float,
      doc: "Repetition penalty applied during decoding"
    ],
    typical_p: [
      type: :float,
      doc: "Typical-p sampling parameter"
    ],
    mirostat_target: [
      type: :float,
      doc: "Target entropy for Mirostat sampling"
    ],
    mirostat_lr: [
      type: :float,
      doc: "Learning rate for Mirostat sampling"
    ],
    perf_metrics_in_response: [
      type: :boolean,
      doc: "Include performance metrics in the response body"
    ],
    raw_output: [
      type: :boolean,
      doc: "Return low-level model interaction details"
    ],
    speculation: [
      type: :map,
      doc: "Speculative decoding configuration"
    ],
    prediction: [
      type: :map,
      doc: "Predicted output for speculative decoding"
    ],
    metadata: [
      type: :map,
      doc: "Arbitrary metadata stored on the request for tracing/distillation"
    ],
    parallel_tool_calls: [
      type: :boolean,
      doc: "Whether the model may invoke multiple tools in parallel"
    ],
    max_completion_tokens: [
      type: :pos_integer,
      doc: "Maximum number of tokens to generate (reasoning-aware budget)"
    ],
    fireworks_reasoning_effort: [
      type: :string,
      doc: "Fireworks-native reasoning_effort string value"
    ],
    response_format: [
      type: :map,
      doc: "Native response_format (e.g. json_schema or json_object) for structured output"
    ],
    fireworks_structured_output_mode: [
      type: {:in, [:auto, :json_schema, :tool]},
      default: :auto,
      doc: "Strategy for object generation: :json_schema (native), :tool (workaround), or :auto"
    ],
    fireworks_json_schema_strict: [
      type: :boolean,
      default: true,
      doc: "Enforce additionalProperties=false and all-required on json_schema mode"
    ]
  ]

  @doc """
  Custom prepare_request for :object operations.

  Defaults to native `response_format: json_schema` (strict-enforced) and falls
  back to the tool-calling workaround when `fireworks_structured_output_mode`
  is `:tool`. All other operations delegate to the default implementation.
  """
  @impl ReqLLM.Provider
  def prepare_request(:object, model_spec, prompt, opts) do
    compiled_schema = Keyword.fetch!(opts, :compiled_schema)

    case structured_output_mode(opts) do
      :tool -> prepare_object_via_tool(model_spec, prompt, compiled_schema, opts)
      _ -> prepare_object_via_json_schema(model_spec, prompt, compiled_schema, opts)
    end
  end

  def prepare_request(operation, model_spec, input, opts) do
    ReqLLM.Provider.Defaults.prepare_request(__MODULE__, operation, model_spec, input, opts)
  end

  def pre_validate_options(_operation, _model, opts) do
    opts
    |> hoist_provider_option(:top_k)
    |> rename_provider_option(:reasoning_effort, :fireworks_reasoning_effort)
  end

  defp structured_output_mode(opts) do
    provider_opts = Keyword.get(opts, :provider_options, [])

    Keyword.get(provider_opts, :fireworks_structured_output_mode) ||
      Keyword.get(opts, :fireworks_structured_output_mode, :auto)
  end

  defp prepare_object_via_json_schema(model_spec, prompt, compiled_schema, opts) do
    schema_name = Map.get(compiled_schema, :name, "output_schema")
    json_schema = ReqLLM.Schema.to_json(compiled_schema.schema)

    provider_opts = Keyword.get(opts, :provider_options, [])

    strict = option_value(opts, provider_opts, :fireworks_json_schema_strict, true)

    json_schema =
      if strict do
        ReqLLM.Providers.OpenAI.AdapterHelpers.enforce_strict_recursive(json_schema)
      else
        json_schema
      end

    response_format = %{
      type: "json_schema",
      json_schema: %{
        name: schema_name,
        strict: strict,
        schema: json_schema
      }
    }

    opts_with_format =
      opts
      |> Keyword.put(:response_format, response_format)
      |> ReqLLM.Provider.Options.put_model_max_tokens_default(model_spec, fallback: 4096)
      |> Keyword.put(:operation, :object)

    ReqLLM.Provider.Defaults.prepare_request(
      __MODULE__,
      :chat,
      model_spec,
      prompt,
      opts_with_format
    )
  end

  defp prepare_object_via_tool(model_spec, prompt, compiled_schema, opts) do
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
      |> Keyword.put(:tool_choice, %{type: "function", function: %{name: "structured_output"}})
      |> Keyword.put(:parallel_tool_calls, false)
      |> ReqLLM.Provider.Options.put_model_max_tokens_default(model_spec, fallback: 4096)
      |> Keyword.put(:operation, :object)

    ReqLLM.Provider.Defaults.prepare_request(
      __MODULE__,
      :chat,
      model_spec,
      prompt,
      opts_with_tool
    )
  end

  @doc """
  Provider-specific option normalization.

  - Drops `:reasoning_token_budget` (Fireworks uses `reasoning_effort` instead).
  - Defaults `:receive_timeout` to 5 minutes (reasoning completions are slow).
  - Caps `:max_tokens` to 4096 for non-streaming requests with a warning,
    since Fireworks rejects larger budgets when `stream: false`.
  """
  @impl ReqLLM.Provider
  def translate_options(_operation, _model, opts) do
    opts =
      opts
      |> Keyword.delete(:reasoning_token_budget)
      |> Keyword.put_new(:receive_timeout, @default_receive_timeout)

    cap_non_streaming_max_tokens(opts)
  end

  defp cap_non_streaming_max_tokens(opts) do
    stream? = Keyword.get(opts, :stream, false) == true
    max_tokens = Keyword.get(opts, :max_tokens)

    if not stream? and is_integer(max_tokens) and max_tokens > @non_streaming_max_tokens do
      warning =
        "Fireworks rejects non-streaming requests with max_tokens > #{@non_streaming_max_tokens}; capping to #{@non_streaming_max_tokens}"

      {Keyword.put(opts, :max_tokens, @non_streaming_max_tokens), [warning]}
    else
      {opts, []}
    end
  end

  defp render_reasoning_effort(nil), do: nil
  defp render_reasoning_effort(:default), do: nil
  defp render_reasoning_effort(:none), do: "none"
  defp render_reasoning_effort(:minimal), do: "low"
  defp render_reasoning_effort(:low), do: "low"
  defp render_reasoning_effort(:medium), do: "medium"
  defp render_reasoning_effort(:high), do: "high"
  defp render_reasoning_effort(:xhigh), do: "xhigh"
  defp render_reasoning_effort(:max), do: "max"
  defp render_reasoning_effort(value) when is_binary(value), do: value
  defp render_reasoning_effort(other), do: other

  @doc """
  Custom encode_body wrapper that delegates body construction to `build_body/1`
  and serialises the result with the default OpenAI-compatible JSON encoder.
  """
  @impl ReqLLM.Provider
  def encode_body(request) do
    body = build_body(request)
    ReqLLM.Provider.Defaults.encode_body_from_map(request, body)
  end

  @doc """
  Custom body building that adds Fireworks-specific extensions to the default
  OpenAI-compatible format.

  Normalises tool_choice to OpenAI's `function` shape, strips message-level
  fields Fireworks rejects on assistant turns (`metadata`,
  `reasoning_details`, `reasoning_content`), renders `reasoning_effort`
  atoms to the strings Fireworks expects, and forwards the full
  Fireworks-specific parameter surface (sampling, prompt cache keys,
  speculation, response_format, etc.). `stream_options.include_usage` is
  added by `default_build_body/1` for streaming requests.
  """
  @impl ReqLLM.Provider
  def build_body(request) do
    ReqLLM.Provider.Defaults.default_build_body(request)
    |> ReqLLM.Providers.OpenAI.AdapterHelpers.translate_tool_choice_format()
    |> strip_rejected_message_fields()
    |> maybe_put(:reasoning_effort, fireworks_reasoning_effort(request))
    |> maybe_put(:prompt_cache_key, request.options[:prompt_cache_key])
    |> maybe_put(:prompt_cache_isolation_key, request.options[:prompt_cache_isolation_key])
    |> maybe_put(:prompt_truncate_len, request.options[:prompt_truncate_len])
    |> maybe_put(:safe_tokenization, request.options[:safe_tokenization])
    |> maybe_put(:min_p, request.options[:min_p])
    |> maybe_put(:repetition_penalty, request.options[:repetition_penalty])
    |> maybe_put(:typical_p, request.options[:typical_p])
    |> maybe_put(:mirostat_target, request.options[:mirostat_target])
    |> maybe_put(:mirostat_lr, request.options[:mirostat_lr])
    |> maybe_put(:perf_metrics_in_response, request.options[:perf_metrics_in_response])
    |> maybe_put(:raw_output, request.options[:raw_output])
    |> maybe_put(:speculation, request.options[:speculation])
    |> maybe_put(:prediction, request.options[:prediction])
    |> maybe_put(:metadata, request.options[:metadata])
    |> maybe_put(:parallel_tool_calls, request.options[:parallel_tool_calls])
    |> maybe_put(:max_completion_tokens, request.options[:max_completion_tokens])
    |> maybe_put(:response_format, request.options[:response_format])
  end

  # Fireworks's strict OpenAI-compat envelope rejects anything outside the
  # documented message shape. Three fields commonly survive round-tripping
  # from prior responses and cause HTTP 400s on the next turn:
  #
  #   * `metadata` — present on tool messages that round-trip non-string
  #     tool results through ReqLLM
  #   * `reasoning_details` — the OpenRouter-shaped reasoning trace that
  #     ResponseBuilder.Defaults attaches to every assistant message
  #   * `reasoning_content` — the OpenAI-compat reasoning string that
  #     thinking-content parts encode for OpenAI-style providers
  #
  # Strip all three from outbound messages so multi-turn conversations
  # don't blow up the second the model emits a reasoning preamble.
  @rejected_message_keys [
    :metadata,
    "metadata",
    :reasoning_details,
    "reasoning_details",
    :reasoning_content,
    "reasoning_content"
  ]

  defp strip_rejected_message_fields(%{messages: messages} = body) when is_list(messages) do
    %{body | messages: Enum.map(messages, &drop_rejected_fields/1)}
  end

  defp strip_rejected_message_fields(%{"messages" => messages} = body) when is_list(messages) do
    Map.put(body, "messages", Enum.map(messages, &drop_rejected_fields/1))
  end

  defp strip_rejected_message_fields(body), do: body

  defp drop_rejected_fields(message) when is_map(message) do
    Map.drop(message, @rejected_message_keys)
  end

  defp hoist_provider_option(opts, provider_key) do
    provider_opts = Keyword.get(opts, :provider_options, [])

    case Keyword.fetch(provider_opts, provider_key) do
      {:ok, value} ->
        provider_opts = Keyword.delete(provider_opts, provider_key)

        opts
        |> Keyword.put(provider_key, value)
        |> put_provider_options(provider_opts)

      :error ->
        opts
    end
  end

  defp rename_provider_option(opts, provider_key, target_key) do
    provider_opts = Keyword.get(opts, :provider_options, [])

    case Keyword.fetch(provider_opts, provider_key) do
      {:ok, value} ->
        provider_opts =
          provider_opts
          |> Keyword.delete(provider_key)
          |> Keyword.put(target_key, value)

        Keyword.put(opts, :provider_options, provider_opts)

      :error ->
        opts
    end
  end

  defp put_provider_options(opts, []), do: Keyword.delete(opts, :provider_options)

  defp put_provider_options(opts, provider_opts),
    do: Keyword.put(opts, :provider_options, provider_opts)

  defp option_value(opts, provider_opts, key, default) do
    case Keyword.fetch(provider_opts, key) do
      {:ok, value} -> value
      :error -> Keyword.get(opts, key, default)
    end
  end

  defp fireworks_reasoning_effort(request) do
    request.options[:fireworks_reasoning_effort] ||
      render_reasoning_effort(request.options[:reasoning_effort])
  end
end
