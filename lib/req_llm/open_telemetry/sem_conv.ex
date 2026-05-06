defmodule ReqLLM.OpenTelemetry.SemConv do
  @moduledoc false

  @provider_names %{
    amazon_bedrock: "aws.bedrock",
    anthropic: "anthropic",
    azure: "azure.ai.openai",
    deepseek: "deepseek",
    google: "gcp.gen_ai",
    google_vertex: "gcp.vertex_ai",
    groq: "groq",
    openai: "openai",
    xai: "x_ai"
  }

  @output_types %{
    chat: "text",
    object: "json",
    image: "image",
    speech: "speech",
    transcription: "text"
  }

  @operation_names %{
    chat: "chat",
    embedding: "embeddings",
    image: "generate_content",
    object: "chat"
  }

  @spec provider_name(any()) :: String.t() | nil
  def provider_name(nil), do: nil

  def provider_name(provider) when is_atom(provider) do
    Map.get(@provider_names, provider, Atom.to_string(provider))
  end

  def provider_name(provider) when is_binary(provider), do: provider
  def provider_name(_), do: nil

  @spec operation_name(any()) :: String.t()
  def operation_name(nil), do: "chat"

  def operation_name(operation) when is_atom(operation) do
    Map.get(@operation_names, operation, Atom.to_string(operation))
  end

  def operation_name(operation) when is_binary(operation), do: operation
  def operation_name(operation), do: inspect(operation)

  @spec output_type(any()) :: String.t() | nil
  def output_type(operation) when is_atom(operation), do: Map.get(@output_types, operation)
  def output_type(_), do: nil

  @spec span_name(any(), String.t() | nil) :: String.t()
  def span_name(operation, model_id) when is_binary(model_id) and model_id != "" do
    "#{operation_name(operation)} #{model_id}"
  end

  def span_name(operation, _model_id), do: operation_name(operation)
end
