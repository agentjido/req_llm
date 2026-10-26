defmodule ReqLLM.Providers.Inference do
  @moduledoc """
  Inference.net provider for serverless and custom models.

  Inference.net exposes an OpenAI-compatible Chat Completions API at
  `https://api.inference.net/v1`. Set `INFERENCE_API_KEY` or pass `:api_key`
  to authenticate.

  The provider supports text generation, streaming, function calling,
  native JSON Schema output, vision, and the reasoning effort levels that
  each catalog model declares. Optional task, environment, and metadata
  values are sent as Inference.net observability headers.

  Use `base_url: "https://us.api.inference.net/v1"` when requests must use
  the US-only endpoint.

      ReqLLM.generate_text("inference:glm-5.3-flash", "Hello")

      ReqLLM.stream_text("inference:deepseek-v4.1-flash-1017", "Solve this",
        reasoning_effort: :high,
        provider_options: [
          inference_environment: "development",
          inference_task_id: "reqllm-example"
        ]
      )
  """

  use ReqLLM.Provider,
    id: :inference,
    default_base_url: "https://api.inference.net/v1",
    default_env_key: "INFERENCE_API_KEY"

  import ReqLLM.Provider.Utils, only: [maybe_put: 3]

  @reasoning_efforts [:none, :minimal, :low, :medium, :high, :xhigh, :max]
  @provider_schema [
    response_format: [
      type: :map,
      doc: "OpenAI-compatible JSON object or JSON Schema response format"
    ],
    service_tier: [
      type: :string,
      doc: "Inference.net service tier, such as priority or fast"
    ],
    reasoning: [
      type: :map,
      doc: "Inference.net reasoning configuration, such as %{enabled: false}"
    ],
    verbosity: [
      type: {:in, ~w(low medium high)},
      doc: "Visible answer length for models that support verbosity"
    ],
    inference_environment: [
      type: :string,
      doc: "Environment label sent in x-inference-environment"
    ],
    inference_task_id: [
      type: :string,
      doc: "Task identifier sent in x-inference-task-id"
    ],
    inference_metadata: [
      type: :map,
      doc: "Metadata sent as x-inference-metadata-* headers"
    ]
  ]

  @doc false
  def display_name, do: "Inference.net"

  @impl ReqLLM.Provider
  def prepare_request(:object, model_spec, prompt, opts) do
    compiled_schema = Keyword.fetch!(opts, :compiled_schema)

    response_format = %{
      type: "json_schema",
      json_schema: %{
        name: Map.get(compiled_schema, :name, "structured_output"),
        strict: true,
        schema:
          compiled_schema.schema
          |> ReqLLM.Schema.to_json()
          |> ReqLLM.Providers.OpenAI.AdapterHelpers.enforce_strict_recursive()
      }
    }

    opts =
      opts
      |> put_base_url(model_spec)
      |> Keyword.put(:response_format, response_format)
      |> ReqLLM.Provider.Options.put_model_max_tokens_default(model_spec, fallback: 4096)
      |> Keyword.put(:operation, :object)

    ReqLLM.Provider.Defaults.prepare_request(__MODULE__, :chat, model_spec, prompt, opts)
  end

  def prepare_request(operation, _model_spec, _input, _opts)
      when operation in [:embedding, :transcription, :speech, :image, :video] do
    {:error,
     ReqLLM.Error.Invalid.Parameter.exception(
       parameter: "Inference.net does not support operation #{inspect(operation)} in ReqLLM"
     )}
  end

  def prepare_request(operation, model_spec, input, opts) do
    ReqLLM.Provider.Defaults.prepare_request(
      __MODULE__,
      operation,
      model_spec,
      input,
      put_base_url(opts, model_spec)
    )
  end

  @impl ReqLLM.Provider
  def attach(request, model, opts) do
    ReqLLM.Provider.Defaults.default_attach(__MODULE__, request, model, opts)
    |> put_observability_headers(opts)
  end

  @impl ReqLLM.Provider
  def attach_stream(model, context, opts, finch_name) do
    opts = put_base_url(opts, model)

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

  @impl ReqLLM.Provider
  def translate_options(_operation, _model, opts) do
    {reasoning_token_budget, opts} = Keyword.pop(opts, :reasoning_token_budget)
    {reasoning_effort, opts} = Keyword.pop(opts, :reasoning_effort)

    opts =
      opts
      |> maybe_put_reasoning_effort(reasoning_effort)
      |> Keyword.put_new(:receive_timeout, 300_000)

    warnings =
      if reasoning_token_budget do
        [
          "Inference.net uses reasoning_effort; removed unsupported reasoning_token_budget."
        ]
      else
        []
      end

    {opts, warnings}
  end

  @impl ReqLLM.Provider
  def build_body(request) do
    request
    |> ReqLLM.Provider.Defaults.default_build_body()
    |> ReqLLM.Providers.OpenAI.AdapterHelpers.translate_tool_choice_format()
    |> maybe_put(:reasoning_effort, wire_reasoning_effort(request.options[:reasoning_effort]))
    |> maybe_put(:reasoning, request.options[:reasoning])
    |> maybe_put(:service_tier, request.options[:service_tier])
    |> maybe_put(:verbosity, request.options[:verbosity])
    |> maybe_put(:response_format, request.options[:response_format])
  end

  @doc false
  def streaming_http(_model, api_key, opts) do
    %{
      path: "/chat/completions",
      headers:
        [
          {"Authorization", "Bearer " <> api_key},
          {"Content-Type", "application/json"}
        ] ++ observability_headers(opts)
    }
  end

  defp maybe_put_reasoning_effort(opts, nil), do: opts
  defp maybe_put_reasoning_effort(opts, :default), do: opts

  defp maybe_put_reasoning_effort(opts, effort) when effort in @reasoning_efforts,
    do: Keyword.put(opts, :reasoning_effort, effort)

  defp wire_reasoning_effort(nil), do: nil
  defp wire_reasoning_effort(:default), do: nil
  defp wire_reasoning_effort(effort) when effort in @reasoning_efforts, do: Atom.to_string(effort)

  defp put_observability_headers(request, opts) do
    Enum.reduce(observability_headers(opts), request, fn {name, value}, req ->
      Req.Request.put_header(req, name, value)
    end)
  end

  defp observability_headers(opts) do
    []
    |> maybe_add_header("x-inference-environment", option(opts, :inference_environment))
    |> maybe_add_header("x-inference-task-id", option(opts, :inference_task_id))
    |> Kernel.++(metadata_headers(option(opts, :inference_metadata)))
  end

  defp metadata_headers(nil), do: []

  defp metadata_headers(metadata) when is_map(metadata) do
    metadata
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map(fn {key, value} ->
      key = key |> to_string() |> String.downcase()
      value = header_value!(value, "inference_metadata.#{key}")

      if Regex.match?(~r/^[a-z0-9][a-z0-9-]*$/, key) do
        {"x-inference-metadata-" <> key, value}
      else
        raise ReqLLM.Error.Invalid.Parameter,
          parameter: "inference_metadata keys must contain only letters, digits, and hyphens"
      end
    end)
  end

  defp maybe_add_header(headers, _name, nil), do: headers

  defp maybe_add_header(headers, name, value) do
    headers ++ [{name, header_value!(value, name)}]
  end

  defp header_value!(value, name)
       when is_binary(value) or is_number(value) or is_boolean(value) do
    value = to_string(value)

    if String.contains?(value, ["\r", "\n"]) do
      raise ReqLLM.Error.Invalid.Parameter,
        parameter: "#{name} must not contain a line break"
    end

    value
  end

  defp header_value!(_value, name) do
    raise ReqLLM.Error.Invalid.Parameter,
      parameter: "#{name} must be a string, number, or boolean"
  end

  defp option(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> value
      :error -> provider_option(opts[:provider_options], key)
    end
  end

  defp provider_option(options, key) when is_list(options), do: Keyword.get(options, key)

  defp provider_option(options, key) when is_map(options) do
    Map.get(options, key) || Map.get(options, Atom.to_string(key))
  end

  defp provider_option(_options, _key), do: nil

  defp put_base_url(opts, model) do
    Keyword.put_new_lazy(opts, :base_url, fn ->
      model_base_url(model) || configured_base_url() || default_base_url()
    end)
  end

  defp model_base_url(%{base_url: "https://inference.net/v1"}), do: nil
  defp model_base_url(%{base_url: base_url}) when is_binary(base_url), do: base_url
  defp model_base_url(_model), do: nil

  defp configured_base_url do
    case Application.get_env(:req_llm, :inference, []) do
      config when is_list(config) -> Keyword.get(config, :base_url)
      config when is_map(config) -> Map.get(config, :base_url) || Map.get(config, "base_url")
      _config -> nil
    end
  end
end
