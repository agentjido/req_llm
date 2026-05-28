defmodule ReqLLM.Providers.Ollama do
  @moduledoc """
  Ollama provider — local LLM inference via Ollama's OpenAI-compatible API.

  Routes to Ollama's `/v1` endpoint (port 11434 by default). No API key required.

  ## Usage

      # In jido_ai model alias config
      config :jido_ai, model_aliases: [default: "ollama:gemma4:27b"]

      # Direct usage
      ReqLLM.generate_text("ollama:llama3", "Hello!")
      ReqLLM.generate_object("ollama:llama3", "Extract the name", schema)

  ## Configuration

      # Optional — defaults to http://localhost:11434/v1
      config :req_llm, :ollama, base_url: "http://my-ollama-host:11434/v1"

  ## Ollama-Specific Options

  Pass via `provider_options:` keyword:

  - `num_ctx` — context window size in tokens (Ollama `options.num_ctx`)
  - `keep_alive` — how long to keep model loaded, e.g. `"30m"` or `0` to unload immediately

  ## Examples

      ReqLLM.generate_text("ollama:gemma4:27b", "Hello",
        provider_options: [num_ctx: 16_384, keep_alive: "30m"]
      )
  """

  use ReqLLM.Provider,
    id: :ollama,
    default_base_url: "http://localhost:11434/v1"

  use ReqLLM.Provider.Defaults

  @provider_schema [
    num_ctx: [
      type: :non_neg_integer,
      doc: "Context window size in tokens (passed as options.num_ctx in Ollama body)"
    ],
    keep_alive: [
      type: {:or, [:string, :non_neg_integer]},
      doc: "How long to keep model loaded (e.g. \"30m\", 0). Top-level body field."
    ],
    response_format: [
      type: :map,
      doc: "Response format configuration for Ollama's OpenAI-compatible API"
    ]
  ]

  @impl ReqLLM.Provider
  def prepare_request(:object, model_spec, prompt, opts) do
    compiled_schema = Keyword.fetch!(opts, :compiled_schema)
    schema_name = Map.get(compiled_schema, :name, "structured_output")

    response_format = %{
      type: "json_schema",
      json_schema: %{
        name: schema_name,
        schema: ReqLLM.Schema.to_json(compiled_schema.schema)
      }
    }

    opts_with_format =
      opts
      |> Keyword.update(:provider_options, [response_format: response_format], fn provider_opts ->
        Keyword.put(provider_opts, :response_format, response_format)
      end)
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

  def prepare_request(operation, model_spec, input, opts) do
    ReqLLM.Provider.Defaults.prepare_request(__MODULE__, operation, model_spec, input, opts)
  end

  @doc """
  Attaches Ollama-specific pipeline steps.

  Unlike OpenAI-compatible providers, Ollama does not require authentication.
  This override skips the `Authorization: Bearer` header entirely so users
  do not need to set any API key environment variable.
  """
  @impl ReqLLM.Provider
  def attach(request, model_input, user_opts) do
    {:ok, %LLMDB.Model{} = model} = ReqLLM.model(model_input)

    if model.provider != provider_id() do
      raise ReqLLM.Error.Invalid.Provider.exception(provider: model.provider)
    end

    extra_keys = ReqLLM.Provider.Defaults.extra_option_keys(__MODULE__)

    request
    |> Req.Request.put_header("content-type", "application/json")
    |> Req.Request.register_options(extra_keys)
    |> Req.Request.merge_options(
      ReqLLM.Provider.Defaults.finch_option(request) ++
        [model: model.provider_model_id || model.id] ++ user_opts
    )
    |> ReqLLM.Step.Retry.attach()
    |> ReqLLM.Step.Error.attach()
    |> Req.Request.append_request_steps(llm_encode_body: &encode_body/1)
    |> Req.Request.append_response_steps(llm_decode_response: &decode_response/1)
    |> ReqLLM.Step.Usage.attach(model)
    |> ReqLLM.Step.Telemetry.attach(model, user_opts)
    |> ReqLLM.Step.Fixture.maybe_attach(model, user_opts)
  end

  @impl ReqLLM.Provider
  def attach_stream(model, context, opts, _finch_name) do
    operation = opts[:operation] || :chat

    processed_opts =
      ReqLLM.Provider.Options.process_stream!(__MODULE__, operation, model, context, opts)

    base_url = ReqLLM.Provider.Options.effective_base_url(__MODULE__, model, processed_opts)
    url = endpoint_url(base_url, "/chat/completions")
    body = encode_stream_body(model, context, processed_opts)

    headers =
      [{"Content-Type", "application/json"}, {"Accept", "text/event-stream"}] ++
        ReqLLM.Provider.Utils.extract_custom_headers(processed_opts[:req_http_options])

    {:ok, Finch.build(:post, url, headers, body)}
  rescue
    error ->
      {:error,
       ReqLLM.Error.API.Request.exception(
         reason: "Failed to build Ollama stream request: #{inspect(error)}"
       )}
  end

  @doc """
  Builds the Ollama request body.

  Extends the standard OpenAI-compat body with two Ollama-specific fields:
  - `options.num_ctx` — nested under the `options` map (Ollama model parameter)
  - `keep_alive` — top-level field controlling how long the model stays loaded
  """
  @impl ReqLLM.Provider
  def build_body(request) do
    ReqLLM.Provider.Defaults.default_build_body(request)
    |> maybe_add_num_ctx(request.options[:num_ctx])
    |> maybe_add_keep_alive(request.options[:keep_alive])
  end

  defp maybe_add_num_ctx(body, nil), do: body
  defp maybe_add_num_ctx(body, num_ctx), do: Map.put(body, :options, %{num_ctx: num_ctx})

  defp maybe_add_keep_alive(body, nil), do: body
  defp maybe_add_keep_alive(body, keep_alive), do: Map.put(body, :keep_alive, keep_alive)

  defp encode_stream_body(model, context, opts) do
    req_opts =
      opts
      |> Keyword.delete(:finch_name)
      |> Keyword.put(:model, model.provider_model_id || model.id)
      |> Keyword.put(:context, context)
      |> Keyword.put(:stream, true)

    request =
      Req.new(method: :post, url: "http://localhost")
      |> Req.Request.register_options(
        ReqLLM.Provider.Defaults.extra_option_keys(__MODULE__) ++ [:context, :operation]
      )
      |> Req.Request.merge_options(req_opts)

    request
    |> encode_body()
    |> Map.fetch!(:body)
  end

  defp endpoint_url(base_url, path) do
    String.trim_trailing(base_url, "/") <> path
  end
end
