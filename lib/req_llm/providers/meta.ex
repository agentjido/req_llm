defmodule ReqLLM.Providers.Meta do
  @moduledoc """
  Generic Meta Llama provider implementing Meta's native prompt format.

  Handles Meta's Llama models (Llama 3, 3.1, 3.2, 3.3, 4) using the native
  Llama prompt format and request/response structure.

  ## Usage Note

  **Most cloud providers and self-hosted deployments wrap Llama models in
  OpenAI-compatible APIs** and should delegate to `ReqLLM.Providers.OpenAI`
  instead of this module:

  - Azure AI Foundry - Uses OpenAI-compatible API
  - Google Cloud Vertex AI - Uses OpenAI-compatible API
  - vLLM (self-hosted) - Uses OpenAI-compatible API
  - Ollama (self-hosted) - Uses OpenAI-compatible API
  - llama.cpp (self-hosted) - Uses OpenAI-compatible API

  This module is for providers that use Meta's **native format** with
  `prompt`, `max_gen_len`, `generation`, etc. Currently this is primarily:

  - AWS Bedrock - Uses native Meta format via `ReqLLM.Providers.AmazonBedrock.Meta`

  ## Native Request Format

  Llama's native format uses a single prompt string with special tokens:
  - `prompt` - Formatted text with special tokens (required)
  - `max_gen_len` - Maximum tokens to generate
  - `temperature` - Sampling temperature
  - `top_p` - Nucleus sampling parameter

  ## Native Response Format

  - `generation` - The generated text
  - `prompt_token_count` - Input token count
  - `generation_token_count` - Output token count
  - `stop_reason` - Why generation stopped

  ## Llama Prompt Format

  Llama 3+ uses a structured prompt format with special tokens:
  - System messages: `<|start_header_id|>system<|end_header_id|>`
  - User messages: `<|start_header_id|>user<|end_header_id|>`
  - Assistant messages: `<|start_header_id|>assistant<|end_header_id|>`

  ## Cloud Provider Integration

  Cloud providers using the native format should wrap this module's functions
  with their specific auth/endpoint handling. See `ReqLLM.Providers.AmazonBedrock.Meta`
  as an example.
  """

  @doc """
  Formats a ReqLLM context into Meta Llama request format.

  Converts structured messages into Llama 3's prompt format and returns
  a map with the prompt and optional parameters.

  ## Options

    * `:max_tokens` - Maximum tokens to generate (mapped to `max_gen_len`)
    * `:temperature` - Sampling temperature
    * `:top_p` - Nucleus sampling parameter

  ## Examples

      context = %ReqLLM.Context{
        messages: [
          %{role: :user, content: "Hello!"}
        ]
      }

      ReqLLM.Providers.Meta.format_request(context, max_tokens: 100)
      # => %{
      #   "prompt" => "<|begin_of_text|><|start_header_id|>user<|end_header_id|>\\n\\nHello!<|eot_id|>...",
      #   "max_gen_len" => 100
      # }
  """
  def format_request(context, opts \\ []) do
    prompt = format_llama_prompt(context.messages)

    %{
      "prompt" => prompt
    }
    |> maybe_add_param("max_gen_len", opts[:max_tokens])
    |> maybe_add_param("temperature", opts[:temperature])
    |> maybe_add_param("top_p", opts[:top_p])
  end

  defp maybe_add_param(map, _key, nil), do: map
  defp maybe_add_param(map, key, value), do: Map.put(map, key, value)

  @doc """
  Formats messages into Llama 3 prompt format.

  Format: `<|begin_of_text|><|start_header_id|>role<|end_header_id|>\\ncontent<|eot_id|>`

  ## Examples

      messages = [
        %{role: :system, content: "You are helpful"},
        %{role: :user, content: "Hello"}
      ]

      ReqLLM.Providers.Meta.format_llama_prompt(messages)
      # => "<|begin_of_text|><|start_header_id|>system<|end_header_id|>\\n\\nYou are helpful<|eot_id|>..."
  """
  def format_llama_prompt(messages) do
    formatted =
      messages
      |> Enum.map_join("", &format_message/1)

    # Start with begin token and end with assistant header
    "<|begin_of_text|>#{formatted}<|start_header_id|>assistant<|end_header_id|>\n\n"
  end

  defp format_message(%{role: role, content: content}) when is_binary(content) do
    "<|start_header_id|>#{role}<|end_header_id|>\n\n#{content}<|eot_id|>"
  end

  defp format_message(%{role: role, content: content}) when is_list(content) do
    # Handle content blocks (text, images, etc.)
    text =
      content
      |> Enum.filter(&(&1.type == :text))
      |> Enum.map_join("\n", & &1.text)

    "<|start_header_id|>#{role}<|end_header_id|>\n\n#{text}<|eot_id|>"
  end

  @doc """
  Parses Meta Llama response into ReqLLM format.

  Expects a response body with:
  - `"generation"` - The generated text
  - `"prompt_token_count"` - Input token count (optional)
  - `"generation_token_count"` - Output token count (optional)
  - `"stop_reason"` - Why generation stopped (optional)

  ## Examples

      body = %{
        "generation" => "Hello! How can I help?",
        "prompt_token_count" => 10,
        "generation_token_count" => 5,
        "stop_reason" => "stop"
      }

      ReqLLM.Providers.Meta.parse_response(body, model: "meta.llama3")
      # => {:ok, %ReqLLM.Response{...}}
  """
  def parse_response(body, opts) when is_map(body) do
    with {:ok, generation} <- Map.fetch(body, "generation"),
         {:ok, usage} <- extract_usage(body) do
      # Create assistant message with text content
      message = %ReqLLM.Message{
        role: :assistant,
        content: [
          %ReqLLM.Message.ContentPart{
            type: :text,
            text: generation
          }
        ]
      }

      # Create context with the new message
      context = %ReqLLM.Context{
        messages: [message]
      }

      response = %ReqLLM.Response{
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
      }

      {:ok, response}
    else
      :error -> {:error, "Invalid response format: missing required fields"}
      {:error, _} -> {:error, "Invalid response format"}
    end
  end

  @doc """
  Extracts usage metadata from the response body.

  Looks for `prompt_token_count` and `generation_token_count` fields.

  ## Examples

      body = %{
        "prompt_token_count" => 10,
        "generation_token_count" => 5
      }

      ReqLLM.Providers.Meta.extract_usage(body)
      # => {:ok, %{input_tokens: 10, output_tokens: 5, total_tokens: 15, ...}}
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

      _ ->
        {:error, :no_usage}
    end
  end

  def extract_usage(_), do: {:error, :no_usage}

  @doc """
  Parses stop reason from Meta's response format.

  Maps Meta's stop reasons to ReqLLM's standard finish reasons:
  - `"stop"` → `:stop`
  - `"length"` → `:length`
  - anything else → `:stop`
  """
  def parse_stop_reason("stop"), do: :stop
  def parse_stop_reason("length"), do: :length
  def parse_stop_reason(_), do: :stop

  defp generate_id do
    "llama-#{:erlang.system_time(:millisecond)}-#{:rand.uniform(1000)}"
  end
end
