defmodule ReqLLM.Providers.Minimax.VideoAPI do
  @moduledoc """
  MiniMax Video API driver.

  Implements request/response handling for MiniMax video generation via the
  native async endpoints:

    * `POST /v2/video_generation` - create a generation task, returns `task_id`
    * `GET /v2/query/video_generation/{task_id}` - poll task status, returns
      the video download URL on success

  The request body uses the multimodal `content[]` shape (`text` /
  `image_url` / `video_url` / `audio_url` with optional `role`), which is
  encoded from the structured keyword list passed to `ReqLLM.Video`.
  """

  @behaviour ReqLLM.Providers.OpenAI.API

  import ReqLLM.Provider.Utils, only: [ensure_parsed_body: 1]

  alias ReqLLM.Video.Task

  @status_map %{
    "queued" => :queued,
    "running" => :running,
    "succeeded" => :succeeded,
    "failed" => :failed,
    "cancelled" => :cancelled
  }

  @impl true
  def path, do: "/v2/video_generation"

  @doc """
  Base URL for the MiniMax V2 video endpoints (the V1 base URL does not apply).
  """
  @spec base_url() :: String.t()
  def base_url, do: "https://api.minimax.io"

  @doc """
  Path of the task query endpoint for the given `task_id`.
  """
  @spec query_path(String.t()) :: String.t()
  def query_path(task_id) do
    "/v2/query/video_generation/#{task_id}"
  end

  @impl true
  def encode_body(request) do
    case request.options[:operation] do
      :video -> encode_create_body(request)
      :video_query -> request
    end
  end

  defp encode_create_body(request) do
    opts = request.options

    body =
      %{
        "model" => opts[:model],
        "content" => encode_content(opts[:content])
      }
      |> maybe_put_string("resolution", opts[:resolution])
      |> maybe_put_integer("duration", opts[:duration])
      |> maybe_put_string("ratio", opts[:ratio])
      |> maybe_put_string("callback_url", opts[:callback_url])

    put_in(request.options[:json], body)
  end

  @impl true
  def decode_response({req, resp}) do
    body = ensure_parsed_body(resp.body)

    case minimax_error?(body) do
      {:error, error} ->
        {req, error}

      :ok ->
        case resp.status do
          200 ->
            case req.options[:operation] do
              :video -> decode_create_response(req, resp, body)
              :video_query -> decode_query_response(req, resp, body)
            end

          status ->
            err =
              ReqLLM.Error.API.Response.exception(
                reason: "MiniMax Video API error",
                status: status,
                response_body: resp.body
              )

            {req, err}
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

  defp decode_query_response(req, resp, %{"task" => task}) when is_map(task) do
    status = Map.get(task, "status", "queued") |> decode_status()

    task_struct = %Task{
      task_id: Map.get(task, "id", req.options[:task_id]),
      status: status,
      url: get_in(task, ["content", "url"]),
      error: decode_error(get_in(task, ["error"])),
      model: Map.get(task, "model", req.options[:model]),
      provider: :minimax,
      provider_meta: %{
        "minimax" =>
          Map.take(task, ["created_at", "updated_at", "resolution", "duration", "ratio"])
      }
    }

    {req, %{resp | body: task_struct}}
  end

  defp decode_query_response(req, resp, body) do
    err =
      ReqLLM.Error.API.Response.exception(
        reason: "MiniMax Video API error: missing task in response",
        status: resp.status,
        response_body: body
      )

    {req, err}
  end

  defp decode_status(status) when is_binary(status), do: Map.get(@status_map, status, :queued)
  defp decode_status(_status), do: :queued

  defp decode_error(nil), do: nil

  defp decode_error(%{"message" => message} = error) do
    code = Map.get(error, "code")

    if code do
      "#{code}: #{message}"
    else
      message
    end
  end

  defp decode_error(_), do: nil

  defp encode_content(content) when is_list(content) do
    prompt = Keyword.get(content, :prompt)

    text_item = %{"type" => "text", "text" => prompt}

    image_items =
      encode_media_items(content, :first_frame_image, "image_url", "first_frame") ++
        encode_media_items(content, :last_frame_image, "image_url", "last_frame") ++
        encode_media_items(content, :reference_images, "image_url", "reference_image")

    video_items =
      encode_media_items(content, :reference_videos, "video_url", "reference_video")

    audio_items =
      encode_media_items(content, :reference_audio, "audio_url", "reference_audio")

    [text_item | image_items ++ video_items ++ audio_items]
  end

  defp encode_content(_content), do: []

  defp encode_media_items(content, key, type, role) do
    case Keyword.get(content, key) do
      nil ->
        []

      value when is_binary(value) ->
        [media_item(type, role, value)]

      values when is_list(values) ->
        Enum.map(values, &media_item(type, role, &1)) |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp media_item(type, role, url) when is_binary(url) do
    %{"type" => type, type => %{"url" => url}, "role" => role}
  end

  defp media_item(_type, _role, _url), do: nil

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
        case Map.get(body, "type") do
          "error" ->
            message = get_in(body, ["error", "message"]) || "MiniMax video generation failed"

            {:error,
             ReqLLM.Error.API.Response.exception(
               reason: "MiniMax error: #{message}",
               status: 400,
               response_body: body
             )}

          _ ->
            :ok
        end
    end
  end

  defp minimax_error?(_body), do: :ok

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
end
