defmodule ReqLLM.Providers.AmazonBedrock.Response do
  @moduledoc """
  Shared utilities for unwrapping AWS Bedrock response formats.

  Bedrock wraps provider responses in AWS-specific formats (base64 encoding, event streams).
  This module handles the Bedrock-specific unwrapping so provider modules can work with
  native provider formats.
  """

  defstruct [:payload]
  @type t :: %__MODULE__{payload: term()}

  @doc """
  Unwraps a Bedrock streaming chunk into the underlying provider event format.

  Bedrock can wrap events in several formats:
  - `%{"chunk" => %{"bytes" => base64}}` - AWS SDK format
  - `%{"bytes" => base64}` - Direct bytes format
  - `%{"type" => ...}` - Already decoded JSON event

  Returns the unwrapped event as a map, or an error tuple.
  """
  @spec unwrap_stream_chunk(map()) :: {:ok, map()} | {:error, term()}
  def unwrap_stream_chunk(chunk) when is_map(chunk) do
    case chunk do
      %{"chunk" => %{"bytes" => encoded}} ->
        # AWS SDK format: chunk wrapper with base64-encoded content
        decoded = Base.decode64!(encoded)
        {:ok, Jason.decode!(decoded)}

      %{"bytes" => encoded} ->
        # Direct bytes format: base64-encoded provider events
        decoded = Base.decode64!(encoded)
        {:ok, Jason.decode!(decoded)}

      %{"type" => _} = event ->
        # Direct JSON event (already decoded by AWS event stream parser)
        {:ok, event}

      _ ->
        # Unknown format
        {:error, :unknown_chunk_format}
    end
  rescue
    e -> {:error, {:unwrap_failed, e}}
  end
end
