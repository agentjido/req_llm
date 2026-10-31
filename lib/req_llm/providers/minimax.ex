defmodule ReqLLM.Providers.Minimax do
  @moduledoc """
  MiniMax provider using the OpenAI-compatible Chat Completions API.

  MiniMax exposes an OpenAI-compatible endpoint at `https://api.minimax.io/v1`.
  This provider reuses the shared OpenAI wire-format implementation and adds
  MiniMax-specific option handling:

  - `max_tokens` is translated to `max_completion_tokens`; explicit limits are
    preserved, while library defaults are capped at the recommended 131072 tokens
  - `reasoning_split` defaults to `true` so reasoning is returned as structured
    `reasoning_details` and can be preserved across turns
  - `reasoning_effort` is forwarded for models that tune thinking depth
    (`MiniMax-M3.1-Flash`: `:low`, `:medium`, `:high`, `:xhigh`, `:max`)
  - `thinking` accepts `%{type: "adaptive"}` for every model, and
    `%{type: "disabled"}` only where MiniMax allows skipping thinking
  - unsupported OpenAI parameters that MiniMax ignores are removed before the
    request is sent

  ## Configuration

      MINIMAX_API_KEY=your-api-key

  ## Examples

      ReqLLM.generate_text("minimax:MiniMax-M3.1-Flash", "Hello!",
        reasoning_effort: :xhigh,
        max_tokens: 4096
      )

      ReqLLM.generate_text("minimax:MiniMax-M3", "Hello!",
        thinking: %{type: "disabled"}
      )

      ReqLLM.stream_text("minimax:MiniMax-M3.1-Flash", "Tell me a story",
        reasoning_effort: :low,
        max_tokens: 512
      )
  """

  use ReqLLM.Provider,
    id: :minimax,
    default_base_url: "https://api.minimax.io/v1",
    default_env_key: "MINIMAX_API_KEY"

  import ReqLLM.Provider.Utils, only: [maybe_put: 3]

  @recommended_max_completion_tokens 131_072

  @provider_schema [
    max_completion_tokens: [
      type: :pos_integer,
      doc: "Maximum generated tokens. MiniMax uses max_completion_tokens instead of max_tokens."
    ],
    reasoning_split: [
      type: :boolean,
      default: true,
      doc: "Return thinking content in reasoning_details instead of inline <thinking> tags."
    ],
    thinking: [
      type: :map,
      doc:
        ~s|Thinking mode, for example %{type: "adaptive"}. Set %{type: "disabled"} only on models that can skip thinking; MiniMax-M3.1-Flash always thinks and rejects it.|
    ],
    prompt_optimizer: [
      type: :boolean,
      default: false,
      doc: "Enable automatic prompt optimization for MiniMax image generation."
    ],
    fast_pretreatment: [
      type: :boolean,
      doc: "Reduce MiniMax video prompt optimization time when prompt optimization is enabled."
    ],
    subject_reference: [
      type: :any,
      doc:
        ~s|Image-to-image character reference for MiniMax image generation. A keyword list or map (or list thereof) with :type/"type" ("character") and :image_file/"image_file" (public URL or base64 data URL).|
    ]
  ]

  @impl ReqLLM.Provider
  def prepare_request(:embedding, _model_spec, _input, _opts) do
    unsupported_operation(:embedding)
  end

  def prepare_request(:transcription, _model_spec, _input, _opts) do
    unsupported_operation(:transcription)
  end

  def prepare_request(:speech, _model_spec, _input, _opts) do
    unsupported_operation(:speech)
  end

  def prepare_request(:image, model_spec, prompt_or_messages, opts) do
    with {:ok, model} <- ReqLLM.model(model_spec),
         {:ok, context, prompt} <- image_context(prompt_or_messages, opts),
         opts_with_context = Keyword.put(opts, :context, context),
         http_opts = Keyword.get(opts, :req_http_options, []),
         {:ok, processed_opts} <-
           ReqLLM.Provider.Options.process(__MODULE__, :image, model, opts_with_context) do
      api_mod = ReqLLM.Providers.Minimax.ImagesAPI
      path = api_mod.path()

      req_keys =
        supported_provider_options() ++
          [
            :context,
            :operation,
            :model,
            :prompt,
            :n,
            :size,
            :aspect_ratio,
            :output_format,
            :response_format,
            :seed,
            :provider_options,
            :req_http_options,
            :api_mod,
            :base_url
          ]

      timeout =
        Keyword.get(
          processed_opts,
          :receive_timeout,
          Application.get_env(:req_llm, :image_receive_timeout, 120_000)
        )

      request =
        Req.new(
          [
            url: path,
            method: :post,
            receive_timeout: timeout
          ] ++ ReqLLM.Provider.Defaults.merge_finch_options(http_opts, pool_timeout: timeout)
        )
        |> Req.Request.register_options(req_keys)
        |> Req.Request.merge_options(
          Keyword.take(processed_opts, req_keys) ++
            [
              operation: :image,
              model: model.provider_model_id || model.id,
              prompt: prompt,
              context: context,
              base_url: Keyword.get(processed_opts, :base_url, default_base_url()),
              api_mod: api_mod
            ]
        )
        |> attach(model, processed_opts)

      {:ok, request}
    end
  end

  def prepare_request(:video, model_spec, content, opts) do
    with {:ok, model} <- ReqLLM.model(model_spec),
         {:ok, content} <- video_content(content),
         http_opts = Keyword.get(opts, :req_http_options, []),
         api_mod = video_api_mod(model),
         opts = Keyword.put_new(opts, :base_url, api_mod.base_url()),
         {:ok, processed_opts} <-
           ReqLLM.Provider.Options.process(__MODULE__, :video, model, opts) do
      path = api_mod.path()

      req_keys =
        supported_provider_options() ++
          [
            :operation,
            :model,
            :content,
            :duration,
            :resolution,
            :ratio,
            :callback_url,
            :prompt_optimizer,
            :fast_pretreatment,
            :provider_options,
            :req_http_options,
            :api_mod,
            :base_url
          ]

      timeout =
        Keyword.get(
          processed_opts,
          :receive_timeout,
          Application.get_env(:req_llm, :video_receive_timeout, 60_000)
        )

      request =
        Req.new(
          [
            url: path,
            method: :post,
            receive_timeout: timeout
          ] ++ ReqLLM.Provider.Defaults.merge_finch_options(http_opts, pool_timeout: timeout)
        )
        |> Req.Request.register_options(req_keys)
        |> Req.Request.merge_options(
          Keyword.take(processed_opts, req_keys) ++
            [
              operation: :video,
              model: model.provider_model_id || model.id,
              content: content,
              base_url: Keyword.get(opts, :base_url, api_mod.base_url()),
              api_mod: api_mod
            ]
        )
        |> attach(model, processed_opts)

      {:ok, request}
    end
  end

  def prepare_request(:video_query, model_spec, task_id, opts) do
    with {:ok, model} <- ReqLLM.model(model_spec) do
      api_mod = video_api_mod(model)
      path = api_mod.query_path(task_id)
      http_opts = Keyword.get(opts, :req_http_options, [])
      timeout = Keyword.get(opts, :receive_timeout, 30_000)

      request =
        Req.new(
          [
            url: path,
            method: :get,
            receive_timeout: timeout
          ] ++ ReqLLM.Provider.Defaults.merge_finch_options(http_opts, pool_timeout: timeout)
        )
        |> Req.Request.register_options([
          :operation,
          :model,
          :task_id,
          :api_mod,
          :base_url,
          :req_http_options
        ])
        |> Req.Request.merge_options(
          operation: :video_query,
          model: model.provider_model_id || model.id,
          task_id: task_id,
          base_url: Keyword.get(opts, :base_url, api_mod.base_url()),
          api_mod: api_mod
        )
        |> attach(model, opts)

      {:ok, request}
    end
  end

  def prepare_request(:video_retrieve, model_spec, file_id, opts) do
    with {:ok, model} <- ReqLLM.model(model_spec) do
      api_mod = ReqLLM.Providers.Minimax.VideoAPIV1
      path = api_mod.retrieve_path(file_id)
      http_opts = Keyword.get(opts, :req_http_options, [])
      timeout = Keyword.get(opts, :receive_timeout, 30_000)

      request =
        Req.new(
          [
            url: path,
            method: :get,
            receive_timeout: timeout
          ] ++ ReqLLM.Provider.Defaults.merge_finch_options(http_opts, pool_timeout: timeout)
        )
        |> Req.Request.register_options([
          :operation,
          :model,
          :file_id,
          :api_mod,
          :base_url,
          :req_http_options
        ])
        |> Req.Request.merge_options(
          operation: :video_retrieve,
          model: model.provider_model_id || model.id,
          file_id: file_id,
          base_url: Keyword.get(opts, :base_url, api_mod.base_url()),
          api_mod: api_mod
        )
        |> attach(model, opts)

      {:ok, request}
    end
  end

  def prepare_request(:video_upload, model_spec, file_binary, opts) do
    with {:ok, model} <- ReqLLM.model(model_spec) do
      api_mod = ReqLLM.Providers.Minimax.VideoAPIV1
      path = api_mod.upload_path()
      http_opts = Keyword.get(opts, :req_http_options, [])
      timeout = Keyword.get(opts, :receive_timeout, 60_000)
      purpose = Keyword.get(opts, :purpose, "video_generation_input")
      media_type = Keyword.get(opts, :media_type, "application/octet-stream")
      filename = Keyword.get(opts, :filename) || upload_filename(media_type)

      request =
        Req.new(
          [
            url: path,
            method: :post,
            receive_timeout: timeout,
            form_multipart: [
              {"purpose", purpose},
              {"file", {file_binary, [filename: filename, content_type: media_type]}}
            ]
          ] ++ ReqLLM.Provider.Defaults.merge_finch_options(http_opts, pool_timeout: timeout)
        )
        |> Req.Request.register_options([
          :operation,
          :model,
          :api_mod,
          :base_url,
          :req_http_options,
          :purpose,
          :filename,
          :media_type
        ])
        |> Req.Request.merge_options(
          operation: :video_upload,
          model: model.provider_model_id || model.id,
          base_url: Keyword.get(opts, :base_url, api_mod.base_url()),
          api_mod: api_mod
        )
        |> attach(model, opts)

      {:ok, request}
    end
  end

  def prepare_request(operation, model_spec, input, opts) do
    ReqLLM.Provider.Defaults.prepare_request(__MODULE__, operation, model_spec, input, opts)
  end

  @impl ReqLLM.Provider
  def normalize_max_tokens_default(operation, _model, limit)
      when operation in [:chat, :object] do
    min(limit, @recommended_max_completion_tokens)
  end

  def normalize_max_tokens_default(_operation, _model, limit), do: limit

  @impl ReqLLM.Provider
  def translate_options(:image, _model, opts),
    do: ReqLLM.Images.drop_openai_only_options(opts, "MiniMax")

  def translate_options(:video, _model, opts), do: {opts, []}

  def translate_options(:video_query, _model, opts), do: {opts, []}

  def translate_options(:video_retrieve, _model, opts), do: {opts, []}

  def translate_options(:video_upload, _model, opts), do: {opts, []}

  def translate_options(_operation, model, opts) do
    warnings = []

    opts =
      opts
      |> Keyword.put_new(:reasoning_split, true)
      |> Keyword.put_new(
        :receive_timeout,
        Application.get_env(:req_llm, :thinking_timeout, 300_000)
      )

    {max_tokens, opts} = Keyword.pop(opts, :max_tokens)
    opts = put_completion_token_limit(max_tokens, opts)

    {opts, warnings} = drop_ignored_option(opts, warnings, :presence_penalty)
    {opts, warnings} = drop_ignored_option(opts, warnings, :frequency_penalty)
    {opts, warnings} = drop_ignored_option(opts, warnings, :seed)
    {opts, warnings} = normalize_reasoning(model, opts, warnings)

    {opts, Enum.reverse(warnings)}
  end

  def pre_validate_options(:video, _model, opts) do
    provider_options =
      opts
      |> Keyword.get(:provider_options, [])
      |> Keyword.put_new(:prompt_optimizer, true)

    Keyword.put(opts, :provider_options, provider_options)
  end

  def pre_validate_options(_operation, _model, opts), do: opts

  @impl ReqLLM.Provider
  def encode_body(%{options: %{api_mod: api_mod}} = request) when is_atom(api_mod) do
    api_mod.encode_body(request)
  end

  def encode_body(request) do
    body = build_body(request)
    ReqLLM.Provider.Defaults.encode_body_from_map(request, body)
  end

  @impl ReqLLM.Provider
  def build_body(request) do
    reasoning_split = option_value(request.options, :reasoning_split, true)
    original_context = request.options[:context]

    request
    |> strip_reasoning_details_from_context()
    |> ReqLLM.Provider.Defaults.default_build_body()
    |> encode_minimax_reasoning_history(original_context)
    |> Map.delete(:max_tokens)
    |> Map.delete("max_tokens")
    |> maybe_put(:max_completion_tokens, request.options[:max_completion_tokens])
    |> maybe_put(:reasoning_split, reasoning_split)
    |> maybe_put(
      :reasoning_effort,
      wire_effort(provider_option(request.options, :reasoning_effort))
    )
    |> maybe_put(:thinking, provider_option(request.options, :thinking))
  end

  defp wire_effort(nil), do: nil
  defp wire_effort(effort) when is_atom(effort), do: Atom.to_string(effort)
  defp wire_effort(effort), do: effort

  @impl ReqLLM.Provider
  def decode_response({req, resp} = _args) do
    case req.options[:api_mod] do
      api_mod when is_atom(api_mod) and not is_nil(api_mod) ->
        api_mod.decode_response({req, resp})

      _ ->
        decode_chat_response({req, resp})
    end
  end

  defp decode_chat_response({req, resp} = args) do
    case resp.status do
      200 ->
        body = ensure_parsed_body(resp.body)
        reasoning_details = extract_reasoning_details(body)

        {req, decoded_resp} =
          ReqLLM.Provider.Defaults.default_decode_response({req, %{resp | body: body}})

        {req, attach_reasoning_details_to_response(decoded_resp, reasoning_details)}

      _ ->
        ReqLLM.Provider.Defaults.default_decode_response(args)
    end
  end

  @impl ReqLLM.Provider
  def decode_stream_event(event, model) do
    event
    |> ReqLLM.Provider.Defaults.default_decode_stream_event(model)
    |> Enum.map(&normalize_stream_chunk/1)
  end

  @media_type_extensions %{
    "image/jpeg" => "jpg",
    "image/png" => "png",
    "image/webp" => "webp",
    "image/heic" => "heic",
    "image/heif" => "heif",
    "video/mp4" => "mp4",
    "video/quicktime" => "mov",
    "audio/wav" => "wav",
    "audio/mpeg" => "mp3"
  }

  defp upload_filename(media_type) do
    ext = Map.get(@media_type_extensions, media_type, "bin")
    "input.#{ext}"
  end

  @doc """
  Returns the API driver module for the given model's video operations.

  `MiniMax-H3*` models use the V2 API (`ReqLLM.Providers.Minimax.VideoAPI`);
  all other video models (Hailuo series, I2V-01*, T2V-01*) use the V1 API
  (`ReqLLM.Providers.Minimax.VideoAPIV1`).
  """
  @spec video_api_mod(LLMDB.Model.t()) :: module()
  def video_api_mod(model) do
    model_id = model.provider_model_id || model.id || ""

    if String.starts_with?(model_id, "MiniMax-H3") do
      ReqLLM.Providers.Minimax.VideoAPI
    else
      ReqLLM.Providers.Minimax.VideoAPIV1
    end
  end

  defp video_content(content) when is_list(content) do
    if Keyword.keyword?(content) do
      validate_video_prompt(content)
    else
      invalid_video_content()
    end
  end

  defp video_content(_content), do: invalid_video_content()

  defp validate_video_prompt(content) do
    prompt = Keyword.get(content, :prompt)

    if is_binary(prompt) and String.trim(prompt) != "" do
      {:ok, content}
    else
      {:error,
       ReqLLM.Error.Invalid.Parameter.exception(
         parameter: "video generation requires a non-empty :prompt in content"
       )}
    end
  end

  defp invalid_video_content do
    {:error,
     ReqLLM.Error.Invalid.Parameter.exception(
       parameter: "video content must be a keyword list with a :prompt"
     )}
  end

  defp image_context(prompt_or_messages, opts) do
    context_result =
      case Keyword.get(opts, :context) do
        %ReqLLM.Context{} = context -> {:ok, context}
        _ -> ReqLLM.Context.normalize(prompt_or_messages, opts)
      end

    with {:ok, context} <- context_result,
         {:ok, prompt} <- extract_image_prompt(context) do
      {:ok, context, prompt}
    end
  end

  defp extract_image_prompt(%ReqLLM.Context{messages: messages}) do
    last_user =
      messages
      |> Enum.reverse()
      |> Enum.find(&(&1.role == :user))

    prompt =
      case last_user do
        nil ->
          ""

        %ReqLLM.Message{content: content} when is_list(content) ->
          content
          |> Enum.filter(&(&1.type == :text))
          |> Enum.map_join("", & &1.text)

        %ReqLLM.Message{content: content} when is_binary(content) ->
          content

        _ ->
          ""
      end
      |> String.trim()

    if prompt == "" do
      {:error,
       ReqLLM.Error.Invalid.Parameter.exception(
         parameter: "image generation requires a non-empty user text prompt"
       )}
    else
      {:ok, prompt}
    end
  end

  defp unsupported_operation(operation) do
    supported_operations = [:chat, :object]

    {:error,
     ReqLLM.Error.Invalid.Parameter.exception(
       parameter:
         "operation: #{inspect(operation)} not supported by #{inspect(__MODULE__)}. Supported operations: #{inspect(supported_operations)}"
     )}
  end

  defp drop_ignored_option(opts, warnings, key) do
    if Keyword.has_key?(opts, key) do
      {
        Keyword.delete(opts, key),
        ["MiniMax ignores #{inspect(key)}; removed it from the request." | warnings]
      }
    else
      {opts, warnings}
    end
  end

  defp put_completion_token_limit(nil, opts), do: opts

  defp put_completion_token_limit(max_tokens, opts) do
    if Keyword.has_key?(opts, :max_completion_tokens) do
      opts
    else
      Keyword.put(opts, :max_completion_tokens, max_tokens)
    end
  end

  defp normalize_reasoning(model, opts, warnings) do
    effort_levels = minimax_effort_levels(model)

    {opts, warnings} = normalize_reasoning_effort(model, effort_levels, opts, warnings)
    {opts, warnings} = drop_reasoning_token_budget(opts, warnings)
    {opts, warnings} = normalize_thinking(model, opts, warnings)
    normalize_reasoning_split(model, opts, warnings)
  end

  defp normalize_reasoning_effort(model, effort_levels, opts, warnings) do
    case Keyword.pop(opts, :reasoning_effort) do
      {nil, opts} -> {opts, warnings}
      {:default, opts} -> {opts, warnings}
      {effort, opts} -> put_reasoning_effort(model, effort_levels, effort, opts, warnings)
    end
  end

  defp put_reasoning_effort(model, [], effort, opts, warnings) do
    {opts,
     [
       "#{model_label(model)} does not tune thinking depth; " <>
         "reasoning_effort #{inspect(effort)} was removed from the request."
       | warnings
     ]}
  end

  defp put_reasoning_effort(model, effort_levels, effort, opts, warnings) do
    effort = ReqLLM.Provider.Reasoning.normalize_effort(effort)

    cond do
      effort in effort_levels ->
        {Keyword.put(opts, :reasoning_effort, effort), warnings}

      effort in [:none, :minimal] ->
        level = if :low in effort_levels, do: :low, else: hd(effort_levels)

        {Keyword.put(opts, :reasoning_effort, level),
         [
           "#{model_label(model)} cannot skip thinking, so reasoning_effort #{inspect(effort)} " <>
             "was raised to #{inspect(level)}."
           | warnings
         ]}

      true ->
        {opts,
         [
           "#{model_label(model)} does not support reasoning_effort #{inspect(effort)}; " <>
             "the option was removed from the request."
           | warnings
         ]}
    end
  end

  defp drop_reasoning_token_budget(opts, warnings) do
    case Keyword.pop(opts, :reasoning_token_budget) do
      {nil, opts} ->
        {opts, warnings}

      {_budget, opts} ->
        {opts,
         [
           "MiniMax does not expose reasoning_token_budget on the OpenAI-compatible endpoint."
           | warnings
         ]}
    end
  end

  defp normalize_thinking(model, opts, warnings) do
    case Keyword.fetch(opts, :thinking) do
      {:ok, thinking} when is_map(thinking) ->
        if thinking_disabled?(thinking) and not thinking_off_supported?(model) do
          {Keyword.delete(opts, :thinking),
           ["#{model_label(model)} always thinks; thinking disabled was removed." | warnings]}
        else
          {opts, warnings}
        end

      _ ->
        {opts, warnings}
    end
  end

  defp normalize_reasoning_split(model, opts, warnings) do
    if Keyword.get(opts, :reasoning_split) == false and m3_1_flash?(model) do
      {Keyword.put(opts, :reasoning_split, true),
       ["#{model_label(model)} requires reasoning_split: true; it was forced to true." | warnings]}
    else
      {opts, warnings}
    end
  end

  defp thinking_disabled?(thinking) do
    type = Map.get(thinking, :type) || Map.get(thinking, "type")
    type in [:disabled, "disabled"]
  end

  defp thinking_off_supported?(%LLMDB.Model{} = model) do
    case get_in(model.capabilities || %{}, [:reasoning, :thinking]) do
      %{disable_supported: supported} when is_boolean(supported) -> supported
      _ -> not m3_1_flash?(model)
    end
  end

  defp thinking_off_supported?(_model), do: true

  defp minimax_effort_levels(%LLMDB.Model{} = model) do
    case effort_metadata(model) do
      values when is_list(values) and values != [] ->
        values
        |> Enum.map(&ReqLLM.Provider.Reasoning.normalize_effort/1)
        |> Enum.filter(&(is_atom(&1) and &1 != :default))

      _ ->
        if m3_1_flash?(model), do: [:low, :medium, :high, :xhigh, :max], else: []
    end
  end

  defp minimax_effort_levels(_model), do: []

  defp effort_metadata(model) do
    case get_in(model.capabilities || %{}, [:reasoning, :effort]) do
      %{values: values} = effort when is_list(values) ->
        if Map.get(effort, :supported) == false, do: [], else: values

      _ ->
        reasoning_option_values(model)
    end
  end

  defp reasoning_option_values(%LLMDB.Model{extra: extra}) when is_map(extra) do
    extra
    |> Map.get(:reasoning_options, Map.get(extra, "reasoning_options", []))
    |> Enum.find_value(fn
      %{"type" => "effort", "values" => values} when is_list(values) -> values
      %{type: "effort", values: values} when is_list(values) -> values
      _ -> nil
    end)
  end

  defp reasoning_option_values(_model), do: nil

  defp m3_1_flash?(%LLMDB.Model{} = model) do
    model
    |> model_id()
    |> String.starts_with?("MiniMax-M3.1")
  end

  defp m3_1_flash?(_model), do: false

  defp model_id(%LLMDB.Model{} = model), do: model.provider_model_id || model.id || ""

  defp model_label(%LLMDB.Model{} = model) do
    case model_id(model) do
      "" -> "This MiniMax model"
      id -> id
    end
  end

  defp model_label(_model), do: "This MiniMax model"

  defp provider_option(options, key) do
    option_value(options, key, nil) ||
      option_value(option_value(options, :provider_options, []), key, nil)
  end

  defp extract_reasoning_details(body) when is_map(body) do
    with %{"choices" => [first_choice | _]} <- body,
         %{"message" => %{"reasoning_details" => details}} when is_list(details) <- first_choice do
      normalize_reasoning_details(details)
    else
      _ -> nil
    end
  end

  defp extract_reasoning_details(_body), do: nil

  defp normalize_stream_chunk(%ReqLLM.StreamChunk{type: :meta, metadata: metadata} = chunk) do
    case metadata do
      %{reasoning_details: details} when is_list(details) ->
        %{chunk | metadata: %{metadata | reasoning_details: normalize_reasoning_details(details)}}

      _ ->
        chunk
    end
  end

  defp normalize_stream_chunk(chunk), do: chunk

  defp strip_reasoning_details_from_context(%Req.Request{options: options} = request) do
    case options[:context] do
      %ReqLLM.Context{messages: messages} = context ->
        stripped_messages =
          Enum.map(messages, fn
            %ReqLLM.Message{} = message -> %{message | reasoning_details: nil}
            message -> message
          end)

        put_in(request.options[:context], %{context | messages: stripped_messages})

      _ ->
        request
    end
  end

  defp encode_minimax_reasoning_history(body, %ReqLLM.Context{messages: context_messages}) do
    cond do
      is_list(Map.get(body, :messages)) ->
        %{body | messages: encode_minimax_messages_reasoning(body.messages, context_messages)}

      is_list(Map.get(body, "messages")) ->
        %{
          body
          | "messages" => encode_minimax_messages_reasoning(body["messages"], context_messages)
        }

      true ->
        body
    end
  end

  defp encode_minimax_reasoning_history(body, _context), do: body

  defp encode_minimax_messages_reasoning(encoded_messages, context_messages)
       when length(encoded_messages) == length(context_messages) do
    encoded_messages
    |> Enum.zip(context_messages)
    |> Enum.map(fn {encoded_message, context_message} ->
      encode_minimax_message_reasoning(encoded_message, context_message)
    end)
  end

  defp encode_minimax_messages_reasoning(encoded_messages, _context_messages),
    do: encoded_messages

  defp encode_minimax_message_reasoning(encoded_message, %ReqLLM.Message{
         reasoning_details: details
       })
       when is_list(details) do
    put_minimax_reasoning_details(encoded_message, encode_minimax_reasoning_details(details))
  end

  defp encode_minimax_message_reasoning(encoded_message, _context_message), do: encoded_message

  defp put_minimax_reasoning_details(message, []) when is_map(message) do
    message
    |> Map.delete(:reasoning_details)
    |> Map.delete("reasoning_details")
  end

  defp put_minimax_reasoning_details(%{} = message, details) do
    cond do
      Map.has_key?(message, :role) -> Map.put(message, :reasoning_details, details)
      Map.has_key?(message, "role") -> Map.put(message, "reasoning_details", details)
      true -> Map.put(message, :reasoning_details, details)
    end
  end

  defp encode_minimax_reasoning_details(details) do
    Enum.map(details, &encode_minimax_reasoning_detail/1)
  end

  defp encode_minimax_reasoning_detail(%ReqLLM.Message.ReasoningDetails{} = detail) do
    detail
    |> minimax_reasoning_detail_attrs()
    |> minimax_reasoning_detail_to_wire()
  end

  defp encode_minimax_reasoning_detail(%{provider: :minimax} = detail) do
    detail
    |> minimax_reasoning_detail_attrs()
    |> minimax_reasoning_detail_to_wire()
  end

  defp encode_minimax_reasoning_detail(%{"provider" => "minimax"} = detail) do
    detail
    |> minimax_reasoning_detail_attrs()
    |> minimax_reasoning_detail_to_wire()
  end

  defp encode_minimax_reasoning_detail(detail), do: detail

  defp minimax_reasoning_detail_attrs(%ReqLLM.Message.ReasoningDetails{} = detail) do
    %{
      provider_data: detail.provider_data,
      signature: detail.signature,
      format: detail.format || "minimax-response-v1",
      index: detail.index,
      text: detail.text
    }
  end

  defp minimax_reasoning_detail_attrs(detail) do
    %{
      provider_data: map_get(detail, :provider_data, "provider_data", %{}),
      signature: map_get(detail, :signature, "signature", nil),
      format: map_get(detail, :format, "format", "minimax-response-v1"),
      index: map_get(detail, :index, "index", 0),
      text: map_get(detail, :text, "text", nil)
    }
  end

  defp minimax_reasoning_detail_to_wire(attrs) do
    attrs.provider_data
    |> normalize_provider_data()
    |> Map.put_new("type", "reasoning.text")
    |> maybe_put_wire_field("id", attrs.signature)
    |> Map.put("format", attrs.format)
    |> Map.put("index", attrs.index)
    |> maybe_put_wire_field("text", attrs.text)
    |> drop_nil_values()
  end

  defp normalize_provider_data(data) when is_map(data) do
    Map.new(data, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_provider_data(_), do: %{}

  defp map_get(map, atom_key, string_key, default) do
    Map.get(map, atom_key, Map.get(map, string_key, default))
  end

  defp maybe_put_wire_field(map, _key, nil), do: map
  defp maybe_put_wire_field(map, key, value), do: Map.put(map, key, value)

  defp drop_nil_values(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end

  defp normalize_reasoning_details(details) do
    details
    |> Enum.with_index()
    |> Enum.map(&normalize_reasoning_detail/1)
  end

  defp normalize_reasoning_detail({%ReqLLM.Message.ReasoningDetails{} = detail, fallback_index}) do
    provider_data = normalize_provider_data(detail.provider_data)

    %ReqLLM.Message.ReasoningDetails{
      text: detail.text,
      signature: detail.signature || provider_data["id"],
      encrypted?: false,
      provider: :minimax,
      format: detail.format || "minimax-response-v1",
      index: detail.index || fallback_index,
      provider_data: Map.drop(provider_data, ["text", "id", "format", "index"])
    }
  end

  defp normalize_reasoning_detail({raw, fallback_index}) when is_map(raw) do
    %ReqLLM.Message.ReasoningDetails{
      text: raw["text"],
      signature: raw["id"],
      encrypted?: false,
      provider: :minimax,
      format: raw["format"] || "minimax-response-v1",
      index: raw["index"] || fallback_index,
      provider_data: Map.drop(raw, ["text", "id", "format", "index"])
    }
  end

  defp normalize_reasoning_detail({raw, fallback_index}) do
    %ReqLLM.Message.ReasoningDetails{
      text: inspect(raw),
      encrypted?: false,
      provider: :minimax,
      format: "minimax-response-v1",
      index: fallback_index,
      provider_data: %{}
    }
  end

  defp attach_reasoning_details_to_response(resp, nil), do: resp
  defp attach_reasoning_details_to_response(resp, []), do: resp

  defp attach_reasoning_details_to_response(
         %Req.Response{body: %ReqLLM.Response{} = body} = resp,
         details
       ) do
    case body.message do
      nil ->
        resp

      message ->
        updated_message = %{message | reasoning_details: details}

        updated_context =
          attach_reasoning_details_to_context(body.context, updated_message, details)

        updated_body = %{body | message: updated_message, context: updated_context}
        %{resp | body: updated_body}
    end
  end

  defp attach_reasoning_details_to_response(resp, _details), do: resp

  defp attach_reasoning_details_to_context(
         %ReqLLM.Context{messages: messages} = context,
         message,
         details
       ) do
    case messages do
      [] ->
        %{context | messages: [message]}

      _ ->
        {init, [last]} = Enum.split(messages, -1)

        if is_struct(last, ReqLLM.Message) and last.role == message.role do
          %{context | messages: init ++ [%{last | reasoning_details: details}]}
        else
          context
        end
    end
  end

  defp attach_reasoning_details_to_context(context, _message, _details), do: context

  defp ensure_parsed_body(body) when is_binary(body) do
    case ReqLLM.JSON.decode_wire(body) do
      {:ok, parsed} -> parsed
      {:error, _reason} -> body
    end
  end

  defp ensure_parsed_body(body), do: body

  defp option_value(options, key, default) when is_list(options),
    do: Keyword.get(options, key, default)

  defp option_value(options, key, default) when is_map(options),
    do: Map.get(options, key, default)

  defp option_value(_options, _key, default), do: default
end
