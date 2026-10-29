defmodule ReqLLM.Test.JSONCodecStub do
  @moduledoc """
  JSON codec that delegates to Jason and records every call.

  Set `Application.put_env(:req_llm, :json_codec_stub_pid, self())` to receive
  `{:json_codec, operation, payload}` messages.
  """

  @behaviour ReqLLM.JSON.Codec

  def encode!(term) do
    record(:encode!, term)
    Jason.encode!(term)
  end

  def encode_to_iodata!(term) do
    record(:encode_to_iodata!, term)
    Jason.encode_to_iodata!(term)
  end

  def decode(json) do
    record(:decode, json)
    Jason.decode(json)
  end

  def decode!(json) do
    record(:decode!, json)
    Jason.decode!(json)
  end

  def decode_error_position(%Jason.DecodeError{position: position}), do: position
  def decode_error_position(_error), do: nil

  defp record(operation, payload) do
    case Application.get_env(:req_llm, :json_codec_stub_pid) do
      pid when is_pid(pid) -> send(pid, {:json_codec, operation, payload})
      _ -> :ok
    end
  end
end
