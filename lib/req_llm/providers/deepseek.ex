defmodule ReqLLM.Providers.Deepseek do
  @moduledoc """
  DeepSeek AI provider – OpenAI-compatible Chat Completions API.

  ## Implementation

  Uses built-in OpenAI-style encoding/decoding defaults.
  DeepSeek is fully OpenAI-compatible, so no custom request/response handling is needed.

  ## Authentication

  Requires a DeepSeek API key from https://platform.deepseek.com/

  ## Configuration

      # Add to .env file (automatically loaded)
      DEEPSEEK_API_KEY=your-api-key

  ## Examples

      # Basic usage
      ReqLLM.generate_text("deepseek:deepseek-chat", "Hello!")

      # With custom parameters
      ReqLLM.generate_text("deepseek:deepseek-reasoner", "Write a function",
        temperature: 0.2,
        max_tokens: 2000
      )

      # Streaming
      ReqLLM.stream_text("deepseek:deepseek-chat", "Tell me a story")
      |> Enum.each(&IO.write/1)

      # With thinking mode enabled (default for reasoning models)
      ReqLLM.generate_text("deepseek:deepseek-v4-pro", "Solve this complex problem",
        reasoning_effort: :high,
        provider_options: [
          thinking: %{type: "enabled"}
        ]
      )

      # With maximum reasoning effort for complex tasks
      ReqLLM.generate_text("deepseek:deepseek-v4-pro", "Complex reasoning task",
        reasoning_effort: :xhigh
      )

      # Disable thinking mode
      ReqLLM.generate_text("deepseek:deepseek-v4-pro", "Quick question",
        provider_options: [
          thinking: %{type: "disabled"}
        ]
      )

  ## Models

  DeepSeek offers several models including:

  - `deepseek-chat` - General purpose conversational model
  - `deepseek-reasoner` - Reasoning and problem-solving
  - `deepseek-v4-flash` - Fast reasoning model with lower latency
  - `deepseek-v4-pro` - Latest reasoning model with thinking support

  ## Thinking Mode

  DeepSeek models support thinking mode for improved reasoning.

  See [DeepSeek Thinking Mode Guide](https://api-docs.deepseek.com/guides/thinking_mode) for details.

  ### Options

  - `thinking: %{type: "enabled"}` - Enable thinking mode (default for reasoning models)
  - `thinking: %{type: "disabled"}` - Disable thinking mode

  ### Reasoning Effort

  The `reasoning_effort` option controls the depth of reasoning. For compatibility,
  `:low` and `:medium` are mapped to `"high"`, and `:xhigh` is mapped to `"max"`.

  Only `"high"` and `"max"` are the meaningful values sent to the API:

  - `:low` → mapped to `"high"`
  - `:medium` → mapped to `"high"`
  - `:high` → `"high"` (default for thinking mode)
  - `:xhigh` → mapped to `"max"` (maximum effort for complex tasks)

  See https://platform.deepseek.com/docs for full model documentation.
  """

  use ReqLLM.Provider,
    id: :deepseek,
    default_base_url: "https://api.deepseek.com",
    default_env_key: "DEEPSEEK_API_KEY"

  use ReqLLM.Provider.Defaults

  import ReqLLM.Provider.Utils, only: [maybe_put: 3]

  @provider_schema [
    thinking: [
      type: :map,
      doc: """
      Thinking mode configuration. Set to %{type: "enabled"} to enable or %{type: "disabled"} to disable.
      Defaults to enabled for reasoning models. See https://api-docs.deepseek.com/guides/thinking_mode
      """
    ]
  ]

  @impl ReqLLM.Provider
  def translate_options(_operation, _model, opts) do
    {reasoning_effort, opts} = Keyword.pop(opts, :reasoning_effort)

    opts =
      case reasoning_effort do
        :low -> Keyword.put(opts, :reasoning_effort, "high")
        :medium -> Keyword.put(opts, :reasoning_effort, "high")
        :high -> Keyword.put(opts, :reasoning_effort, "high")
        :xhigh -> Keyword.put(opts, :reasoning_effort, "max")
        nil -> opts
        other when is_binary(other) -> Keyword.put(opts, :reasoning_effort, other)
        other -> Keyword.put(opts, :reasoning_effort, to_string(other))
      end

    {opts, []}
  end

  @impl ReqLLM.Provider
  def build_body(request) do
    provider_opts = request.options[:provider_options] || []

    ReqLLM.Provider.Defaults.default_build_body(request)
    |> ensure_assistant_reasoning_content()
    |> maybe_put(:thinking, normalize_thinking(provider_opts[:thinking]))
    |> maybe_put(:reasoning_effort, request.options[:reasoning_effort])
  end

  defp ensure_assistant_reasoning_content(body) do
    case get_messages(body) do
      nil ->
        body

      messages when is_list(messages) ->
        key = messages_key(body)
        Map.put(body, key, Enum.map(messages, &add_reasoning_content_to_message/1))
    end
  end

  defp add_reasoning_content_to_message(msg) do
    if assistant_message?(msg) and not has_reasoning_content?(msg) do
      Map.put(msg, :reasoning_content, "")
    else
      msg
    end
  end

  defp get_messages(%{messages: msgs}), do: msgs
  defp get_messages(%{"messages" => msgs}), do: msgs
  defp get_messages(_), do: nil

  defp messages_key(%{messages: _}), do: :messages
  defp messages_key(%{"messages" => _}), do: "messages"

  defp assistant_message?(msg) when is_map(msg) do
    Map.get(msg, :role) == "assistant" or Map.get(msg, "role") == "assistant"
  end

  defp assistant_message?(_msg), do: false

  defp has_reasoning_content?(msg) when is_map(msg) do
    Map.has_key?(msg, :reasoning_content) or Map.has_key?(msg, "reasoning_content")
  end

  defp normalize_thinking(nil), do: nil

  defp normalize_thinking(%{type: type} = thinking) when is_atom(type),
    do: %{thinking | type: to_string(type)}

  defp normalize_thinking(thinking) when is_map(thinking), do: thinking
end
