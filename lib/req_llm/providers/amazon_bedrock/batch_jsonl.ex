defmodule ReqLLM.Providers.AmazonBedrock.BatchJSONL do
  @moduledoc false

  alias ReqLLM.{Context, Error, Message}
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Provider.Options
  alias ReqLLM.Providers.AmazonBedrock.Converse

  @doc false
  def encode_jsonl(model, records, opts) do
    with {:ok, opts} <- inference_options(opts),
         {:ok, lines, _ids} <-
           Enum.reduce_while(
             records,
             {:ok, [], MapSet.new()},
             &encode_record(&1, &2, model, opts)
           ) do
      case lines do
        [] -> {:error, invalid_parameter("a batch must contain at least one record")}
        _ -> {:ok, Enum.reverse(lines)}
      end
    end
  end

  @doc false
  def decode_jsonl(model, lines) do
    results = lines |> Stream.with_index(1) |> Stream.map(&decode_line(&1, model.id))
    {:ok, results}
  end

  defp inference_options(opts) do
    with true <- Keyword.keyword?(opts),
         {:ok, opts} <-
           Options.validate_generation_options(opts,
             only: [:max_tokens, :temperature, :top_p, :stop]
           ) do
      {stop, opts} = Keyword.pop(opts, :stop)
      {:ok, Keyword.put(opts, :stop_sequences, stop && List.wrap(stop))}
    else
      false -> {:error, invalid_parameter("expected a keyword list of inference options")}
      {:error, error} -> {:error, invalid_parameter(Exception.message(error))}
    end
  end

  defp encode_record({id, prompt}, {:ok, lines, ids}, model, opts)
       when is_binary(id) and id != "" do
    with false <- MapSet.member?(ids, id),
         {:ok, context} <- Context.normalize(prompt),
         {:ok, body} <- encode_input(context, model, opts),
         {:ok, encoded} <- Jason.encode_to_iodata(%{"recordId" => id, "modelInput" => body}) do
      {:cont, {:ok, [[encoded, ?\n] | lines], MapSet.put(ids, id)}}
    else
      true -> {:halt, {:error, invalid_parameter("duplicate batch record ID #{inspect(id)}")}}
      {:error, reason} -> {:halt, {:error, invalid_record(id, reason)}}
    end
  end

  defp encode_record(_record, _acc, _model, _opts) do
    {:halt,
     {:error, invalid_parameter("expected a {record_id, prompt} with a non-empty string ID")}}
  end

  defp encode_input(%Context{messages: messages, tools: tools} = context, model, opts) do
    if tools in [nil, []] and Enum.all?(messages, &text_message?/1) do
      body = Converse.format_request(model.provider_model_id || model.id, context, opts)

      if text_input?(body),
        do: {:ok, body},
        else: {:error, "expected text-only Converse input with a user message"}
    else
      {:error, "Bedrock batch records support text-only prompts"}
    end
  rescue
    error in Error.Invalid.Parameter -> {:error, error}
  end

  defp text_message?(%Message{role: role, content: [_ | _] = parts} = message)
       when role in [:user, :assistant, :system] do
    message.tool_calls in [nil, []] and message.reasoning_details in [nil, []] and
      Enum.all?(
        parts,
        &match?(%ContentPart{type: :text, text: text} when is_binary(text) and text != "", &1)
      )
  end

  defp text_message?(_message), do: false

  defp decode_line({line, number}, model_id) when is_binary(line) do
    case Jason.decode(line) do
      {:ok, %{"recordId" => id} = row} when is_binary(id) and id != "" ->
        {id, decode_row(row, number, model_id)}

      {:ok, _row} ->
        {nil, {:error, row_error(number, "missing batch record ID")}}

      {:error, _error} ->
        {nil, {:error, row_error(number, "invalid JSON")}}
    end
  end

  defp decode_line({_line, number}, _model_id),
    do: {nil, {:error, row_error(number, "expected a complete JSONL line")}}

  defp decode_row(%{"error" => error}, _number, _model) when is_map(error) do
    {:error,
     Error.API.Request.exception(
       reason: error["errorMessage"] || "Bedrock batch record failed",
       provider_code: error["errorCode"],
       response_body: error
     )}
  end

  defp decode_row(
         %{"modelOutput" => %{"output" => %{"message" => %{"content" => content}}} = body} = row,
         number,
         model_id
       )
       when is_list(content) do
    with {:ok, context} <- response_context(row["modelInput"], number) do
      Converse.parse_response(body, model: model_id, context: context)
    end
  rescue
    _error -> {:error, row_error(number, "invalid Converse response")}
  end

  defp decode_row(_row, number, _model),
    do: {:error, row_error(number, "expected a Converse modelOutput or an error")}

  defp response_context(nil, _number), do: {:ok, Context.new()}

  defp response_context(input, number) do
    if text_input?(input) do
      system = Map.get(input, "system", [])
      system_messages = if system == [], do: [], else: [Context.system(content_parts(system))]

      messages =
        Enum.map(input["messages"], fn
          %{"role" => "user", "content" => blocks} ->
            Context.user(content_parts(blocks))

          %{"role" => "assistant", "content" => blocks} ->
            Context.assistant(content_parts(blocks))
        end)

      {:ok, Context.new(system_messages ++ messages)}
    else
      {:error, row_error(number, "invalid text-only Converse modelInput")}
    end
  end

  defp text_input?(%{"messages" => [_ | _] = messages} = input) do
    Enum.any?(messages, &match?(%{"role" => "user"}, &1)) and
      Enum.all?(messages, &text_turn?/1) and text_blocks?(Map.get(input, "system", [])) and
      not Map.has_key?(input, "toolConfig")
  end

  defp text_input?(_input), do: false

  defp text_turn?(%{"role" => role, "content" => [_ | _] = blocks})
       when role in ["user", "assistant"],
       do: text_blocks?(blocks)

  defp text_turn?(_turn), do: false

  defp text_blocks?(blocks) when is_list(blocks) do
    Enum.all?(blocks, &match?(%{"text" => text} when is_binary(text) and text != "", &1))
  end

  defp text_blocks?(_blocks), do: false

  defp content_parts(blocks), do: Enum.map(blocks, &ContentPart.text(&1["text"]))

  defp invalid_record(id, reason) when is_binary(reason),
    do: invalid_parameter("batch record #{inspect(id)}: #{reason}")

  defp invalid_record(id, reason) when is_exception(reason),
    do: invalid_record(id, Exception.message(reason))

  defp invalid_record(id, _reason), do: invalid_record(id, "invalid prompt")

  defp invalid_parameter(reason), do: Error.Invalid.Parameter.exception(parameter: reason)

  defp row_error(number, reason),
    do: Error.API.Response.exception(reason: "Bedrock batch output line #{number}: #{reason}")
end
