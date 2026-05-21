defmodule ReqLLM.Providers.NearAI do
  @moduledoc """
  NEAR AI Cloud provider using the OpenAI-compatible Chat Completions API.

  NEAR AI Cloud exposes TEE-backed inference through an OpenAI-compatible
  endpoint at `https://cloud-api.near.ai/v1`. ReqLLM reuses the shared OpenAI
  wire-format implementation and adds NEAR-specific compatibility handling:

  - `max_completion_tokens` is translated to `max_tokens`
  - unsupported reasoning options are removed before the request is sent
  - strict tool schemas are sent without OpenAI's `strict` marker

  ## Configuration

      NEARAI_API_KEY=your-api-key

  ## Examples

      ReqLLM.generate_text("nearai:anthropic/claude-haiku-4-5", "Hello!")

      ReqLLM.stream_text("nearai:openai/gpt-5.4-mini", "Tell me a story",
        max_tokens: 512
      )
  """

  use ReqLLM.Provider,
    id: :nearai,
    default_base_url: "https://cloud-api.near.ai/v1",
    default_env_key: "NEARAI_API_KEY"

  use ReqLLM.Provider.Defaults

  @provider_schema [
    max_completion_tokens: [
      type: :pos_integer,
      doc:
        "Alias for max_tokens. NEAR AI Cloud expects the OpenAI Chat Completions max_tokens field."
    ]
  ]

  @doc false
  def display_name, do: "NEAR AI Cloud"

  @impl ReqLLM.Provider
  def translate_options(_operation, _model, opts) do
    warnings = []

    {max_completion_tokens, opts} = Keyword.pop(opts, :max_completion_tokens)
    {opts, warnings} = translate_max_completion_tokens(max_completion_tokens, opts, warnings)
    {opts, warnings} = drop_unsupported_reasoning_options(opts, warnings)

    {opts, Enum.reverse(warnings)}
  end

  @impl ReqLLM.Provider
  def build_body(request) do
    request
    |> ReqLLM.Provider.Defaults.default_build_body()
    |> put_max_completion_alias(request.options)
    |> strip_strict_from_tools()
  end

  defp translate_max_completion_tokens(nil, opts, warnings), do: {opts, warnings}

  defp translate_max_completion_tokens(max_completion_tokens, opts, warnings) do
    if Keyword.has_key?(opts, :max_tokens) do
      {opts,
       [
         "NEAR AI Cloud expects max_tokens; ignored max_completion_tokens because max_tokens is set."
         | warnings
       ]}
    else
      {Keyword.put(opts, :max_tokens, max_completion_tokens),
       [
         "NEAR AI Cloud expects max_tokens; translated max_completion_tokens to max_tokens."
         | warnings
       ]}
    end
  end

  defp drop_unsupported_reasoning_options(opts, warnings) do
    {reasoning_effort, opts} = Keyword.pop(opts, :reasoning_effort)
    {reasoning_token_budget, opts} = Keyword.pop(opts, :reasoning_token_budget)

    warnings =
      if reasoning_effort && reasoning_effort != :default do
        [
          "NEAR AI Cloud does not support reasoning_effort; removed it from the request."
          | warnings
        ]
      else
        warnings
      end

    warnings =
      if reasoning_token_budget do
        [
          "NEAR AI Cloud does not expose reasoning_token_budget on the OpenAI-compatible endpoint."
          | warnings
        ]
      else
        warnings
      end

    {opts, warnings}
  end

  defp put_max_completion_alias(body, options) do
    cond do
      Map.has_key?(body, :max_tokens) or Map.has_key?(body, "max_tokens") ->
        body

      options[:max_completion_tokens] ->
        Map.put(body, :max_tokens, options[:max_completion_tokens])

      true ->
        body
    end
  end

  defp strip_strict_from_tools(%{tools: tools} = body) when is_list(tools) do
    %{body | tools: Enum.map(tools, &strip_tool_strict/1)}
  end

  defp strip_strict_from_tools(%{"tools" => tools} = body) when is_list(tools) do
    %{body | "tools" => Enum.map(tools, &strip_tool_strict/1)}
  end

  defp strip_strict_from_tools(body), do: body

  defp strip_tool_strict(%{"function" => function} = tool) when is_map(function) do
    %{tool | "function" => Map.delete(function, "strict")}
  end

  defp strip_tool_strict(%{function: function} = tool) when is_map(function) do
    %{tool | function: function |> Map.delete(:strict) |> Map.delete("strict")}
  end

  defp strip_tool_strict(tool), do: tool
end
