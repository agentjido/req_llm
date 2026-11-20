defmodule ReqLLM.Providers.Google.DecisionsAPI do
  @moduledoc """
  Gemini Decisions request compilation and response decoding for `ReqLLM.evaluate/4`.

  Supports boolean, choice, and score questions. Multimodal input uses a context
  containing one user message. Plain maps and lists are serialized as JSON text.
  """

  alias ReqLLM.Error.API.Response, as: ResponseError
  alias ReqLLM.Error.Invalid.Parameter
  alias ReqLLM.Evaluation.Codec
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Provider.Utils

  @doc false
  def request_private_key, do: :req_llm_google_decisions

  @doc false
  @spec compile_request(String.t(), ReqLLM.Evaluation.state(), map()) ::
          {:ok, map(), map()} | {:error, Exception.t()}
  def compile_request(model, state, questions) do
    input = compile_input!(state)
    questions = compile_questions!(questions)
    body = %{"model" => model, "input" => input, "questions" => questions}
    {:ok, body, %{model: model, questions: questions}}
  rescue
    error in [Parameter, ReqLLM.Error.Invalid.ProviderFileReference] -> {:error, error}
    error in [Jason.EncodeError, Protocol.UndefinedError] -> invalid(Exception.message(error))
  end

  @doc false
  def decode_response({request, %Req.Response{status: status} = response})
      when status in 200..299 do
    body = Utils.ensure_parsed_body(response.body)
    contract = request.private[request_private_key()]

    with :ok <- validate_response(body, contract),
         {:ok, result} <-
           Codec.decode_response(
             body
             |> Map.put("model", contract.model)
             |> Map.put("usage", normalize_usage(body["usage"])),
             request.private[:req_llm_evaluation_provider] || :google
           ) do
      result = put_in(result.provider_meta.raw_response, body)
      {request, %{response | body: result}}
    else
      _ -> response_error(request, response, "Invalid Gemini Decisions response", body)
    end
  end

  def decode_response({request, response}) do
    response_error(
      request,
      response,
      "Gemini Decisions request failed",
      Utils.ensure_parsed_body(response.body)
    )
  end

  defp compile_input!(text) when is_binary(text) and byte_size(text) > 0, do: text

  defp compile_input!(
         %ReqLLM.Context{
           messages: [%ReqLLM.Message{role: :user, content: [_ | _] = parts, tool_calls: calls}]
         } = context
       )
       when calls in [nil, []] do
    case ReqLLM.ProviderFileReference.validate_context(context, :google) do
      :ok -> Enum.map(parts, &compile_part!/1)
      {:error, error} -> raise error
    end
  end

  defp compile_input!(%ReqLLM.Context{}) do
    invalid!("context must contain exactly one non-empty user message without tool calls")
  end

  defp compile_input!(state) when is_map(state) or is_list(state) do
    state |> normalize_keys!() |> Jason.encode!()
  end

  defp compile_input!(_),
    do: invalid!("input must be non-empty text, JSON data, or a user context")

  defp compile_part!(%ContentPart{type: :text, text: text})
       when is_binary(text) and byte_size(text) > 0,
       do: %{"type" => "text", "text" => text}

  defp compile_part!(%ContentPart{type: type, data: data, media_type: mime} = part)
       when type in [:image, :file] and is_binary(data) and byte_size(data) > 0 do
    media_block!(mime, "data", Base.encode64(data), part.metadata)
  end

  defp compile_part!(%ContentPart{type: :file, file_id: uri, media_type: mime} = part)
       when is_binary(uri) do
    media_block!(mime, "uri", validate_uri!(uri), part.metadata)
  end

  defp compile_part!(%ContentPart{type: type, url: uri} = part)
       when type in [:image_url, :video_url] and is_binary(uri) do
    mime =
      part.media_type || part.metadata[:mime_type] || part.metadata["mime_type"] ||
        MIME.from_path(URI.parse(uri).path || "")

    media_block!(mime, "uri", validate_uri!(uri), part.metadata)
  end

  defp compile_part!(_), do: invalid!("unsupported or empty input content part")

  defp media_block!(mime, source, value, metadata) do
    type = media_type!(mime)
    block = %{"type" => type, source => value, "mime_type" => mime}

    case metadata[:resolution] || metadata["resolution"] do
      nil ->
        block

      resolution when type in ["image", "video"] ->
        allowed =
          if type == "image", do: ~w(low medium high ultra_high), else: ~w(low medium high)

        resolution = to_string(resolution)
        unless resolution in allowed, do: invalid!("unsupported #{type} resolution")
        Map.put(block, "resolution", resolution)

      _ ->
        invalid!("resolution is supported only for image and video inputs")
    end
  end

  defp media_type!("image/" <> _), do: "image"
  defp media_type!("audio/" <> _), do: "audio"
  defp media_type!("video/" <> _), do: "video"
  defp media_type!("application/pdf"), do: "document"
  defp media_type!(_), do: invalid!("media requires an image, audio, video, or PDF MIME type")

  defp validate_uri!(uri) do
    parsed = URI.parse(uri)
    host = String.downcase(parsed.host || "")

    if parsed.scheme == "https" and host != "" and
         not (host in ["youtu.be", "youtube.com"] or String.ends_with?(host, ".youtube.com")) do
      uri
    else
      invalid!("media requires a Files API URI or HTTPS URL; YouTube and gs:// are unsupported")
    end
  end

  defp compile_questions!(questions) when is_map(questions) and map_size(questions) in 1..1000 do
    questions
    |> normalize_keys!()
    |> Map.new(fn {name, question} ->
      unless Regex.match?(~r/\A[A-Za-z0-9_-]{1,64}\z/, name),
        do: invalid!("question names must match [A-Za-z0-9_-] and contain 1 to 64 characters")

      {name, compile_question!(question)}
    end)
  end

  defp compile_questions!(_),
    do: invalid!("questions must be a map containing 1 to 1,000 entries")

  defp compile_question!(%{"type" => type, "instructions" => instructions} = question)
       when type in ["boolean", "noul", "choice", "score"] and is_binary(instructions) do
    type = if type == "boolean", do: "noul", else: type
    validate_criteria!(type, question["criteria"])

    question
    |> Map.take(["instructions", "criteria"])
    |> Map.put("type", type)
  end

  defp compile_question!(_),
    do: invalid!("questions require a supported type and text instructions")

  defp validate_criteria!("noul", nil), do: :ok

  defp validate_criteria!("noul", criteria) when is_map(criteria) do
    unless Enum.all?(criteria, fn {key, value} ->
             key in ["true_description", "false_description"] and is_binary(value)
           end),
           do:
             invalid!("boolean criteria accept only true_description and false_description text")
  end

  defp validate_criteria!("choice", criteria)
       when is_map(criteria) and map_size(criteria) in 2..255 do
    unless Enum.all?(criteria, fn {key, value} -> valid_option_key?(key) and is_binary(value) end),
           do: invalid!("choice criteria require valid option names and text descriptions")
  end

  defp validate_criteria!("score", criteria) when is_list(criteria) do
    unless length(criteria) in 2..255 and
             Enum.all?(criteria, &(is_binary(&1) and String.trim(&1) != "")),
           do: invalid!("score criteria require 2 to 255 non-empty level descriptions")
  end

  defp validate_criteria!(_, _), do: invalid!("invalid criteria for the question type")

  defp valid_option_key?(key) do
    String.length(key) in 1..128 and byte_size(key) <= 512 and String.trim(key) == key and
      not Regex.match?(~r/[\x00-\x1F\x7F]|[^\S ]/u, key)
  end

  defp normalize_keys!(%_{}), do: invalid!("JSON input must not contain structs")

  defp normalize_keys!(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {normalize_key!(key), normalize_keys!(value)} end)
    |> then(fn normalized ->
      if map_size(normalized) != map_size(map),
        do: invalid!("duplicate keys after string normalization")

      normalized
    end)
  end

  defp normalize_keys!(list) when is_list(list), do: Enum.map(list, &normalize_keys!/1)
  defp normalize_keys!(value) when value in [nil, true, false], do: value
  defp normalize_keys!(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_keys!(value), do: value

  defp normalize_key!(key) when is_atom(key) or is_binary(key), do: to_string(key)
  defp normalize_key!(_), do: invalid!("object keys must be strings or atoms")

  defp validate_response(%{"answers" => answers, "usage" => usage}, %{questions: questions})
       when is_map(answers) and is_map(usage) do
    if MapSet.new(Map.keys(answers)) == MapSet.new(Map.keys(questions)) and
         Enum.all?(questions, fn {name, question} -> valid_answer?(answers[name], question) end) and
         valid_usage?(usage) do
      :ok
    else
      :error
    end
  end

  defp validate_response(_, _), do: :error

  defp valid_answer?(%{"type" => "noul", "noul" => probability} = answer, %{"type" => "noul"}),
    do: probability?(probability) and probability?(answer["confidence"])

  defp valid_answer?(%{"type" => "choice", "choice" => choice} = answer, %{
         "type" => "choice",
         "criteria" => criteria
       }) do
    Map.has_key?(criteria, choice) and probability?(answer["confidence"]) and
      valid_probabilities?(answer["probabilities"], Map.keys(criteria))
  end

  defp valid_answer?(%{"type" => "score", "score" => score} = answer, %{
         "type" => "score",
         "criteria" => criteria
       }) do
    legend =
      criteria |> Enum.with_index() |> Map.new(fn {text, index} -> {to_string(index), text} end)

    is_number(score) and score >= 0 and score <= length(criteria) - 1 and
      probability?(answer["confidence"]) and answer["legend"] == legend and
      valid_probabilities?(answer["probabilities"], Map.keys(legend))
  end

  defp valid_answer?(_, _), do: false

  defp valid_probabilities?(probabilities, keys) when is_map(probabilities) do
    MapSet.new(Map.keys(probabilities)) == MapSet.new(keys) and
      Enum.all?(Map.values(probabilities), &probability?/1)
  end

  defp valid_probabilities?(_, _), do: false
  defp probability?(value), do: is_number(value) and value >= 0 and value <= 1

  defp valid_usage?(usage) do
    is_integer(usage["total_input_tokens"]) and usage["total_input_tokens"] >= 0 and
      usage["total_output_tokens"] == 0 and is_integer(usage["total_tokens"]) and
      usage["total_tokens"] >= 0
  end

  defp normalize_usage(usage) do
    %{
      "input_tokens" => usage["total_input_tokens"],
      "output_tokens" => usage["total_output_tokens"],
      "total_tokens" => usage["total_tokens"]
    }
  end

  defp response_error(request, response, reason, body) do
    {request,
     ResponseError.exception(reason: reason, status: response.status, response_body: body)}
  end

  defp invalid!(message), do: raise(Parameter, parameter: "Gemini Decisions #{message}")

  defp invalid(message),
    do: {:error, Parameter.exception(parameter: "Gemini Decisions #{message}")}
end
