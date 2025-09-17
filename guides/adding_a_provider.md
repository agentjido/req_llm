# Adding a new provider to **ReqLLM**

_Rev. 2025-02 – ReqLLM 1.0.0-rc.1_

## Developer checklist

The checklist is now split in two.  
Pick **ONE** column depending on what the remote API looks like.

| Fast path – OpenAI compatible               | Advanced path – custom protocol                     |
|---------------------------------------------|-----------------------------------------------------|
| ☑  `lib/req_llm/providers/<provider>.ex`    | ☑  `lib/req_llm/providers/<provider>.ex`            |
| ☑  `priv/models_dev/<provider>.json`        | ☑  `priv/models_dev/<provider>.json`                |
| ☐  unit tests / live fixtures               | ☐  unit tests / live fixtures                       |
| _No extra modules needed_                   | ☐  `context.ex` implementing `ReqLLM.Context.Codec` |
|                                             | ☐  `response.ex` implementing `ReqLLM.Response.Codec`|

Why the split? 95% of new providers on the market expose a "Chat Completions"
endpoint that is 1-for-1 wire-compatible with OpenAI.  
For those you can reuse the generic `ReqLLM.Context.Codec` /
`ReqLLM.Response.Codec` implementations and skip two entire modules.

---

## Overview

This guide shows both approaches:

1. Minimal OpenAI-style implementation (same pattern used by the **Groq** provider).  
2. Opting-in to custom codecs when the remote JSON deviates.  
3. Leveraging `prepare_request/4` for multi-operation providers (chat, completions, embeddings, images …).

---

## 1. Provider module – **minimal skeleton (OpenAI-compatible)**

```
lib/req_llm/providers/my_openai.ex
```

```elixir
defmodule ReqLLM.Providers.MyOpenAI do
  @moduledoc """
  MyOpenAI – fully OpenAI-compatible Chat Completions API.
  """

  @behaviour ReqLLM.Provider

  use ReqLLM.Provider.DSL,
    id: :my_openai,
    base_url: "https://api.my-openai.com/v1",
    metadata: "priv/models_dev/my_openai.json",
    default_env_key: "MY_OPENAI_API_KEY",
    # generic codecs are used – nothing else to configure
    provider_schema: [
      # Only list options that **do not** exist in the OpenAI spec
      organisation_id: [type: :string, doc: "Optional tenant id"]
    ]

  import ReqLLM.Provider.Utils,
    only: [prepare_options!: 3, maybe_put: 3, maybe_put_skip: 4, ensure_parsed_body: 1]

  # ---------------------------------------------------------------------------
  # 1️⃣  prepare_request/4 – operation dispatcher
  # ---------------------------------------------------------------------------

  @impl ReqLLM.Provider
  def prepare_request(:chat, model_input, %ReqLLM.Context{} = ctx, opts) do
    with {:ok, model} <- ReqLLM.Model.from(model_input) do
      req =
        Req.new(url: "/chat/completions", method: :post, receive_timeout: 30_000)
        |> attach(model, Keyword.put(opts, :context, ctx))

      {:ok, req}
    end
  end

  # Example of a second, non-Chat operation (optional)
  def prepare_request(:embeddings, model_input, _ctx, opts) do
    with {:ok, model} <- ReqLLM.Model.from(model_input) do
      Req.new(url: "/embeddings", method: :post, receive_timeout: 30_000)
      |> attach(model, opts)
      |> then(&{:ok, &1})
    end
  end

  def prepare_request(op, _, _, _),
    do:
      {:error,
       ReqLLM.Error.Invalid.Parameter.exception(
         parameter: "operation #{inspect(op)} not supported"
       )}

  # ---------------------------------------------------------------------------
  # 2️⃣  attach/3 – validation, option handling, Req pipeline
  # ---------------------------------------------------------------------------

  @impl ReqLLM.Provider
  def attach(%Req.Request{} = request, model_input, user_opts \\ []) do
    %ReqLLM.Model{} = model = ReqLLM.Model.from!(model_input)
    if model.provider != provider_id(), do: raise ReqLLM.Error.Invalid.Provider, provider: model.provider

    api_key = ReqLLM.Keys.get!(model, user_opts)

    {tools, other_opts} = Keyword.pop(user_opts, :tools, [])
    {provider_opts, core_opts} = Keyword.pop(other_opts, :provider_options, [])

    opts =
      model
      |> prepare_options!(__MODULE__, core_opts)
      |> Keyword.put(:tools, tools)
      |> Keyword.merge(provider_opts)

    base_url = Keyword.get(user_opts, :base_url, default_base_url())
    req_keys = __MODULE__.supported_provider_options() ++ [:context]

    request
    |> Req.Request.register_options(req_keys ++ [:model])
    |> Req.Request.merge_options(
      Keyword.take(opts, req_keys) ++
        [model: model.model, base_url: base_url, auth: {:bearer, api_key}]
    )
    |> ReqLLM.Step.Error.attach()
    |> Req.Request.append_request_steps(llm_encode_body: &__MODULE__.encode_body/1)
    |> ReqLLM.Step.Stream.maybe_attach(opts[:stream])
    |> Req.Request.append_response_steps(llm_decode_response: &__MODULE__.decode_response/1)
    |> ReqLLM.Step.Usage.attach(model)
  end

  # ---------------------------------------------------------------------------
  # 3️⃣  encode_body – still needed (adds provider-specific extras)
  # ---------------------------------------------------------------------------

  @impl ReqLLM.Provider
  def encode_body(req) do
    context_json =
      case req.options[:context] do
        %ReqLLM.Context{} = ctx -> ReqLLM.Context.Codec.encode_request(ctx, req.options[:model])
        _ -> %{messages: req.options[:messages] || []}
      end

    body =
      %{
        model: req.options[:model]
      }
      |> Map.merge(context_json)
      |> maybe_put(:temperature, req.options[:temperature])
      |> maybe_put(:max_tokens, req.options[:max_tokens])
      |> maybe_put_skip(:organisation_id, req.options[:organisation_id], [nil])
      |> maybe_put(:stream, req.options[:stream])
      |> maybe_put(:tools, req.options[:tools] |> tools_to_openai_schema())

    req
    |> Req.Request.put_header("content-type", "application/json")
    |> Map.put(:body, Jason.encode!(body))
  end

  defp tools_to_openai_schema([]), do: nil
  defp tools_to_openai_schema(list), do: Enum.map(list, &ReqLLM.Tool.to_schema(&1, :openai))

  # ---------------------------------------------------------------------------
  # 4️⃣  decode_response – generic OpenAI codec does 99%
  # ---------------------------------------------------------------------------

  @impl ReqLLM.Provider
  def decode_response({req, resp}) do
    case resp.status do
      200 ->
        {:ok, response} =
          resp.body
          |> ensure_parsed_body()
          |> ReqLLM.Response.Codec.decode_response(%ReqLLM.Model{provider: provider_id(), model: req.options[:model]})

        {req, %{resp | body: response}}

      status ->
        err =
          ReqLLM.Error.API.Response.exception(
            reason: "MyOpenAI API error",
            status: status,
            response_body: resp.body
          )

        {req, err}
    end
  end

  # Usage extraction is identical to Groq / OpenAI
  @impl ReqLLM.Provider
  def extract_usage(%{"usage" => u}, _), do: {:ok, u}
  def extract_usage(_, _), do: {:error, :no_usage}
end
```

