defmodule ReqLLM.Providers.Minimax.VideoAPIV1 do
  @moduledoc """
  MiniMax Video API V1 driver (Hailuo series).

  Implements request/response handling for the legacy MiniMax video generation
  endpoints used by the `MiniMax-Hailuo-*`, `I2V-01*`, and `T2V-01*` models:

    * `POST /v1/video_generation` - create a generation task, returns `task_id`
    * `GET /v1/query/video_generation?task_id=...` - poll task status, returns
      a `file_id` on success
    * `GET /v1/files/retrieve?file_id=...` - resolve the `file_id` to a
      time-limited download URL

  Unlike the V2 API (MiniMax-H3), the request body is flat (`prompt`,
  `first_frame_image`, ...) and the query endpoint takes `task_id` as a query
  parameter. Task statuses are `Preparing` / `Queueing` / `Processing` /
  `Success` / `Fail`.
  """

  @behaviour ReqLLM.Providers.OpenAI.API

  import ReqLLM.Provider.Utils, only: [ensure_parsed_body: 1]

  alias ReqLLM.Video.Task

  @status_map %{
    "Preparing" => :queued,
    "Queueing" => :queued,
    "Processing" => :running,
    "Success" => :succeeded,
    "Fail" => :failed
  }

  @impl true
  def path, do: "/video_generation"

  @doc """
  Path of the task query endpoint for the given `task_id`.
  """
  @spec query_path(String.t()) :: String.t()
  def query_path(task_id) do
    "/query/video_generation?task_id=#{task_id}"
  end

  @doc """
  Path of the file retrieval endpoint for the given `file_id`.
  """
  @spec retrieve_path(String.t()) :: String.t()
  def retrieve_path(file_id) do
    "/files/retrieve?file_id=#{file_id}"
  end

  @doc """
  Path of the file upload endpoint.
  """
  @spec upload_path() :: String.t()
  def upload_path, do: "/files/upload"

  @doc """
  Base URL for the MiniMax V1 video endpoints.
  """
  @spec base_url() :: String.t()
  def base_url, do: "https://api.minimax.io/v1"

  @impl true
  def encode_body(request) do
    case request.options[:operation] do
      :video -> encode_create_body(request)
      :video_query -> request
      :video_retrieve -> request
      :video_upload -> request
    end
  end

  defp encode_create_body(request) do
    opts = request.options
    content = opts[:content] || []

    body =
      %{"model" => opts[:model]}
      |> maybe_put_string("prompt", Keyword.get(content, :prompt))
      |> maybe_put_string("first_frame_image", Keyword.get(content, :first_frame_image))
      |> maybe_put_string("last_frame_image", Keyword.get(content, :last_frame_image))
      |> maybe_put_boolean("prompt_optimizer", opts[:prompt_optimizer])
      |> maybe_put_boolean("fast_pretreatment", opts[:fast_pretreatment])
      |> maybe_put_integer("duration", opts[:duration])
      |> maybe_put_string("resolution", opts[:resolution])
      |> maybe_put_string("callback_url", opts[:callback_url])

    put_in(request.options[:json], body)
  end

  @impl true
  def decode_response({req, %Req.Response{status: status} = resp}) when status not in 200..299 do
    body = ensure_parsed_body(resp.body)

    error =
      ReqLLM.Error.API.Response.exception(
        reason: http_error_reason(body),
        status: status,
        response_body: body
      )

    {req, error}
  end

  def decode_response({req, resp}) do
    body = ensure_parsed_body(resp.body)

    case req.options[:operation] do
      :video ->
        case minimax_error?(body) do
          {:error, error} ->
            {req, error}

          :ok ->
            decode_create_response(req, resp, body)
        end

      :video_query ->
        decode_query_response(req, resp, body)

      :video_retrieve ->
        case minimax_error?(body) do
          {:error, error} -> {req, error}
          :ok -> decode_retrieve_response(req, resp, body)
        end

      :video_upload ->
        case minimax_error?(body) do
          {:error, error} -> {req, error}
          :ok -> decode_upload_response(req, resp, body)
        end
    end
  end

  @impl true
  def decode_stream_event(_event, _model), do: []

  @impl true
  def attach_stream(_model, _context, _opts, _finch_name) do
    {:error,
     ReqLLM.Error.Invalid.Parameter.exception(parameter: "streaming not supported for :video")}
  end

  defp decode_create_response(req, resp, %{"task_id" => task_id} = body) do
    task = %Task{
      task_id: task_id,
      status: :queued,
      model: req.options[:model],
      provider: :minimax,
      provider_meta: %{"minimax" => Map.delete(body, "task_id")}
    }

    {req, %{resp | body: task}}
  end

  defp decode_create_response(req, resp, body) do
    err =
      ReqLLM.Error.API.Response.exception(
        reason: "MiniMax Video API error: missing task_id in response",
        status: resp.status,
        response_body: body
      )

    {req, err}
  end

  defp decode_query_response(req, resp, %{"status" => status} = body)
       when is_binary(status) do
    case get_in(body, ["base_resp", "status_code"]) do
      code when is_integer(code) and code != 0 and status != "Fail" ->
        status_msg =
          get_in(body, ["base_resp", "status_msg"]) || "MiniMax video query failed"

        err =
          ReqLLM.Error.API.Response.exception(
            reason: "MiniMax error #{code}: #{status_msg}",
            status: code,
            response_body: body
          )

        {req, err}

      _ ->
        task = %Task{
          task_id: Map.get(body, "task_id", req.options[:task_id]),
          status: decode_status(Map.get(body, "status")),
          file_id: Map.get(body, "file_id"),
          error: decode_error(body),
          model: req.options[:model],
          provider: :minimax,
          provider_meta: %{
            "minimax" => Map.take(body, ["video_width", "video_height", "base_resp"])
          }
        }

        {req, %{resp | body: task}}
    end
  end

  defp decode_query_response(req, resp, body) do
    malformed_response(req, resp, body, "missing status in query response")
  end

  defp decode_upload_response(
         req,
         resp,
         %{"file" => %{"file_id" => file_id} = file_body} = body
       )
       when is_binary(file_id) or is_integer(file_id) do
    file = %ReqLLM.Video.File{
      file_id: file_id,
      filename: Map.get(file_body, "filename"),
      bytes: Map.get(file_body, "bytes"),
      purpose: Map.get(file_body, "purpose"),
      provider_meta: %{"minimax" => Map.take(body, ["base_resp"])}
    }

    {req, %{resp | body: file}}
  end

  defp decode_upload_response(req, resp, body) do
    malformed_response(req, resp, body, "missing file_id in upload response")
  end

  defp decode_retrieve_response(
         req,
         resp,
         %{
           "file" => %{"file_id" => file_id, "download_url" => download_url} = file_body
         } = body
       )
       when (is_binary(file_id) or is_integer(file_id)) and is_binary(download_url) and
              download_url != "" do
    file = %ReqLLM.Video.File{
      file_id: file_id,
      url: download_url,
      filename: Map.get(file_body, "filename"),
      bytes: Map.get(file_body, "bytes"),
      purpose: Map.get(file_body, "purpose"),
      provider_meta: %{"minimax" => Map.take(body, ["base_resp"])}
    }

    {req, %{resp | body: file}}
  end

  defp decode_retrieve_response(req, resp, body) do
    malformed_response(req, resp, body, "missing file_id or download_url in retrieve response")
  end

  defp decode_status(status) when is_binary(status), do: Map.get(@status_map, status, :queued)
  defp decode_status(_status), do: :queued

  defp decode_error(%{"status" => "Fail"} = body) do
    get_in(body, ["base_resp", "status_msg"]) || "MiniMax video generation failed"
  end

  defp decode_error(_body), do: nil

  defp minimax_error?(body) when is_map(body) do
    case get_in(body, ["base_resp", "status_code"]) do
      code when is_integer(code) and code != 0 ->
        status_msg =
          get_in(body, ["base_resp", "status_msg"]) || "MiniMax video generation failed"

        {:error,
         ReqLLM.Error.API.Response.exception(
           reason: "MiniMax error #{code}: #{status_msg}",
           status: code,
           response_body: body
         )}

      _ ->
        :ok
    end
  end

  defp minimax_error?(_body), do: :ok

  defp http_error_reason(body) do
    case get_in(body, ["base_resp", "status_code"]) do
      code when is_integer(code) and code != 0 ->
        status_msg = get_in(body, ["base_resp", "status_msg"]) || "request failed"
        "MiniMax error #{code}: #{status_msg}"

      _ ->
        "MiniMax Video API error"
    end
  end

  defp malformed_response(req, resp, body, detail) do
    error =
      ReqLLM.Error.API.Response.exception(
        reason: "MiniMax Video API error: #{detail}",
        status: resp.status,
        response_body: body
      )

    {req, error}
  end

  defp maybe_put_string(body, _key, nil), do: body

  defp maybe_put_string(body, key, value) when is_atom(value) do
    Map.put(body, key, Atom.to_string(value))
  end

  defp maybe_put_string(body, key, value) when is_binary(value) do
    Map.put(body, key, value)
  end

  defp maybe_put_string(body, _key, _), do: body

  defp maybe_put_integer(body, _key, nil), do: body
  defp maybe_put_integer(body, key, value) when is_integer(value), do: Map.put(body, key, value)
  defp maybe_put_integer(body, _key, _), do: body

  defp maybe_put_boolean(body, _key, nil), do: body
  defp maybe_put_boolean(body, key, value) when is_boolean(value), do: Map.put(body, key, value)
  defp maybe_put_boolean(body, _key, _), do: body
end
