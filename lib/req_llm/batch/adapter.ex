defmodule ReqLLM.Batch.Adapter do
  @moduledoc """
  Extension behaviour for provider-managed batch inference.

  Hosting providers opt in through `c:ReqLLM.Provider.batch_adapter/0`. Each
  adapter defines the input reference, job options, and output format used by
  its service. Adapters for services without a JSONL input or output format
  can omit the corresponding codec callback.
  """

  alias ReqLLM.Batch.Job

  @doc "Encodes independent records into the provider's JSONL wire format."
  @callback encode_jsonl(LLMDB.Model.t(), Enumerable.t(), keyword()) ::
              {:ok, iodata()} | {:error, term()}

  @doc "Submits input to the hosting provider and returns its durable job identity."
  @callback submit(LLMDB.Model.t(), term(), keyword()) :: {:ok, Job.t()} | {:error, term()}

  @doc "Fetches status and output metadata for a previously submitted job."
  @callback status(Job.t(), keyword()) :: {:ok, Job.t()} | {:error, term()}

  @doc "Requests cancellation where the provider supports it."
  @callback cancel(Job.t(), keyword()) :: :ok | {:error, term()}

  @doc "Lazily decodes output lines into `t:ReqLLM.Batch.result/0` tuples."
  @callback decode_jsonl(LLMDB.Model.t(), Enumerable.t()) ::
              {:ok, Enumerable.t()} | {:error, term()}

  @optional_callbacks encode_jsonl: 3, decode_jsonl: 2, cancel: 2
end