### Five lines you no longer need

```
context_wrapper: ...,
response_wrapper: ...,
defmodule ReqLLM.Providers.MyOpenAI.Context do ...
defmodule ReqLLM.Providers.MyOpenAI.Response do ...
ReqLLM.Context.Codec/Response.Codec implementations
```

---

## 2. Provider module – **custom protocol skeleton (when not OpenAI-ish)**

If the remote JSON schema is _not_ OpenAI-style you can still use the older
pattern (context + response codecs).  
The existing section "2. Context & Response codec modules" in the previous
guide is unchanged and now lives in **adding_a_provider_custom.md** to keep
this document focused.

---

## 3. Multi-operation providers & `prepare_request/4`

`prepare_request/4` may be invoked for several atoms:

• `:chat`  – ChatCompletions  
• `:embeddings`  
• `:completion` (legacy)  
• `:images` / `:audio_transcription` / …

You decide which are supported.  
Return `{:error, ...}` for the others just like in the example above.

For OpenAI-style endpoints the encode/decode helpers are almost identical;
only the path (`/embeddings`, `/audio/transcriptions`, …) changes. Feel free
to extract a small helper like `build_request_path/1`.

---

## 4. Capability metadata (`priv/models_dev/<provider>.json`)

No change – see the Groq file for reference.

---

## 5. Capability testing

Identical process. Focus on the cheapest, deterministic model, use
`temperature: 0`, and record fixtures with `LIVE=true`.

---

## 6. Best practices recap

• Prefer the **fast** OpenAI pattern – fewer lines, fewer bugs.  
• Move logic into `attach/3`; keep `prepare_request/4` a thin dispatcher.  
• `provider_schema` is **only** for fields outside the OpenAI spec.  
• Use `ReqLLM.Keys` – never read `System.get_env/1` directly.  
• Do not ship custom codecs unless you must: they double your test surface.  
• Start small, add streaming, tools, vision, etc. incrementally.

---

Welcome to ReqLLM 1.0 – shipping a new provider is now a coffee-break task ☕🚀
