defmodule ReqLLM.Providers.Cerebras do
  @moduledoc """
  Cerebras provider – OpenAI-compatible Chat Completions API with ultra-fast inference.

  ## Implementation

  Uses built-in OpenAI-style encoding/decoding defaults with Cerebras-specific adjustments.

  ## Cerebras-Specific Notes

  - System messages have stronger influence compared to OpenAI's implementation
  - Streaming not supported with reasoning models in JSON mode or tool calling
  - `strict: true` is automatically added to tool schemas when the model supports it
  - Models that don't support `strict: true` (e.g., Qwen, ZAI GLM models) have it automatically excluded
  - Supports OpenAI-style tool calling, including `tool_choice: "auto"`, `"none"`, `"required"`, and function-specific choice objects
  - Supports `parallel_tool_calls` to control whether tools can be requested concurrently

  ## Unsupported OpenAI Features

  The following fields will result in a 400 error if supplied:
  - `frequency_penalty`
  - `logit_bias`
  - `presence_penalty`

  ## Configuration

      # Add to .env file (automatically loaded)
      CEREBRAS_API_KEY=csk_...
  """

  use ReqLLM.Provider,
    id: :cerebras,
    default_base_url: "https://api.cerebras.ai/v1",
    default_env_key: "CEREBRAS_API_KEY"

  import ReqLLM.Provider.Utils, only: [maybe_put: 3]

  @provider_schema []

  @impl ReqLLM.Provider
  def encode_body(request) do
    body = build_body(request)
    ReqLLM.Provider.Defaults.encode_body_from_map(request, body)
  end

  @impl ReqLLM.Provider
  def build_body(request) do
    model = request.private[:req_llm_model]

    ReqLLM.Provider.Defaults.default_build_body(request)
    |> ReqLLM.Providers.OpenAI.AdapterHelpers.translate_tool_choice_format()
    |> add_strict_to_tools(model)
    |> maybe_put(:parallel_tool_calls, request.options[:parallel_tool_calls])
    |> normalize_assistant_content()
  end

  defp add_strict_to_tools(%{"tools" => tools} = body, model) when is_list(tools) do
    tools =
      if supports_strict_tools?(model) do
        Enum.map(tools, &put_strict_in_tool/1)
      else
        Enum.map(tools, &strip_unsupported_schema_constraints/1)
      end

    Map.put(body, "tools", tools)
  end

  defp add_strict_to_tools(%{tools: tools} = body, model) when is_list(tools) do
    tools =
      if supports_strict_tools?(model) do
        Enum.map(tools, &put_strict_in_tool/1)
      else
        Enum.map(tools, &strip_unsupported_schema_constraints/1)
      end

    Map.put(body, :tools, tools)
  end

  defp add_strict_to_tools(body, _model), do: body

  defp put_strict_in_tool(%{"function" => _} = tool) do
    put_in(tool, ["function", "strict"], true)
  end

  defp put_strict_in_tool(%{function: _} = tool) do
    put_in(tool, [:function, :strict], true)
  end

  defp put_strict_in_tool(tool), do: tool

  defp supports_strict_tools?(%LLMDB.Model{} = model) do
    ReqLLM.ModelHelpers.tools_strict?(model)
  end

  defp supports_strict_tools?(_), do: false

  defp strip_unsupported_schema_constraints(%{"function" => _} = tool) do
    update_in(tool, ["function", "parameters"], fn params ->
      if is_map(params) do
        strip_constraints_recursive(params)
      else
        params
      end
    end)
  end

  defp strip_unsupported_schema_constraints(%{function: _} = tool) do
    update_in(tool, [:function, :parameters], fn params ->
      if is_map(params) do
        strip_constraints_recursive(params)
      else
        params
      end
    end)
  end

  defp strip_unsupported_schema_constraints(tool), do: tool

  defp strip_constraints_recursive(schema) when is_map(schema) do
    schema
    |> Map.drop(["minimum", "maximum", "minLength", "maxLength"])
    |> Map.new(fn
      {"properties", props} when is_map(props) ->
        {"properties", Map.new(props, fn {k, v} -> {k, strip_constraints_recursive(v)} end)}

      {k, v} when is_map(v) ->
        {k, strip_constraints_recursive(v)}

      {k, v} ->
        {k, v}
    end)
  end

  defp strip_constraints_recursive(value), do: value

  defp normalize_assistant_content(%{"messages" => messages} = body) when is_list(messages) do
    normalized_messages = Enum.map(messages, &normalize_assistant_message/1)
    Map.put(body, "messages", normalized_messages)
  end

  defp normalize_assistant_content(%{messages: messages} = body) when is_list(messages) do
    normalized_messages = Enum.map(messages, &normalize_assistant_message/1)
    Map.put(body, :messages, normalized_messages)
  end

  defp normalize_assistant_content(body), do: body

  defp normalize_assistant_message(%{"role" => "assistant", "content" => []} = message) do
    Map.put(message, "content", "")
  end

  defp normalize_assistant_message(%{role: "assistant", content: []} = message) do
    Map.put(message, :content, "")
  end

  defp normalize_assistant_message(%{"role" => :assistant, "content" => []} = message) do
    Map.put(message, "content", "")
  end

  defp normalize_assistant_message(%{role: :assistant, content: []} = message) do
    Map.put(message, :content, "")
  end

  defp normalize_assistant_message(message), do: message
end
