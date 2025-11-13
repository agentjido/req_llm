defmodule ReqLLM.ModelHelpers do
  @moduledoc """
  Helper functions for working with LLMDB.Model structs.

  Provides convenience predicates for checking model capabilities,
  bridging the gap between LLMDB's nested capability structure
  and ReqLLM's usage patterns.
  """

  @doc "Returns true if model supports tool/function calling"
  @spec tool_calls?(LLMDB.Model.t()) :: boolean()
  def tool_calls?(%LLMDB.Model{} = model) do
    get_in(model.capabilities, [:tools, :enabled]) || false
  end

  @doc "Returns true if model supports reasoning/thinking tokens"
  @spec reasoning?(LLMDB.Model.t()) :: boolean()
  def reasoning?(%LLMDB.Model{} = model) do
    get_in(model.capabilities, [:reasoning, :enabled]) || false
  end

  @doc "Returns true if model supports temperature parameter"
  @spec temperature?(LLMDB.Model.t()) :: boolean()
  def temperature?(%LLMDB.Model{} = model) do
    not reasoning?(model)
  end

  @doc "Returns true if model supports attachments (non-text input modalities)"
  @spec attachments?(LLMDB.Model.t()) :: boolean()
  def attachments?(%LLMDB.Model{} = model) do
    case get_in(model.modalities, [:input]) do
      nil ->
        false

      modalities when is_list(modalities) ->
        Enum.any?(modalities, &(&1 in [:image, :audio, :video, :pdf]))

      _ ->
        false
    end
  end

  @doc "Returns true if model supports streaming text generation"
  @spec streaming_text?(LLMDB.Model.t()) :: boolean()
  def streaming_text?(%LLMDB.Model{} = model) do
    get_in(model.capabilities, [:streaming, :text]) != false
  end

  @doc "Returns true if model supports streaming tool calls"
  @spec streaming_tools?(LLMDB.Model.t()) :: boolean()
  def streaming_tools?(%LLMDB.Model{} = model) do
    get_in(model.capabilities, [:streaming, :tool_calls]) || false
  end

  @doc "Returns true if model supports JSON schema output"
  @spec json_schema?(LLMDB.Model.t()) :: boolean()
  def json_schema?(%LLMDB.Model{} = model) do
    get_in(model.capabilities, [:json, :schema]) || false
  end

  @doc "Returns true if model supports strict JSON schema enforcement"
  @spec strict_json?(LLMDB.Model.t()) :: boolean()
  def strict_json?(%LLMDB.Model{} = model) do
    get_in(model.capabilities, [:json, :strict]) || false
  end
end
