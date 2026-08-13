defmodule ReqLLM.Video do
  @moduledoc """
  Video generation functionality for ReqLLM.

  Video generation is asynchronous: `generate_video/3` submits a task and
  returns a `ReqLLM.Video.Task` with a `task_id`, `query_video/3` polls the
  task status, and `wait_video/3` polls until the task reaches a terminal
  state (`:succeeded`, `:failed`, or `:cancelled`).

  ## Content input

  The `content` argument is a keyword list describing the multimodal input:

    * `:prompt` - required text prompt describing the video
    * `:first_frame_image` - URL of the first-frame image (image-to-video)
    * `:last_frame_image` - URL of the last-frame image (image-to-video)
    * `:reference_images` - list of reference image URLs (reference-to-video)
    * `:reference_videos` - list of reference video URLs (reference-to-video)
    * `:reference_audio` - list of reference audio URLs (reference-to-video)

  ## Examples

      {:ok, task} =
        ReqLLM.Video.generate_video("minimax:MiniMax-H3",
          [prompt: "A boy playing basketball by the sea",
           first_frame_image: "https://example.com/frame.png"],
          duration: 5,
          resolution: "2K"
        )

      {:ok, task} = ReqLLM.Video.wait_video("minimax:MiniMax-H3", task.task_id)
  """

  alias LLMDB.Model

  @terminal_statuses [:succeeded, :failed, :cancelled]

  @base_schema NimbleOptions.new!(
                 duration: [
                   type: :pos_integer,
                   doc:
                     "Duration of the generated video in seconds (provider dependent, e.g. 4-15)"
                 ],
                 resolution: [
                   type: :string,
                   doc: ~s(Output resolution, e.g. "768P" or "2K")
                 ],
                 ratio: [
                   type: :string,
                   doc:
                     ~s(Aspect ratio, e.g. "16:9" or "adaptive". Required for text-to-video; defaults to "adaptive" otherwise.)
                 ],
                 callback_url: [
                   type: :string,
                   doc: "Optional callback URL for task status changes (provider dependent)"
                 ],
                 provider_options: [
                   type: {:or, [:map, {:list, :any}]},
                   doc: "Provider-specific options (keyword list or map)",
                   default: []
                 ],
                 req_http_options: [
                   type: {:or, [:map, {:list, :any}]},
                   doc: "Req-specific options (keyword list or map)",
                   default: []
                 ],
                 telemetry: [
                   type: {:or, [:map, {:list, :any}]},
                   doc: "ReqLLM telemetry options (for example, [payloads: :raw])",
                   default: []
                 ],
                 receive_timeout: [
                   type: :pos_integer,
                   doc: "Timeout for receiving HTTP responses in milliseconds"
                 ],
                 total_timeout: [
                   type: {:or, [:pos_integer, {:in, [:infinity]}]},
                   doc: "Optional total model-call timeout in milliseconds, including retries"
                 ],
                 max_retries: [
                   type: :non_neg_integer,
                   default: 3,
                   doc:
                     "Maximum number of retry attempts for transient network errors. Set to 0 to disable retries."
                 ],
                 on_unsupported: [
                   type: {:in, [:warn, :error, :ignore]},
                   default: :warn,
                   doc: "How to handle provider option translation warnings"
                 ],
                 fixture: [
                   type: {:or, [:string, {:tuple, [:atom, :string]}]},
                   doc: "HTTP fixture for testing (provider inferred from model if string)"
                 ]
               )

  @doc """
  Returns the base video generation options schema.
  """
  @spec schema :: NimbleOptions.t()
  def schema, do: @base_schema

  defmodule Task do
    @moduledoc """
    A video generation task.

    Returned by `generate_video/3` and `query_video/3`. `status` is one of
    `:queued`, `:running`, `:succeeded`, `:failed`, or `:cancelled`. `url` is
    populated once the task succeeds; `error` carries the provider error message
    when the task fails.
    """

    @enforce_keys [:task_id]
    defstruct task_id: nil,
              status: :queued,
              url: nil,
              file_id: nil,
              error: nil,
              model: nil,
              provider: nil,
              provider_meta: %{}

    @type t :: %__MODULE__{
            task_id: String.t(),
            status: :queued | :running | :succeeded | :failed | :cancelled,
            url: String.t() | nil,
            file_id: String.t() | nil,
            error: String.t() | nil,
            model: String.t() | nil,
            provider: atom() | nil,
            provider_meta: map()
          }
  end

  defmodule File do
    @moduledoc """
    A resolved video file.

    Returned by `retrieve_file/3` for V1 providers, where a succeeded task
    carries a `file_id` that must be resolved to a time-limited download URL.
    """

    @enforce_keys [:file_id]
    defstruct file_id: nil,
              url: nil,
              filename: nil,
              bytes: nil,
              purpose: nil,
              provider_meta: %{}

    @type t :: %__MODULE__{
            file_id: String.t() | integer(),
            url: String.t() | nil,
            filename: String.t() | nil,
            bytes: integer() | nil,
            purpose: String.t() | nil,
            provider_meta: map()
          }
  end

  @doc """
  Submits a video generation task.

  Returns `{:ok, %ReqLLM.Video.Task{}}` with the provider `task_id`, or
  `{:error, term()}`. The task runs asynchronously; poll with `query_video/3`
  or block until completion with `wait_video/3`.
  """
  @spec generate_video(ReqLLM.model_input(), keyword(), keyword()) ::
          {:ok, Task.t()} | {:error, term()}
  def generate_video(model_spec, content, opts \\ []) do
    opts = ReqLLM.ModelInput.merge_tuple_defaults(model_spec, :video, opts)
    deadline = ReqLLM.TimeoutBudget.deadline(opts)

    with {:ok, model} <- ReqLLM.model(model_spec),
         {:ok, provider_module} <- ReqLLM.provider(model.provider),
         {:ok, opts} <-
           ReqLLM.Provider.Options.normalize_namespaced_provider_options(
             provider_module,
             :video,
             model,
             opts
           ),
         {:ok, content} <- maybe_upload_content(model, content, opts),
         {:ok, request} <- provider_module.prepare_request(:video, model, content, opts),
         {:ok, %Req.Response{status: status, body: %Task{} = task}} when status in 200..299 <-
           ReqLLM.TimeoutBudget.request(request, deadline) do
      {:ok, task}
    else
      {:ok, %Req.Response{status: status, body: body}} ->
        {:error,
         ReqLLM.Error.API.Request.exception(
           reason: "HTTP #{status}: Request failed",
           status: status,
           response_body: body
         )}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Queries the status of a video generation task by `task_id`.

  Returns `{:ok, %ReqLLM.Video.Task{}}` with the current status; `url` is
  populated once the task succeeds on V2 providers, `file_id` on V1 providers.
  """
  @spec query_video(ReqLLM.model_input(), String.t(), keyword()) ::
          {:ok, Task.t()} | {:error, term()}
  def query_video(model_spec, task_id, opts \\ []) do
    opts = ReqLLM.ModelInput.merge_tuple_defaults(model_spec, :video, opts)
    deadline = ReqLLM.TimeoutBudget.deadline(opts)

    with {:ok, model} <- ReqLLM.model(model_spec),
         {:ok, provider_module} <- ReqLLM.provider(model.provider),
         {:ok, request} <- provider_module.prepare_request(:video_query, model, task_id, opts),
         {:ok, %Req.Response{status: status, body: %Task{} = task}} when status in 200..299 <-
           ReqLLM.TimeoutBudget.request(request, deadline) do
      {:ok, task}
    else
      {:ok, %Req.Response{status: status, body: body}} ->
        {:error,
         ReqLLM.Error.API.Request.exception(
           reason: "HTTP #{status}: Request failed",
           status: status,
           response_body: body
         )}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Polls a video generation task until it reaches a terminal state.

  Polls every `:poll_interval` milliseconds (default 10s) until the task
  succeeds, fails, or is cancelled, or until `:timeout` milliseconds (default
  10 minutes) elapse.

  This function blocks the calling process for the duration of the wait. For
  production use, prefer persisting the `task_id` and polling with
  `query_video/3` from a background process.

  Transient query errors (network timeouts, connection resets) are retried up
  to `:max_transient_retries` times (default 3) before giving up; the task
  itself keeps running server-side and can be polled again later.

  For V1 providers (e.g. `MiniMax-Hailuo-2.3`) the succeeded task carries a
  `file_id` instead of a `url`; resolve it with `retrieve_file/3`.
  """
  @spec wait_video(ReqLLM.model_input(), String.t(), keyword()) ::
          {:ok, Task.t()} | {:error, term()}
  def wait_video(model_spec, task_id, opts \\ []) do
    {poll_interval, opts} = Keyword.pop(opts, :poll_interval, 10_000)
    {timeout, opts} = Keyword.pop(opts, :timeout, 600_000)
    {max_transient_retries, opts} = Keyword.pop(opts, :max_transient_retries, 3)
    deadline = System.monotonic_time(:millisecond) + timeout

    with {:ok, model} <- ReqLLM.model(model_spec),
         {:ok, provider_module} <- ReqLLM.provider(model.provider),
         {:ok, request} <- provider_module.prepare_request(:video_query, model, task_id, opts) do
      do_wait(request, poll_interval, deadline, max_transient_retries, timeout, opts)
    end
  end

  defp do_wait(request, poll_interval, deadline, retries_left, timeout, opts) do
    case query_request(request, opts) do
      {:ok, %Task{status: status} = task} when status in @terminal_statuses ->
        {:ok, task}

      {:ok, %Task{}} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, ReqLLM.Error.API.Timeout.exception(kind: :total, timeout: timeout)}
        else
          Process.sleep(poll_interval)
          do_wait(request, poll_interval, deadline, retries_left, timeout, opts)
        end

      {:error, error} ->
        if retries_left > 0 and transient_error?(error) do
          Process.sleep(poll_interval)
          do_wait(request, poll_interval, deadline, retries_left - 1, timeout, opts)
        else
          {:error, error}
        end
    end
  end

  defp query_request(request, opts) do
    deadline = ReqLLM.TimeoutBudget.deadline(opts)

    case ReqLLM.TimeoutBudget.request(request, deadline) do
      {:ok, %Req.Response{status: status, body: %Task{} = task}} when status in 200..299 ->
        {:ok, task}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error,
         ReqLLM.Error.API.Request.exception(
           reason: "HTTP #{status}: Request failed",
           status: status,
           response_body: body
         )}

      {:error, error} ->
        {:error, error}
    end
  end

  defp transient_error?(%Req.TransportError{reason: reason}),
    do: reason in [:closed, :timeout, :econnrefused]

  defp transient_error?(%ReqLLM.Error.API.Request{cause: %Req.TransportError{reason: reason}}),
    do: reason in [:closed, :timeout, :econnrefused]

  defp transient_error?(%ReqLLM.Error.API.Timeout{}), do: true
  defp transient_error?(_error), do: false

  @doc """
  Resolves a video `file_id` to a time-limited download URL.

  V1 providers (e.g. `MiniMax-Hailuo-2.3`) return a `file_id` on task
  success instead of a direct URL. Call this with the `file_id` from the
  succeeded task to obtain the download URL, which is time-limited and should
  be downloaded promptly.

  Returns `{:ok, %ReqLLM.Video.File{}}` with the `url` populated.
  """
  @spec retrieve_file(ReqLLM.model_input(), String.t(), keyword()) ::
          {:ok, File.t()} | {:error, term()}
  def retrieve_file(model_spec, file_id, opts \\ []) do
    opts = ReqLLM.ModelInput.merge_tuple_defaults(model_spec, :video, opts)
    deadline = ReqLLM.TimeoutBudget.deadline(opts)

    with {:ok, model} <- ReqLLM.model(model_spec),
         {:ok, provider_module} <- ReqLLM.provider(model.provider),
         {:ok, request} <- provider_module.prepare_request(:video_retrieve, model, file_id, opts),
         {:ok, %Req.Response{status: status, body: body}} when status in 200..299 <-
           ReqLLM.TimeoutBudget.request(request, deadline) do
      {:ok, body}
    else
      {:ok, %Req.Response{status: status, body: body}} ->
        {:error,
         ReqLLM.Error.API.Request.exception(
           reason: "HTTP #{status}: Request failed",
           status: status,
           response_body: body
         )}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Uploads a file to the provider platform for use as video generation input.

  Returns `{:ok, %ReqLLM.Video.File{}}` with the `file_id` populated. Use the
  returned `file_id` as `mm_file://{file_id}` in the `content` media fields of
  `generate_video/3` to reference the uploaded file without exposing a public
  URL (important for sensitive data).

  Alternatively, pass `{:upload, binary, media_type}` or `{:file, path}` as a
  media value in `generate_video/3` content to upload automatically. For V1
  models (e.g. `MiniMax-Hailuo-2.3`) the media is inlined as a base64 data URL
  instead, since the V1 API does not support `mm_file://` references.

  Options: `:purpose` (default `"video_generation_input"`), `:filename`
  (defaults to `"input.<ext>"` derived from `:media_type`), `:media_type`
  (default `"application/octet-stream"`).
  """
  @spec upload_file(ReqLLM.model_input(), binary(), keyword()) ::
          {:ok, File.t()} | {:error, term()}
  def upload_file(model_spec, file_binary, opts \\ []) do
    opts = ReqLLM.ModelInput.merge_tuple_defaults(model_spec, :video, opts)
    deadline = ReqLLM.TimeoutBudget.deadline(opts)

    with {:ok, model} <- ReqLLM.model(model_spec),
         {:ok, provider_module} <- ReqLLM.provider(model.provider),
         {:ok, request} <-
           provider_module.prepare_request(:video_upload, model, file_binary, opts),
         {:ok, %Req.Response{status: status, body: %File{} = file}} when status in 200..299 <-
           ReqLLM.TimeoutBudget.request(request, deadline) do
      {:ok, file}
    else
      {:ok, %Req.Response{status: status, body: body}} ->
        {:error,
         ReqLLM.Error.API.Request.exception(
           reason: "HTTP #{status}: Request failed",
           status: status,
           response_body: body
         )}

      {:error, error} ->
        {:error, error}
    end
  end

  @media_keys [
    :first_frame_image,
    :last_frame_image,
    :reference_images,
    :reference_videos,
    :reference_audio
  ]

  @upload_opts [
    :api_key,
    :base_url,
    :purpose,
    :filename,
    :media_type,
    :receive_timeout,
    :total_timeout,
    :max_retries,
    :telemetry,
    :fixture,
    :req_http_options
  ]

  defp maybe_upload_content(model, content, opts) when is_list(content) do
    upload_opts = Keyword.take(opts, @upload_opts)
    v2? = ReqLLM.Providers.Minimax.video_api_mod(model) == ReqLLM.Providers.Minimax.VideoAPI

    Enum.reduce_while(@media_keys, {:ok, content}, fn key, {:ok, acc} ->
      case Keyword.get(acc, key) do
        {:upload, binary, media_type} when is_binary(media_type) ->
          case upload_reference(model, v2?, binary, media_type, upload_opts) do
            {:ok, ref} -> {:cont, {:ok, Keyword.put(acc, key, ref)}}
            {:error, error} -> {:halt, {:error, error}}
          end

        {:upload, _binary, _media_type} ->
          {:halt,
           {:error,
            ReqLLM.Error.Invalid.Parameter.exception(
              parameter:
                "media_type must be a binary, e.g. {:upload, image_bytes, \"image/jpeg\"}"
            )}}

        {:file, path} ->
          case :file.read_file(path) do
            {:ok, binary} ->
              case upload_reference(model, v2?, binary, media_type_from_path(path), upload_opts) do
                {:ok, ref} -> {:cont, {:ok, Keyword.put(acc, key, ref)}}
                {:error, error} -> {:halt, {:error, error}}
              end

            {:error, error} ->
              {:halt, {:error, error}}
          end

        _ ->
          {:cont, {:ok, acc}}
      end
    end)
  end

  defp maybe_upload_content(_model, content, _opts), do: {:ok, content}

  defp upload_reference(model, true, binary, media_type, upload_opts) do
    with {:ok, file} <-
           upload_file(model, binary, Keyword.put(upload_opts, :media_type, media_type)) do
      {:ok, "mm_file://#{file.file_id}"}
    end
  end

  defp upload_reference(_model, false, binary, media_type, _upload_opts) do
    {:ok, "data:#{media_type};base64,#{Base.encode64(binary)}"}
  end

  defp media_type_from_path(path) do
    case path |> Path.extname() |> String.downcase() |> String.trim_leading(".") do
      "jpg" -> "image/jpeg"
      "jpeg" -> "image/jpeg"
      "png" -> "image/png"
      "webp" -> "image/webp"
      "heic" -> "image/heic"
      "heif" -> "image/heif"
      "mp4" -> "video/mp4"
      "mov" -> "video/quicktime"
      "wav" -> "audio/wav"
      "mp3" -> "audio/mpeg"
      _ -> "application/octet-stream"
    end
  end

  @doc """
  Returns a list of model specs that likely support video generation.
  """
  @spec supported_models() :: [String.t()]
  def supported_models do
    ReqLLM.Providers.list()
    |> Enum.flat_map(fn provider ->
      LLMDB.models(provider)
      |> Enum.filter(&video_capable_model?/1)
      |> Enum.map(&LLMDB.Model.spec/1)
    end)
  end

  @doc """
  Validates that a model supports video generation operations.
  """
  @spec validate_model(ReqLLM.model_input()) :: {:ok, Model.t()} | {:error, term()}
  def validate_model(model_spec) do
    with {:ok, model} <- ReqLLM.model(model_spec),
         {:ok, _provider_module} <- ReqLLM.provider(model.provider) do
      model_string = LLMDB.Model.spec(model)

      if video_capable_model?(model) do
        {:ok, model}
      else
        {:error,
         ReqLLM.Error.Invalid.Parameter.exception(
           parameter: "model: #{model_string} does not appear to support video generation"
         )}
      end
    end
  end

  defp video_capable_model?(model) do
    ReqLLM.ModelOperation.supported?(model, :video)
  end
end
