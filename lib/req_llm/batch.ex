defmodule ReqLLM.Batch do
  @moduledoc """
  Submits and manages provider-hosted batches of independent generation requests.

  Amazon Bedrock is the first adapter. See the [Bedrock guide](amazon_bedrock.html#batch-inference)
  for the text-only Converse workflow using caller-staged S3 files.
  """

  alias ReqLLM.Error

  defmodule Job do
    @moduledoc """
    A provider-hosted batch job. Persist `provider` and `id` to resume it later.

    `status` preserves the provider's status string, and `output` is the provider's
    output reference, such as an S3 URI. A provider may return either field only
    when queried. `message` carries any provider-reported job details.
    """

    @type t :: %__MODULE__{
            provider: atom(),
            id: String.t(),
            status: String.t() | nil,
            output: String.t() | nil,
            message: String.t() | nil
          }

    @enforce_keys [:provider, :id]
    defstruct [:provider, :id, :status, :output, :message]
  end

  @typedoc "A caller-chosen record ID and a prompt accepted by `ReqLLM.Context.normalize/2`."
  @type record_entry :: {String.t(), ReqLLM.Context.prompt()}

  @typedoc "A decoded response or error with its record ID, when the ID is available."
  @type result :: {String.t() | nil, {:ok, ReqLLM.Response.t()} | {:error, Exception.t()}}

  @doc """
  Reports whether LLMDB marks a model as batch-capable and its provider has a
  batch adapter. This is a discovery helper. Explicit submission is available
  for models whose metadata is incomplete, and service eligibility is decided
  by the provider in the job's region.
  """
  @spec supported?(ReqLLM.static_model_input()) :: boolean()
  def supported?(model_spec) do
    with {:ok, %{provider: provider, capabilities: %{batch: %{supported: true}}}} <-
           ReqLLM.model(model_spec),
         {:ok, _adapter} <- adapter(provider, :submit, 3) do
      true
    else
      _ -> false
    end
  end

  @doc """
  Encodes `{record_id, prompt}` entries as newline-terminated JSONL iodata.

  The adapter validates all records before returning the iodata. For Bedrock,
  common Converse inference settings can be supplied via `:max_tokens`,
  `:temperature`, `:top_p`, and `:stop`.
  """
  @spec encode_jsonl(ReqLLM.static_model_input(), Enumerable.t(), keyword()) ::
          {:ok, iodata()} | {:error, term()}
  def encode_jsonl(model_spec, records, opts \\ []) do
    with {:ok, model} <- ReqLLM.model(model_spec),
         {:ok, adapter} <- adapter(model.provider, :encode_jsonl, 3) do
      adapter.encode_jsonl(model, records, opts)
    end
  end

  @doc """
  Submits staged input and returns a job. The input reference and options are
  defined by the hosting provider. Bedrock takes an S3 URI.
  """
  @spec submit(ReqLLM.static_model_input(), term(), keyword()) ::
          {:ok, Job.t()} | {:error, term()}
  def submit(model_spec, input, opts) do
    with {:ok, model} <- ReqLLM.model(model_spec),
         {:ok, adapter} <- adapter(model.provider, :submit, 3) do
      adapter.submit(model, input, opts)
    end
  end

  @doc "Fetches current job status and output details using the job's saved identity."
  @spec status(Job.t(), keyword()) :: {:ok, Job.t()} | {:error, term()}
  def status(%Job{provider: provider} = job, opts \\ []) do
    with {:ok, adapter} <- adapter(provider, :status, 2), do: adapter.status(job, opts)
  end

  @doc "Requests cancellation. Use `status/2` to check when the job has stopped."
  @spec cancel(Job.t(), keyword()) :: :ok | {:error, term()}
  def cancel(%Job{provider: provider} = job, opts \\ []) do
    with {:ok, adapter} <- adapter(provider, :cancel, 2), do: adapter.cancel(job, opts)
  end

  @doc """
  Lazily decodes an enumerable of complete JSONL lines, such as `File.stream!/1`.

  Each row yields `{record_id, {:ok, response}}` or `{record_id, {:error, error}}`.
  Rows without a readable ID use `nil`. Results are in file order and should be
  correlated by ID. Pass the same model spec used for submission.
  """
  @spec decode_jsonl(ReqLLM.static_model_input(), Enumerable.t()) ::
          {:ok, Enumerable.t()} | {:error, term()}
  def decode_jsonl(model_spec, lines) do
    with {:ok, model} <- ReqLLM.model(model_spec),
         {:ok, adapter} <- adapter(model.provider, :decode_jsonl, 2) do
      adapter.decode_jsonl(model, lines)
    end
  end

  defp adapter(provider, callback, arity) do
    with {:ok, module} <- ReqLLM.provider(provider),
         true <- function_exported?(module, :batch_adapter, 0),
         adapter = module.batch_adapter(),
         true <- Code.ensure_loaded?(adapter) and function_exported?(adapter, callback, arity) do
      {:ok, adapter}
    else
      false ->
        {:error, Error.Invalid.NotImplemented.exception(feature: "#{provider} batch #{callback}")}

      {:error, _} = error ->
        error
    end
  end
end
