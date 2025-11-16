defmodule PetalPro.AI.OpenAI do
  def chat_stream(messages, opts \\ []) do
    api_key = System.get_env("OPENAI_API_KEY")

    unless api_key do
      {:error, "OPENAI_API_KEY not set"}
    else
      ReqLLM.put_key(:openai_api_key, api_key)

      model = Keyword.get(opts, :model, "gpt-4o-mini")
      temperature = Keyword.get(opts, :temperature, 0.7)
      model_spec = "openai:#{model}"

      case ReqLLM.stream_text(model_spec, messages,
             temperature: temperature) do
        {:ok, stream_response} ->
          token_stream = ReqLLM.StreamResponse.tokens(stream_response)
          {:ok, token_stream}

        {:error, error} ->
          {:error, "Request failed: #{inspect(error)}"}
      end
    end
  end
end
