defmodule ReqLLM.Providers.Minimax do
  @moduledoc """
  MiniMax provider using the OpenAI-compatible Chat Completions API.

  MiniMax exposes an OpenAI-compatible endpoint at `https://api.minimax.io/v1`.
  This provider reuses the shared OpenAI wire-format implementation and adds
  MiniMax-specific option handling:

  - `max_tokens` is translated to `max_completion_tokens`
  - `reasoning_split` defaults to `true` so reasoning is returned as structured
    `reasoning_details` and can be preserved across turns
  - unsupported OpenAI parameters that MiniMax ignores are removed before the
    request is sent

  ## Configuration

      MINIMAX_API_KEY=your-api-key

  ## Examples

      ReqLLM.generate_text("minimax:MiniMax-M2.7", "Hello!")

      ReqLLM.stream_text("minimax:MiniMax-M2.7-highspeed", "Tell me a story",
        max_tokens: 512
      )
  """

  use ReqLLM.Provider,
    id: :minimax,
    default_base_url: "https://api.minimax.io/v1",
    default_env_key: "MINIMAX_API_KEY"

  use ReqLLM.Provider.Defaults

  import ReqLLM.Provider.Utils, only: [maybe_put: 3]

  @provider_schema [
    max_completion_tokens: [
      type: :pos_integer,
      doc: "Maximum generated tokens. MiniMax uses max_completion_tokens instead of max_tokens."
    ],
    reasoning_split: [
      type: :boolean,
      default: true,
      doc: "Return thinking content in reasoning_details instead of inline <think> tags."
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

  def prepare_request(operation, model_spec, input, opts) do
    ReqLLM.Provider.Defaults.prepare_request(__MODULE__, operation, model_spec, input, opts)
  end

  @impl ReqLLM.Provider
  def translate_options(_operation, _model, opts) do
    warnings = []

    opts =
      opts
      |> Keyword.put_new(:reasoning_split, true)
      |> Keyword.put_new(
        :receive_timeout,
        Application.get_env(:req_llm, :thinking_timeout, 300_000)
      )

    {max_tokens, opts} = Keyword.pop(opts, :max_tokens)

    {opts, warnings} =
      if max_tokens && !Keyword.has_key?(opts, :max_completion_tokens) do
        warning =
          "MiniMax uses max_completion_tokens; translated max_tokens to max_completion_tokens."

        {Keyword.put(opts, :max_completion_tokens, max_tokens), [warning | warnings]}
      else
        {opts, warnings}
      end

    {opts, warnings} = drop_ignored_option(opts, warnings, :presence_penalty)
    {opts, warnings} = drop_ignored_option(opts, warnings, :frequency_penalty)
    {opts, warnings} = drop_ignored_option(opts, warnings, :seed)
    {opts, warnings} = drop_unsupported_reasoning_options(opts, warnings)

    {opts, Enum.reverse(warnings)}
  end

  @impl ReqLLM.Provider
  def build_body(request) do
    reasoning_split = option_value(request.options, :reasoning_split, true)

    request
    |> ReqLLM.Provider.Defaults.default_build_body()
    |> encode_minimax_reasoning_history()
    |> Map.delete(:max_tokens)
    |> Map.delete("max_tokens")
    |> maybe_put(:max_completion_tokens, request.options[:max_completion_tokens])
    |> maybe_put(:reasoning_split, reasoning_split)
  end

  @impl ReqLLM.Provider
  def decode_response({req, resp} = args) do
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
  def attach_stream(model, context, opts, finch_name) do
    processed_opts =
      ReqLLM.Provider.Options.process_stream!(
        __MODULE__,
        opts[:operation] || :chat,
        model,
        context,
        opts
      )

    base_url = ReqLLM.Provider.Options.effective_base_url(__MODULE__, model, processed_opts)
    opts_with_base_url = Keyword.put(processed_opts, :base_url, base_url)

    ReqLLM.Provider.Defaults.default_attach_stream(
      __MODULE__,
      model,
      context,
      opts_with_base_url,
      finch_name
    )
  end

  @impl ReqLLM.Provider
  def decode_stream_event(event, model) do
    event
    |> ReqLLM.Provider.Defaults.default_decode_stream_event(model)
    |> Enum.map(&normalize_stream_chunk/1)
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

  defp drop_unsupported_reasoning_options(opts, warnings) do
    {reasoning_effort, opts} = Keyword.pop(opts, :reasoning_effort)
    {reasoning_token_budget, opts} = Keyword.pop(opts, :reasoning_token_budget)

    warnings =
      if reasoning_effort && reasoning_effort != :default do
        ["MiniMax uses model-native thinking; reasoning_effort is not sent." | warnings]
      else
        warnings
      end

    warnings =
      if reasoning_token_budget do
        [
          "MiniMax does not expose reasoning_token_budget on the OpenAI-compatible endpoint."
          | warnings
        ]
      else
        warnings
      end

    {opts, warnings}
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

  defp encode_minimax_reasoning_history(%{messages: messages} = body) when is_list(messages) do
    %{body | messages: Enum.map(messages, &encode_minimax_message_reasoning/1)}
  end

  defp encode_minimax_reasoning_history(%{"messages" => messages} = body)
       when is_list(messages) do
    %{body | "messages" => Enum.map(messages, &encode_minimax_message_reasoning/1)}
  end

  defp encode_minimax_reasoning_history(body), do: body

  defp encode_minimax_message_reasoning(%{reasoning_details: details} = message)
       when is_list(details) do
    %{message | reasoning_details: encode_minimax_reasoning_details(details)}
  end

  defp encode_minimax_message_reasoning(%{"reasoning_details" => details} = message)
       when is_list(details) do
    %{message | "reasoning_details" => encode_minimax_reasoning_details(details)}
  end

  defp encode_minimax_message_reasoning(message), do: message

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
    case Jason.decode(body) do
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
