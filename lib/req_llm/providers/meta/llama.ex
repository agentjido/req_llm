defmodule ReqLLM.Providers.Meta.Llama do
  @moduledoc """
  Meta Llama native-payload helpers used by Amazon Bedrock.

  Bedrock's native Llama endpoint uses a formatted `prompt`, `max_gen_len`,
  `generation`, and token-count fields instead of Meta's OpenAI-compatible
  Model API envelope.
  """

  @doc """
  Formats a ReqLLM context into Meta's native Llama request format.
  """
  def format_request(context, opts \\ []) do
    %{"prompt" => format_llama_prompt(context.messages)}
    |> maybe_add_param("max_gen_len", opts[:max_tokens])
    |> maybe_add_param("temperature", opts[:temperature])
    |> maybe_add_param("top_p", opts[:top_p])
  end

  @doc """
  Formats messages using the Llama 3 prompt token convention.
  """
  def format_llama_prompt(messages) do
    formatted = Enum.map_join(messages, "", &format_message/1)

    "<|begin_of_text|>#{formatted}<|start_header_id|>assistant<|end_header_id|>\n\n"
  end

  @doc """
  Parses a native Llama response into a ReqLLM response.
  """
  def parse_response(body, opts) when is_map(body) do
    with {:ok, generation} <- Map.fetch(body, "generation"),
         {:ok, usage} <- extract_usage(body) do
      message = %ReqLLM.Message{
        role: :assistant,
        content: [%ReqLLM.Message.ContentPart{type: :text, text: generation}]
      }

      context = %ReqLLM.Context{messages: [message]}

      {:ok,
       %ReqLLM.Response{
         id: generate_id(),
         model: opts[:model] || "meta.llama",
         context: context,
         message: message,
         stream?: false,
         stream: nil,
         usage: usage,
         finish_reason: parse_stop_reason(body["stop_reason"]),
         provider_meta:
           Map.drop(body, [
             "generation",
             "prompt_token_count",
             "generation_token_count",
             "stop_reason"
           ])
       }}
    else
      :error -> {:error, "Invalid response format: missing required fields"}
      {:error, _reason} -> {:error, "Invalid response format"}
    end
  end

  @doc """
  Extracts token usage from a native Llama response.
  """
  def extract_usage(body) when is_map(body) do
    case {Map.get(body, "prompt_token_count"), Map.get(body, "generation_token_count")} do
      {input, output} when is_integer(input) and is_integer(output) ->
        {:ok,
         %{
           input_tokens: input,
           output_tokens: output,
           total_tokens: input + output,
           cached_tokens: 0,
           reasoning_tokens: 0
         }}

      _other ->
        {:error, :no_usage}
    end
  end

  def extract_usage(_body), do: {:error, :no_usage}

  @doc """
  Normalizes Meta's native stop reason.
  """
  def parse_stop_reason("stop"), do: :stop
  def parse_stop_reason("length"), do: :length
  def parse_stop_reason(_reason), do: :stop

  defp format_message(%{role: role, content: content}) when is_binary(content) do
    "<|start_header_id|>#{role}<|end_header_id|>\n\n#{content}<|eot_id|>"
  end

  defp format_message(%{role: role, content: content}) when is_list(content) do
    text =
      content
      |> Enum.filter(&(&1.type == :text))
      |> Enum.map_join("\n", & &1.text)

    "<|start_header_id|>#{role}<|end_header_id|>\n\n#{text}<|eot_id|>"
  end

  defp maybe_add_param(map, _key, nil), do: map
  defp maybe_add_param(map, key, value), do: Map.put(map, key, value)

  defp generate_id do
    "llama-#{:erlang.system_time(:millisecond)}-#{:rand.uniform(1000)}"
  end
end
