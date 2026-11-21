defmodule ReqLLM.Providers.Google.InteractionsAPI.Encoder do
  @moduledoc false

  alias ReqLLM.Context
  alias ReqLLM.Error.Invalid.Parameter
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Providers.Google
  alias ReqLLM.Providers.Google.InteractionsAPI.Helpers
  alias ReqLLM.Providers.Google.InteractionsAPI.StepHistory
  alias ReqLLM.Tool
  alias ReqLLM.ToolCall
  alias ReqLLM.ToolResult

  @builtin_tool_types ~w(
    google_search
    code_execution
    url_context
    mcp_server
    file_search
    google_maps
    computer_use
  )

  @singleton_builtin_tool_types ~w(
    google_search
    code_execution
    url_context
    file_search
    google_maps
    computer_use
  )

  @tool_choice_modes %{
    :auto => "auto",
    "auto" => "auto",
    :any => "any",
    "any" => "any",
    :required => "any",
    "required" => "any",
    :none => "none",
    "none" => "none",
    :validated => "validated",
    "validated" => "validated"
  }

  def build_request_body(model_or_id, %Context{} = context, opts) when is_list(opts) do
    case ReqLLM.ProviderFileReference.validate_context(context, :google) do
      :ok -> :ok
      {:error, error} -> raise error
    end

    agent = Helpers.get_opt(opts, :agent)
    {system_instruction, chat_messages} = split_system_messages(context.messages, opts)
    input = compile_input!(chat_messages, context.messages, opts)

    base =
      if Helpers.non_empty_binary?(agent) do
        %{"agent" => agent, "input" => input}
        |> Helpers.maybe_put_map("agent_config", Helpers.get_opt(opts, :agent_config))
        |> maybe_put_environment(Helpers.get_opt(opts, :environment))
      else
        model_id = Helpers.normalize_model_id(model_or_id)
        tools = encode_tools(opts)

        %{"model" => model_id, "input" => input}
        |> Helpers.maybe_put_string("system_instruction", system_instruction)
        |> Helpers.maybe_put_non_empty_map(
          "generation_config",
          build_generation_config(model_or_id, opts)
        )
        |> Helpers.maybe_put_non_empty_list("tools", tools)
        |> maybe_put_response_format(opts)
        |> Helpers.maybe_put_list(
          "safety_settings",
          encode_safety_settings(Helpers.get_opt(opts, :google_safety_settings))
        )
      end

    base
    |> Helpers.maybe_put_string(
      "previous_interaction_id",
      Helpers.get_opt(opts, :previous_interaction_id)
    )
    |> Helpers.maybe_put_boolean("store", Helpers.get_opt(opts, :store))
    |> Helpers.maybe_put_boolean("background", Helpers.get_opt(opts, :background))
    |> Helpers.maybe_put_true("stream", Keyword.get(opts, :stream))
    |> maybe_put_service_tier(Helpers.get_opt(opts, :service_tier))
    |> Helpers.maybe_put_string("continuation_token", Helpers.get_opt(opts, :continuation_token))
    |> Helpers.maybe_put_map("labels", Helpers.get_opt(opts, :labels))
  end

  def split_system_messages(messages, opts) do
    {system_msgs, chat_msgs} = Enum.split_with(messages, &(&1.role == :system))

    system_instruction =
      system_msgs
      |> Enum.map(&extract_message_text/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    resolved_system =
      case system_instruction do
        "" ->
          case Keyword.get(opts, :system_prompt) do
            prompt when is_binary(prompt) and prompt != "" -> prompt
            _ -> nil
          end

        text ->
          text
      end

    {resolved_system, chat_msgs}
  end

  defp compile_input!(chat_messages, all_messages, opts) do
    prev_id = Helpers.get_opt(opts, :previous_interaction_id)

    if Helpers.non_empty_binary?(prev_id) do
      delta = StepHistory.select_stateful_delta(chat_messages, prev_id)
      encode_delta_input!(delta, all_messages)
    else
      encode_stateless_input!(chat_messages, all_messages)
    end
  end

  defp encode_delta_input!([], _all_messages) do
    raise Parameter,
      parameter: "previous_interaction_id requires a follow-up user message or tool result"
  end

  defp encode_delta_input!([%Message{role: :user} = msg], _all_messages) do
    encode_single_user_input!(msg)
  end

  defp encode_delta_input!(messages, all_messages) do
    if match?(%Message{role: :assistant}, List.last(messages)) do
      raise Parameter,
        parameter: "previous_interaction_id requires a follow-up user message or tool result"
    end

    encode_step_list!(messages, all_messages)
  end

  defp encode_stateless_input!([], _all_messages) do
    raise Parameter, parameter: "Interactions API requires at least one non-system message"
  end

  defp encode_stateless_input!([%Message{role: :user, tool_calls: calls} = msg], _all_messages)
       when calls in [nil, []] do
    encode_single_user_input!(msg)
  end

  defp encode_stateless_input!(messages, all_messages) do
    encode_step_list!(messages, all_messages)
  end

  defp encode_single_user_input!(%Message{content: nil}), do: ""
  defp encode_single_user_input!(%Message{content: []}), do: ""
  defp encode_single_user_input!(%Message{content: content}) when is_binary(content), do: content

  defp encode_single_user_input!(%Message{
         content: [%ContentPart{type: :text, text: text, metadata: meta}]
       })
       when is_binary(text) and map_size(meta) == 0 do
    text
  end

  defp encode_single_user_input!(%Message{content: parts}) when is_list(parts) do
    case encode_non_empty_content_parts!(parts) do
      [] -> ""
      encoded -> encoded
    end
  end

  defp encode_step_list!(messages, all_messages) do
    Enum.flat_map(messages, &encode_message_steps!(&1, all_messages))
  end

  defp encode_message_steps!(%Message{role: :user} = msg, _all_messages) do
    [%{"type" => "user_input", "content" => encode_user_message_content!(msg)}]
  end

  defp encode_message_steps!(%Message{role: :assistant} = msg, _all_messages) do
    case StepHistory.verified_interactions_steps(msg) do
      [_ | _] = steps ->
        steps

      nil ->
        reconstruct_assistant_steps!(msg)
    end
  end

  defp encode_message_steps!(%Message{role: :tool} = msg, all_messages) do
    [encode_function_result_step!(msg, all_messages)]
  end

  defp encode_message_steps!(%Message{role: role}, _all_messages) do
    raise Parameter, parameter: "Unsupported message role for Interactions API: #{inspect(role)}"
  end

  defp reconstruct_assistant_steps!(%Message{} = msg) do
    {content_steps, remaining_details, matched_step_indices} =
      encode_ordered_assistant_content(msg.content, List.wrap(msg.reasoning_details))

    {leading_details, trailing_details} =
      split_remaining_thoughts(remaining_details, matched_step_indices)

    leading_thoughts =
      leading_details
      |> Enum.map(&encode_reasoning_detail_step/1)
      |> Enum.reject(&is_nil/1)

    trailing_thoughts =
      trailing_details
      |> Enum.map(&encode_reasoning_detail_step/1)
      |> Enum.reject(&is_nil/1)

    call_steps = encode_assistant_function_call_steps(msg.tool_calls)

    case leading_thoughts ++ content_steps ++ trailing_thoughts ++ call_steps do
      [] -> [%{"type" => "model_output", "content" => [%{"type" => "text", "text" => ""}]}]
      steps -> steps
    end
  end

  defp split_remaining_thoughts(remaining_details, []), do: {remaining_details, []}

  defp split_remaining_thoughts(remaining_details, matched_step_indices) do
    max_matched = Enum.max(matched_step_indices)

    Enum.split_with(remaining_details, fn detail ->
      case detail_step_index(detail) do
        idx when is_integer(idx) -> idx <= max_matched
        _ -> true
      end
    end)
  end

  defp encode_ordered_assistant_content(content, details)
       when is_binary(content) and content != "" do
    {[%{"type" => "model_output", "content" => [%{"type" => "text", "text" => content}]}],
     details, []}
  end

  defp encode_ordered_assistant_content(parts, details) when is_list(parts) do
    encode_assistant_parts(parts, details, [], [], [])
  end

  defp encode_ordered_assistant_content(_content, details), do: {[], details, []}

  defp encode_assistant_parts([], details_acc, rev_steps, rev_pending_output, rev_matched_indices) do
    final_steps = rev_steps |> flush_pending_model_output(rev_pending_output) |> Enum.reverse()
    {final_steps, details_acc, Enum.reverse(rev_matched_indices)}
  end

  defp encode_assistant_parts(
         [%ContentPart{type: :thinking} = part | rest_parts],
         details_acc,
         steps_acc,
         output_acc,
         matched_indices_acc
       ) do
    steps_acc = flush_pending_model_output(steps_acc, output_acc)

    {thought_step, next_details, matched_idx} =
      match_thinking_part_step(part, details_acc, rest_parts)

    next_steps = if(thought_step, do: [thought_step | steps_acc], else: steps_acc)

    next_indices =
      if(is_integer(matched_idx),
        do: [matched_idx | matched_indices_acc],
        else: matched_indices_acc
      )

    encode_assistant_parts(rest_parts, next_details, next_steps, [], next_indices)
  end

  defp encode_assistant_parts(
         [%ContentPart{type: :provider_block, data: block, metadata: meta} | rest_parts],
         details_acc,
         steps_acc,
         output_acc,
         matched_indices_acc
       )
       when is_map(block) do
    {next_steps, next_output} =
      encode_assistant_provider_block(block, meta, steps_acc, output_acc)

    encode_assistant_parts(rest_parts, details_acc, next_steps, next_output, matched_indices_acc)
  end

  defp encode_assistant_parts(
         [%ContentPart{type: :provider_block} | rest_parts],
         details_acc,
         steps_acc,
         output_acc,
         matched_indices_acc
       ) do
    encode_assistant_parts(rest_parts, details_acc, steps_acc, output_acc, matched_indices_acc)
  end

  defp encode_assistant_parts(
         [%ContentPart{type: :text, text: ""} = part | rest_parts],
         details_acc,
         steps_acc,
         output_acc,
         matched_indices_acc
       ) do
    next_output =
      case Map.get(part.metadata || %{}, :annotations) ||
             Map.get(part.metadata || %{}, "annotations") do
        anns when is_list(anns) and anns != [] -> [encode_content_part!(part) | output_acc]
        _ -> output_acc
      end

    encode_assistant_parts(rest_parts, details_acc, steps_acc, next_output, matched_indices_acc)
  end

  defp encode_assistant_parts(
         [%ContentPart{type: :text, text: nil} | rest_parts],
         details_acc,
         steps_acc,
         output_acc,
         matched_indices_acc
       ) do
    encode_assistant_parts(rest_parts, details_acc, steps_acc, output_acc, matched_indices_acc)
  end

  defp encode_assistant_parts(
         [%ContentPart{} = part | rest_parts],
         details_acc,
         steps_acc,
         output_acc,
         matched_indices_acc
       ) do
    encode_assistant_parts(
      rest_parts,
      details_acc,
      steps_acc,
      [encode_content_part!(part) | output_acc],
      matched_indices_acc
    )
  end

  defp encode_assistant_provider_block(block, meta, steps_acc, output_acc) do
    meta_map = meta || %{}
    provider = Map.get(meta_map, :provider) || Map.get(meta_map, "provider")
    api = Map.get(meta_map, :api) || Map.get(meta_map, "api")

    content_item? =
      Map.get(meta_map, :content_item) == true or Map.get(meta_map, "content_item") == true

    block_type = Map.get(block, "type") || Map.get(block, :type)

    cond do
      provider in [:google, "google"] and api in [nil, :interactions, "interactions"] and
        Helpers.non_empty_binary?(block_type) and content_item? ->
        {steps_acc, [Helpers.stringify_keys(block) | output_acc]}

      provider in [:google, "google"] and api in [nil, :interactions, "interactions"] and
          Helpers.non_empty_binary?(block_type) ->
        flushed = flush_pending_model_output(steps_acc, output_acc)
        {[Helpers.stringify_keys(block) | flushed], []}

      true ->
        {steps_acc, output_acc}
    end
  end

  defp match_thinking_part_step(%ContentPart{} = part, details_acc, rest_parts) do
    part_sig = thinking_part_signature(part)
    {later_sigs, later_texts} = reserved_later_thinking(rest_parts)

    case pop_matching_detail(details_acc, part_sig, part.text, later_sigs, later_texts) do
      {:ok, detail, rest} ->
        step = encode_matched_detail_step(detail, part)
        {step, rest, detail_step_index(detail)}

      :none ->
        {encode_thinking_part_step(part), details_acc, nil}
    end
  end

  defp thinking_part_signature(%ContentPart{metadata: meta}) do
    meta_map = meta || %{}
    Map.get(meta_map, :signature) || Map.get(meta_map, "signature")
  end

  defp reserved_later_thinking(rest_parts) do
    Enum.reduce(rest_parts, {MapSet.new(), MapSet.new()}, fn
      %ContentPart{type: :thinking} = part, {sigs, texts} ->
        sig = thinking_part_signature(part)

        cond do
          Helpers.non_empty_binary?(sig) ->
            {MapSet.put(sigs, sig), texts}

          is_binary(part.text) and part.text != "" ->
            {sigs, MapSet.put(texts, part.text)}

          true ->
            {sigs, texts}
        end

      _other, acc ->
        acc
    end)
  end

  defp reserved_detail_sig?(detail, later_sigs) do
    sig = detail_signature(detail)
    Helpers.non_empty_binary?(sig) and MapSet.member?(later_sigs, sig)
  end

  defp reserved_detail_text?(detail, later_texts) do
    text = detail_text(detail)
    is_binary(text) and text != "" and MapSet.member?(later_texts, text)
  end

  defp pop_matching_detail([], _part_sig, _part_text, _later_sigs, _later_texts), do: :none

  defp pop_matching_detail(details, part_sig, _part_text, _later_sigs, _later_texts)
       when is_binary(part_sig) and part_sig != "" do
    pop_first_matching(details, &(detail_signature(&1) == part_sig))
  end

  defp pop_matching_detail(details, _part_sig, part_text, later_sigs, _later_texts)
       when is_binary(part_text) and part_text != "" do
    case pop_first_matching(details, fn d ->
           detail_text(d) == part_text and not reserved_detail_sig?(d, later_sigs)
         end) do
      {:ok, _detail, _rest} = found ->
        found

      :none ->
        pop_first_matching(details, fn d ->
          detail_text(d) in [nil, ""] and
            Helpers.non_empty_binary?(detail_signature(d)) and
            not reserved_detail_sig?(d, later_sigs)
        end)
    end
  end

  defp pop_matching_detail(details, _part_sig, _part_text, later_sigs, later_texts) do
    pop_first_matching(details, fn d ->
      not reserved_detail_sig?(d, later_sigs) and not reserved_detail_text?(d, later_texts)
    end)
  end

  defp pop_first_matching(list, pred) do
    pop_first_matching(list, pred, [])
  end

  defp pop_first_matching([], _pred, _prefix_rev), do: :none

  defp pop_first_matching([head | tail], pred, prefix_rev) do
    if pred.(head) do
      {:ok, head, Enum.reverse(prefix_rev, tail)}
    else
      pop_first_matching(tail, pred, [head | prefix_rev])
    end
  end

  defp encode_matched_detail_step(detail, %ContentPart{} = part) do
    case encode_reasoning_detail_step(detail) do
      nil ->
        encode_thinking_part_step(part)

      %{} = step ->
        if not Map.has_key?(step, "summary") and is_binary(part.text) and part.text != "" do
          maybe_put_thought_summary(step, part.text)
        else
          step
        end
    end
  end

  defp detail_text(%Message.ReasoningDetails{text: text}), do: text

  defp detail_text(detail) when is_map(detail),
    do: Map.get(detail, :text) || Map.get(detail, "text")

  defp detail_text(_), do: nil

  defp detail_signature(%Message.ReasoningDetails{signature: sig}), do: sig

  defp detail_signature(detail) when is_map(detail) do
    Map.get(detail, :signature) || Map.get(detail, "signature")
  end

  defp detail_signature(_), do: nil

  defp detail_step_index(%Message.ReasoningDetails{provider_data: %{"step_index" => idx}})
       when is_integer(idx),
       do: idx

  defp detail_step_index(%Message.ReasoningDetails{provider_data: %{step_index: idx}})
       when is_integer(idx),
       do: idx

  defp detail_step_index(%{provider_data: %{"step_index" => idx}}) when is_integer(idx), do: idx
  defp detail_step_index(%{provider_data: %{step_index: idx}}) when is_integer(idx), do: idx
  defp detail_step_index(_), do: nil

  defp flush_pending_model_output(steps_acc, []), do: steps_acc

  defp flush_pending_model_output(steps_acc, rev_output_parts) do
    step = %{"type" => "model_output", "content" => Enum.reverse(rev_output_parts)}
    [step | steps_acc]
  end

  defp encode_reasoning_detail_step(%Message.ReasoningDetails{text: text, signature: signature}) do
    build_thought_step(text, signature)
  end

  defp encode_reasoning_detail_step(detail) when is_map(detail) do
    text = Map.get(detail, :text) || Map.get(detail, "text")
    signature = Map.get(detail, :signature) || Map.get(detail, "signature")
    build_thought_step(text, signature)
  end

  defp encode_reasoning_detail_step(_detail), do: nil

  defp encode_thinking_part_step(%ContentPart{text: text, metadata: meta}) do
    signature = Map.get(meta || %{}, :signature) || Map.get(meta || %{}, "signature")
    build_thought_step(text, signature)
  end

  defp build_thought_step(text, signature) do
    step =
      %{"type" => "thought"}
      |> Helpers.maybe_put_string("signature", signature)
      |> maybe_put_thought_summary(text)

    if map_size(step) > 1, do: step, else: nil
  end

  defp maybe_put_thought_summary(step, text) when is_binary(text) and text != "" do
    Map.put(step, "summary", [%{"type" => "text", "text" => text}])
  end

  defp maybe_put_thought_summary(step, _text), do: step

  defp encode_assistant_function_call_steps(nil), do: []

  defp encode_assistant_function_call_steps(tool_calls) when is_list(tool_calls) do
    tool_calls
    |> Enum.reject(&ToolCall.builtin?/1)
    |> Enum.map(fn %ToolCall{} = tc ->
      meta = ToolCall.metadata(tc)

      signature =
        Map.get(meta, :signature) ||
          Map.get(meta, "signature") ||
          Map.get(meta, :thought_signature) ||
          Map.get(meta, "thought_signature")

      %{
        "type" => "function_call",
        "id" => tc.id,
        "name" => ToolCall.name(tc),
        "arguments" => ToolCall.args_map(tc) || %{}
      }
      |> Helpers.maybe_put_string("signature", signature)
    end)
  end

  defp encode_safety_settings(nil), do: nil

  defp encode_safety_settings(settings) do
    Enum.map(settings, fn setting ->
      setting = Helpers.stringify_keys(setting)
      {category, setting} = Map.pop(setting, "category")
      type = setting["type"] || normalize_safety_enum(category, "harm_category_")

      setting
      |> Map.put("type", type)
      |> Map.update("threshold", nil, fn
        "BLOCK_NONE" -> "off"
        threshold -> normalize_safety_enum(threshold, "")
      end)
      |> Map.replace_lazy("method", &normalize_safety_enum(&1, "harm_block_method_"))
    end)
  end

  defp normalize_safety_enum(value, prefix) when is_binary(value),
    do: value |> String.downcase() |> String.replace_prefix(prefix, "")

  defp normalize_safety_enum(value, _prefix), do: value

  defp encode_function_result_step!(%Message{} = msg, all_messages) do
    call_id = msg.tool_call_id

    if not Helpers.non_empty_binary?(call_id) do
      raise Parameter,
        parameter: "tool result message requires :tool_call_id for Interactions API"
    end

    name = resolve_tool_result_name(msg, call_id, all_messages)
    result = encode_tool_result_payload!(msg)
    meta = msg.metadata || %{}
    is_error? = Map.get(meta, :is_error) == true or Map.get(meta, "is_error") == true

    %{"type" => "function_result", "call_id" => call_id, "result" => result}
    |> Helpers.maybe_put_string("name", name)
    |> Helpers.maybe_put_true("is_error", is_error?)
  end

  defp resolve_tool_result_name(%Message{name: name}, _call_id, _all_messages)
       when is_binary(name) and name != "",
       do: name

  defp resolve_tool_result_name(_msg, call_id, all_messages) do
    all_messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %Message{role: :assistant, tool_calls: calls} when is_list(calls) ->
        Enum.find_value(calls, fn
          %ToolCall{id: ^call_id} = tc -> ToolCall.name(tc)
          _ -> nil
        end)

      _ ->
        nil
    end)
  end

  defp encode_tool_result_payload!(%Message{} = msg) do
    output = ToolResult.output_from_message(msg)

    cond do
      ToolResult.explicit_content?(msg) and is_list(msg.content) ->
        encode_tool_result_content!(msg.content)

      is_map(output) ->
        [%{"type" => "text", "text" => output |> Helpers.stringify_keys() |> Jason.encode!()}]

      is_binary(output) ->
        output

      is_list(output) ->
        output |> Helpers.stringify_keys() |> Jason.encode!()

      output != nil ->
        case String.Chars.impl_for(output) do
          nil -> inspect(output)
          _impl -> to_string(output)
        end

      is_binary(msg.content) ->
        msg.content

      is_list(msg.content) and msg.content != [] ->
        encode_tool_result_content!(msg.content)

      true ->
        ""
    end
  end

  defp encode_tool_result_content!(parts) do
    Enum.map(parts, fn
      %ContentPart{type: :text, text: text} ->
        %{"type" => "text", "text" => text || ""}

      %ContentPart{} = part ->
        encode_content_part!(part)
    end)
  end

  defp encode_user_message_content!(%Message{content: content}) when is_binary(content) do
    [%{"type" => "text", "text" => content}]
  end

  defp encode_user_message_content!(%Message{content: parts}) when is_list(parts) do
    encode_content_parts!(parts)
  end

  defp encode_user_message_content!(_msg), do: [%{"type" => "text", "text" => ""}]

  defp encode_content_parts!(parts) when is_list(parts) do
    case encode_non_empty_content_parts!(parts) do
      [] -> [%{"type" => "text", "text" => ""}]
      encoded -> encoded
    end
  end

  defp encode_non_empty_content_parts!(parts) when is_list(parts) do
    Enum.flat_map(parts, fn
      %ContentPart{type: :text, text: ""} -> []
      %ContentPart{type: :text, text: nil} -> []
      %ContentPart{} = part -> [encode_content_part!(part)]
    end)
  end

  defp encode_content_part!(%ContentPart{type: :text, text: text, metadata: meta}) do
    base = %{"type" => "text", "text" => text}

    case Map.get(meta || %{}, :annotations) || Map.get(meta || %{}, "annotations") do
      anns when is_list(anns) and anns != [] ->
        Map.put(base, "annotations", Helpers.stringify_keys(anns))

      _ ->
        base
    end
  end

  defp encode_content_part!(%ContentPart{type: :image, data: data, media_type: mime} = part)
       when is_binary(data) and data != "" do
    media_type = mime || "image/png"
    build_media_block!("image", "data", Base.encode64(data), media_type, part.metadata)
  end

  defp encode_content_part!(%ContentPart{type: :file, data: data, media_type: mime} = part)
       when is_binary(data) and data != "" do
    media_type = mime || metadata_mime_type(part.metadata) || "application/pdf"
    block_type = metadata_interactions_type(part.metadata) || media_block_type!(media_type)
    build_media_block!(block_type, "data", Base.encode64(data), media_type, part.metadata)
  end

  defp encode_content_part!(%ContentPart{type: :file, file_id: uri, media_type: mime} = part)
       when is_binary(uri) and uri != "" do
    media_type = mime || metadata_mime_type(part.metadata) || infer_mime_from_uri(uri)

    block_type =
      metadata_interactions_type(part.metadata) ||
        if(media_type, do: media_block_type!(media_type), else: "document")

    build_media_block!(block_type, "uri", uri, media_type, part.metadata)
  end

  defp encode_content_part!(%ContentPart{type: :file, url: uri, media_type: mime} = part)
       when is_binary(uri) and uri != "" do
    if String.starts_with?(uri, "data:") do
      encode_data_uri_block!(:file, uri, part.metadata)
    else
      media_type = mime || metadata_mime_type(part.metadata) || infer_mime_from_uri(uri)

      block_type =
        metadata_interactions_type(part.metadata) ||
          if(media_type, do: media_block_type!(media_type), else: "document")

      build_media_block!(block_type, "uri", uri, media_type, part.metadata)
    end
  end

  defp encode_content_part!(%ContentPart{type: type, url: uri, media_type: mime} = part)
       when type in [:image_url, :video_url] and is_binary(uri) and uri != "" do
    if String.starts_with?(uri, "data:") do
      encode_data_uri_block!(type, uri, part.metadata)
    else
      explicit_mime = mime || metadata_mime_type(part.metadata)
      inferred = explicit_mime || infer_mime_from_uri(uri)
      default_type = if(type == :video_url, do: "video", else: "image")

      block_type =
        cond do
          is_binary(explicit_mime) -> media_block_type!(explicit_mime)
          is_binary(inferred) -> url_media_block_type(inferred, default_type)
          true -> default_type
        end

      media_mime =
        if(
          block_type == default_type and is_nil(explicit_mime) and not media_mimes?(inferred),
          do: nil,
          else: inferred
        )

      build_media_block!(block_type, "uri", uri, media_mime, part.metadata)
    end
  end

  defp encode_content_part!(%ContentPart{type: type})
       when type in [:image, :file, :image_url, :video_url] do
    raise Parameter,
      parameter:
        "ContentPart #{inspect(type)} requires non-empty data, file_id, or url for Interactions API"
  end

  defp encode_content_part!(%ContentPart{type: other}) do
    raise Parameter,
      parameter: "Unsupported ContentPart type for Interactions API: #{inspect(other)}"
  end

  defp encode_data_uri_block!(_part_type, uri, metadata) do
    case String.split(uri, ",", parts: 2) do
      ["data:" <> header_body, payload] ->
        {mime, base64?} = parse_data_uri_header(header_body)
        encoded_data = if(base64?, do: payload, else: Base.encode64(URI.decode(payload)))
        block_type = media_block_type!(mime)
        build_media_block!(block_type, "data", encoded_data, mime, metadata)

      _ ->
        raise Parameter, parameter: "Malformed data URI in Interactions input"
    end
  end

  defp parse_data_uri_header(header_body) do
    segments = String.split(header_body, ";")
    last = List.last(segments) || ""
    base64? = String.downcase(String.trim(last)) == "base64"

    mime_segments = if(base64?, do: Enum.drop(segments, -1), else: segments)

    mime =
      case mime_segments do
        [first | _] ->
          trimmed = String.trim(first)
          if(trimmed == "" or String.contains?(trimmed, "="), do: "text/plain", else: trimmed)

        [] ->
          "text/plain"
      end

    {mime, base64?}
  end

  defp metadata_mime_type(meta) when is_map(meta) do
    Map.get(meta, :mime_type) || Map.get(meta, "mime_type")
  end

  defp metadata_mime_type(_), do: nil

  defp metadata_interactions_type(meta) when is_map(meta) do
    case Map.get(meta, :interactions_type) || Map.get(meta, "interactions_type") do
      type when type in ["image", "audio", "video", "document"] -> type
      _ -> nil
    end
  end

  defp metadata_interactions_type(_), do: nil

  defp build_media_block!(type, source_key, value, mime_type, metadata) do
    block = %{"type" => type, source_key => value}

    block =
      if(Helpers.non_empty_binary?(mime_type),
        do: Map.put(block, "mime_type", mime_type),
        else: block
      )

    case Map.get(metadata || %{}, :resolution) || Map.get(metadata || %{}, "resolution") do
      nil ->
        block

      resolution ->
        Map.put(block, "resolution", to_string(resolution))
    end
  end

  defp media_block_type!("image/" <> _), do: "image"
  defp media_block_type!("audio/" <> _), do: "audio"
  defp media_block_type!("video/" <> _), do: "video"
  defp media_block_type!("application/pdf"), do: "document"
  defp media_block_type!("text/" <> _), do: "document"
  defp media_block_type!(_), do: "document"

  defp url_media_block_type("image/" <> _, _default), do: "image"
  defp url_media_block_type("audio/" <> _, _default), do: "audio"
  defp url_media_block_type("video/" <> _, _default), do: "video"
  defp url_media_block_type("application/pdf", _default), do: "document"
  defp url_media_block_type(_, default), do: default

  defp media_mimes?(mime) when is_binary(mime) do
    String.starts_with?(mime, ["image/", "audio/", "video/"]) or mime == "application/pdf"
  end

  defp media_mimes?(_), do: false

  defp infer_mime_from_uri(uri) do
    case URI.parse(uri) do
      %URI{path: path} when is_binary(path) and path != "" ->
        case MIME.from_path(path) do
          "application/octet-stream" -> nil
          mime -> mime
        end

      _ ->
        nil
    end
  end

  defp build_generation_config(model, opts) do
    thinking_level =
      normalize_thinking_level(Helpers.get_opt(opts, :google_thinking_level), model)

    thinking_budget =
      case Helpers.get_opt(opts, :google_thinking_budget) do
        nil -> Keyword.get(opts, :reasoning_token_budget)
        budget -> budget
      end

    if thinking_level != nil and thinking_budget != nil do
      raise Parameter,
        parameter:
          "google_thinking_budget and google_thinking_level cannot be combined in the same request"
    end

    thinking_configured? =
      thinking_level not in [nil, "minimal"] or
        (is_integer(thinking_budget) and thinking_budget > 0)

    %{}
    |> Helpers.maybe_put_int("max_output_tokens", Keyword.get(opts, :max_tokens))
    |> Helpers.maybe_put_non_empty_list(
      "stop_sequences",
      normalize_stop_sequences(Keyword.get(opts, :stop))
    )
    |> Helpers.maybe_put_int("seed", Keyword.get(opts, :seed))
    |> Helpers.maybe_put_number("temperature", Keyword.get(opts, :temperature))
    |> Helpers.maybe_put_number("top_p", Keyword.get(opts, :top_p))
    |> Helpers.maybe_put_int("top_k", Keyword.get(opts, :top_k))
    |> maybe_put_tool_choice(Keyword.get(opts, :tool_choice))
    |> Helpers.maybe_put_string("thinking_level", thinking_level)
    |> Helpers.maybe_put_int("thinking_budget", thinking_budget)
    |> maybe_put_thinking_summaries(opts, thinking_configured?)
  end

  defp normalize_stop_sequences(nil), do: nil
  defp normalize_stop_sequences(stop) when is_binary(stop) and stop != "", do: [stop]

  defp normalize_stop_sequences(stops) when is_list(stops),
    do: Enum.filter(stops, &Helpers.non_empty_binary?/1)

  defp normalize_stop_sequences(_), do: nil

  defp maybe_put_tool_choice(config, nil), do: config

  defp maybe_put_tool_choice(config, choice) when is_atom(choice) or is_binary(choice) do
    case Map.fetch(@tool_choice_modes, choice) do
      {:ok, mode} ->
        Map.put(config, "tool_choice", mode)

      :error ->
        raise Parameter,
          parameter: "Unsupported tool_choice mode for Interactions API: #{inspect(choice)}"
    end
  end

  defp maybe_put_tool_choice(config, choice) when is_list(choice) do
    if Keyword.keyword?(choice) and choice != [] do
      maybe_put_tool_choice(config, Helpers.keywords_to_maps(choice))
    else
      raise Parameter,
        parameter: "Unsupported tool_choice for Interactions API: #{inspect(choice)}"
    end
  end

  defp maybe_put_tool_choice(config, %{} = choice) do
    normalized = choice |> Helpers.keywords_to_maps() |> Helpers.stringify_keys()

    fn_name =
      case normalized["function"] do
        %{"name" => name} -> non_empty_name(name)
        _ -> nil
      end

    top_name = non_empty_name(normalized["name"])

    cond do
      Map.has_key?(normalized, "allowed_tools") ->
        Map.put(config, "tool_choice", normalized)

      fn_name != nil ->
        Map.put(config, "tool_choice", %{
          "allowed_tools" => %{
            "mode" => "any",
            "tools" => [fn_name]
          }
        })

      top_name != nil ->
        Map.put(config, "tool_choice", %{
          "allowed_tools" => %{
            "mode" => "any",
            "tools" => [top_name]
          }
        })

      true ->
        raise Parameter,
          parameter: "Unsupported tool_choice map for Interactions API: #{inspect(choice)}"
    end
  end

  defp maybe_put_tool_choice(_config, choice) do
    raise Parameter, parameter: "Unsupported tool_choice for Interactions API: #{inspect(choice)}"
  end

  defp non_empty_name(val) when is_binary(val) and val != "", do: val

  defp non_empty_name(val) when is_atom(val) and val not in [nil, true, false] do
    Atom.to_string(val)
  end

  defp non_empty_name(_val), do: nil

  defp normalize_thinking_level(nil, _model), do: nil

  defp normalize_thinking_level(level, model) do
    normalized = level |> to_string() |> String.trim() |> String.downcase()

    cond do
      normalized not in ~w(minimal low medium high xhigh) ->
        raise Parameter,
          parameter: "Unsupported google_thinking_level for Interactions API: #{inspect(level)}"

      normalized == "xhigh" and not Google.supports_xhigh_thinking?(model) ->
        raise Parameter,
          parameter:
            "google_thinking_level #{inspect(level)} is not supported for this Gemini model"

      true ->
        normalized
    end
  end

  defp maybe_put_thinking_summaries(config, opts, thinking_configured?) do
    has_explicit_flag? = Helpers.explicit_option?(opts, :google_include_thoughts)
    include_thoughts = Helpers.get_opt(opts, :google_include_thoughts)
    operation = Keyword.get(opts, :operation)

    cond do
      has_explicit_flag? ->
        Map.put(config, "thinking_summaries", if(include_thoughts, do: "auto", else: "none"))

      thinking_configured? ->
        Map.put(config, "thinking_summaries", if(operation == :object, do: "none", else: "auto"))

      true ->
        config
    end
  end

  defp maybe_put_response_format(body, opts) do
    operation = Keyword.get(opts, :operation)
    compiled_schema = Keyword.get(opts, :compiled_schema)
    explicit_format = opts |> Helpers.get_opt(:response_format) |> Helpers.keywords_to_maps()

    cond do
      operation == :object and compiled_schema != nil ->
        raw_schema =
          case compiled_schema do
            %{schema: inner_schema, compiled: _} -> inner_schema
            other -> other
          end

        schema =
          raw_schema
          |> ReqLLM.Schema.to_json()
          |> Helpers.strip_schema_meta()

        Map.put(body, "response_format", %{
          "type" => "text",
          "mime_type" => "application/json",
          "schema" => schema
        })

      is_map(explicit_format) ->
        normalized =
          explicit_format
          |> Helpers.stringify_keys()
          |> normalize_explicit_response_format()

        Map.put(body, "response_format", normalized)

      is_list(explicit_format) and explicit_format != [] ->
        normalized =
          Enum.map(explicit_format, fn fmt ->
            fmt |> Helpers.stringify_keys() |> normalize_explicit_response_format()
          end)

        Map.put(body, "response_format", normalized)

      true ->
        body
    end
  end

  defp normalize_explicit_response_format(%{"type" => type})
       when type in ["json_object", :json_object] do
    %{"type" => "text", "mime_type" => "application/json"}
  end

  defp normalize_explicit_response_format(%{"type" => type} = map)
       when type in ["json_schema", :json_schema] do
    schema_obj = Map.get(map, "json_schema") || %{}
    schema = Map.get(schema_obj, "schema") || Map.get(map, "schema")
    base = %{"type" => "text", "mime_type" => "application/json"}

    if is_map(schema) do
      Map.put(base, "schema", Helpers.strip_schema_meta(schema))
    else
      base
    end
  end

  defp normalize_explicit_response_format(%{"schema" => %{} = schema} = other) do
    other
    |> stringify_format_type()
    |> Map.put("schema", Helpers.strip_schema_meta(schema))
  end

  defp normalize_explicit_response_format(%{} = other), do: stringify_format_type(other)
  defp normalize_explicit_response_format(other), do: other

  defp stringify_format_type(%{"type" => type} = map) when is_atom(type) and not is_nil(type) do
    Map.put(map, "type", Atom.to_string(type))
  end

  defp stringify_format_type(map), do: map

  defp encode_tools(opts) do
    explicit_tools =
      opts
      |> Keyword.get(:tools, [])
      |> List.wrap()
      |> Enum.map(&encode_tool!/1)

    option_tools = builtin_tools_from_options(opts)
    merge_tool_declarations(explicit_tools, option_tools)
  end

  defp encode_tool!(%Tool{} = tool) do
    if tool.parameter_schema in [nil, []] do
      %{"type" => "function", "name" => tool.name}
      |> Helpers.maybe_put_string("description", tool.description)
    else
      schema = Tool.to_schema(tool, :openai)
      fn_def = schema["function"]

      base =
        %{"type" => "function", "name" => fn_def["name"]}
        |> Helpers.maybe_put_string("description", fn_def["description"])

      case Helpers.strip_schema_meta(fn_def["parameters"]) do
        nil -> base
        params -> Map.put(base, "parameters", params)
      end
    end
  end

  defp encode_tool!(%{} = tool_map) do
    normalized = Helpers.stringify_keys(tool_map)
    tool_type = if(normalized["type"], do: to_string(normalized["type"]), else: nil)
    normalized = if(tool_type, do: Map.put(normalized, "type", tool_type), else: normalized)

    cond do
      tool_type in @builtin_tool_types ->
        normalized

      tool_type == "function" and is_map(normalized["function"]) ->
        fn_def = normalized["function"]
        name = validate_function_tool_name!(fn_def["name"], tool_map)

        %{"type" => "function", "name" => name}
        |> Helpers.maybe_put_string("description", fn_def["description"])
        |> Helpers.maybe_put_map("parameters", Helpers.strip_schema_meta(fn_def["parameters"]))

      tool_type == "function" ->
        validate_function_tool_name!(normalized["name"], tool_map)

        case normalized["parameters"] do
          %{} = params -> Map.put(normalized, "parameters", Helpers.strip_schema_meta(params))
          _ -> normalized
        end

      true ->
        raise Parameter,
          parameter: "Unsupported tool declaration for Interactions API: #{inspect(tool_map)}"
    end
  end

  defp encode_tool!(tool) do
    raise Parameter,
      parameter: "Unsupported tool declaration for Interactions API: #{inspect(tool)}"
  end

  defp validate_function_tool_name!(name, _tool_map) when is_binary(name) do
    if Helpers.non_empty_binary?(name) do
      name
    else
      raise Parameter, parameter: "Function tool declaration requires a non-empty \"name\""
    end
  end

  defp validate_function_tool_name!(_name, _tool_map) do
    raise Parameter, parameter: "Function tool declaration requires a non-empty \"name\""
  end

  defp builtin_tools_from_options(opts) do
    []
    |> maybe_append_google_search_tool(opts)
    |> maybe_append_simple_builtin(opts, :google_code_execution, "code_execution")
    |> maybe_append_simple_builtin(opts, :google_url_context, "url_context")
    |> maybe_append_file_search_tool(opts)
    |> maybe_append_mcp_server_tools(opts)
  end

  defp maybe_append_google_search_tool(tools, opts) do
    grounding = Helpers.get_opt(opts, :google_grounding)
    search_types = Helpers.get_opt(opts, :google_search_types)

    cond do
      is_list(search_types) and search_types != [] ->
        tools ++
          [%{"type" => "google_search", "search_types" => Enum.map(search_types, &to_string/1)}]

      is_map(grounding) and map_size(grounding) > 0 and Map.get(grounding, :enable) != false and
          Map.get(grounding, "enable") != false ->
        tool =
          case grounding[:search_types] || grounding["search_types"] do
            types when is_list(types) and types != [] ->
              %{"type" => "google_search", "search_types" => Enum.map(types, &to_string/1)}

            _ ->
              %{"type" => "google_search"}
          end

        tools ++ [tool]

      true ->
        tools
    end
  end

  defp maybe_append_simple_builtin(tools, opts, opt_key, tool_type) do
    case Helpers.get_opt(opts, opt_key) do
      true ->
        tools ++ [%{"type" => tool_type}]

      %{} = config ->
        if Map.get(config, :enable) == false or Map.get(config, "enable") == false do
          tools
        else
          tool =
            config
            |> Map.drop([:enable, "enable"])
            |> Helpers.stringify_keys()
            |> Map.put("type", tool_type)

          tools ++ [tool]
        end

      _ ->
        tools
    end
  end

  defp maybe_append_file_search_tool(tools, opts) do
    case Helpers.get_opt(opts, :google_file_search) do
      %{} = config when map_size(config) > 0 ->
        tool = config |> Helpers.stringify_keys() |> Map.put("type", "file_search")
        tools ++ [tool]

      _ ->
        tools
    end
  end

  defp maybe_append_mcp_server_tools(tools, opts) do
    case Helpers.get_opt(opts, :google_mcp_servers) do
      servers when is_list(servers) and servers != [] ->
        encoded =
          Enum.map(servers, fn server ->
            server |> Helpers.stringify_keys() |> Map.put("type", "mcp_server")
          end)

        tools ++ encoded

      _ ->
        tools
    end
  end

  defp merge_tool_declarations(explicit_tools, option_tools) do
    existing_singletons =
      explicit_tools
      |> Enum.map(& &1["type"])
      |> Enum.filter(&(&1 in @singleton_builtin_tool_types))
      |> MapSet.new()

    existing_mcp_names =
      explicit_tools
      |> Enum.filter(&(&1["type"] == "mcp_server" and is_binary(&1["name"])))
      |> MapSet.new(& &1["name"])

    filtered_options =
      Enum.reject(option_tools, fn tool ->
        (tool["type"] in @singleton_builtin_tool_types and
           MapSet.member?(existing_singletons, tool["type"])) or
          (tool["type"] == "mcp_server" and is_binary(tool["name"]) and
             MapSet.member?(existing_mcp_names, tool["name"]))
      end)

    dedup_option_tools =
      filtered_options
      |> Enum.reduce({[], MapSet.new(), MapSet.new()}, fn tool, {acc, seen_types, seen_mcp} ->
        type = tool["type"]
        mcp_name = if(type == "mcp_server", do: tool["name"], else: nil)

        cond do
          type in @singleton_builtin_tool_types and MapSet.member?(seen_types, type) ->
            {acc, seen_types, seen_mcp}

          type in @singleton_builtin_tool_types ->
            {[tool | acc], MapSet.put(seen_types, type), seen_mcp}

          is_binary(mcp_name) and MapSet.member?(seen_mcp, mcp_name) ->
            {acc, seen_types, seen_mcp}

          is_binary(mcp_name) ->
            {[tool | acc], seen_types, MapSet.put(seen_mcp, mcp_name)}

          true ->
            {[tool | acc], seen_types, seen_mcp}
        end
      end)
      |> elem(0)
      |> Enum.reverse()

    explicit_tools ++ dedup_option_tools
  end

  defp maybe_put_environment(map, val) when is_binary(val) and val != "",
    do: Map.put(map, "environment", val)

  defp maybe_put_environment(map, val) when is_map(val),
    do: Map.put(map, "environment", Helpers.stringify_keys(val))

  defp maybe_put_environment(map, _val), do: map

  defp maybe_put_service_tier(map, nil), do: map

  defp maybe_put_service_tier(map, tier)
       when is_atom(tier) and tier not in [nil, true, false] do
    Helpers.maybe_put_string(map, "service_tier", Atom.to_string(tier))
  end

  defp maybe_put_service_tier(map, tier) when is_binary(tier) do
    if Helpers.non_empty_binary?(tier), do: Map.put(map, "service_tier", tier), else: map
  end

  defp maybe_put_service_tier(map, _tier), do: map

  defp extract_message_text(%Message{content: content}) when is_binary(content), do: content

  defp extract_message_text(%Message{content: parts}) when is_list(parts) do
    Enum.map_join(parts, "", fn
      %ContentPart{type: :text, text: text} when is_binary(text) -> text
      _ -> ""
    end)
  end

  defp extract_message_text(_), do: ""
end
