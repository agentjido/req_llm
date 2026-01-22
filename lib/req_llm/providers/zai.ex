defmodule ReqLLM.Providers.Zai do
  @moduledoc """
  Z.AI provider – OpenAI-compatible Chat Completions API (Standard Endpoint).

  ## Implementation

  Uses built-in OpenAI-style encoding/decoding defaults.
  No custom request/response handling needed – leverages the standard OpenAI wire format.

  This provider uses the Z.AI **standard endpoint** (`/api/paas/v4`) for general-purpose
  chat and reasoning tasks. For code generation optimized responses, use the `zai_coder`
  provider.

  ## Supported Models

  - glm-4.5 - Advanced reasoning model with 131K context
  - glm-4.5-air - Lighter variant with same capabilities
  - glm-4.5-flash - Free tier model with fast inference
  - glm-4.5v - Vision model supporting text, image, and video inputs
  - glm-4.6 - Latest model with 204K context and improved reasoning

  ## Configuration

      # Add to .env file (automatically loaded)
      ZAI_API_KEY=your-api-key
  """

  use ReqLLM.Provider,
    id: :zai,
    default_base_url: "https://api.z.ai/api/paas/v4",
    default_env_key: "ZAI_API_KEY"

  @provider_schema []

  @impl ReqLLM.Provider
  def prepare_request(operation, model_spec, input, opts) do
    ReqLLM.Provider.Defaults.prepare_request(__MODULE__, operation, model_spec, input, opts)
  end

  @impl ReqLLM.Provider
  def attach(request, model_input, user_opts) do
    context = Map.get(request.options, :context)

    default_timeout =
      if context && Map.get(context, :__thinking_mode__, false) do
        Application.get_env(:req_llm, :thinking_timeout, 300_000)
      else
        Application.get_env(:req_llm, :receive_timeout, 120_000)
      end

    timeout = Keyword.get(user_opts, :receive_timeout, default_timeout)

    updated_request =
      request
      |> Map.update!(:options, fn opts ->
        opts
        |> Map.put(:receive_timeout, timeout)
        |> Map.put(:pool_timeout, timeout)
        |> Map.put(:connect_options, timeout: timeout)
      end)

    ReqLLM.Provider.Defaults.default_attach(__MODULE__, updated_request, model_input, user_opts)
  end

  @impl ReqLLM.Provider
  def translate_options(_operation, _model, opts) do
    {translate_tool_choice(opts), []}
  end

  defp translate_tool_choice(opts) do
    case Keyword.get(opts, :tool_choice) do
      %{name: _name, type: _type} ->
        Keyword.put(opts, :tool_choice, "auto")

      %{type: "function", function: %{name: _name}} ->
        Keyword.put(opts, :tool_choice, "auto")

      _ ->
        opts
    end
  end

  @impl ReqLLM.Provider
  def decode_response({req, %{status: 200} = resp}) do
    model =
      req.private[:req_llm_model] || %LLMDB.Model{id: req.options[:model], provider: :zai}

    body = ensure_parsed_body(resp.body)

    {:ok, response} = ReqLLM.Provider.Defaults.decode_response_body_openai_format(body, model)

    case extract_usage(body, model) do
      {:ok, normalized_usage} ->
        updated_response = %{response | usage: normalized_usage}

        final_response =
          case req.options[:operation] do
            :object ->
              extract_and_set_object(updated_response, req)

            _ ->
              updated_response
          end

        merged_response = merge_response_with_context(req, final_response)
        {req, %{resp | body: merged_response}}

      {:error, _} ->
        merged_response = merge_response_with_context(req, response)
        {req, %{resp | body: merged_response}}
    end
  end

  def decode_response(request_response) do
    ReqLLM.Provider.Defaults.default_decode_response(request_response)
  end

  @impl ReqLLM.Provider
  def encode_body(request) do
    # Use default encoding but with ZAI-specific content part encoding
    body =
      case request.options[:operation] do
        :embedding ->
          encode_embedding_body(request)

        _ ->
          encode_zai_chat_body(request)
      end

    try do
      encoded_body = Jason.encode!(body)

      request
      |> Req.Request.put_header("content-type", "application/json")
      |> Map.put(:body, encoded_body)
    rescue
      error ->
        reraise error, __STACKTRACE__
    end
  end

  @impl ReqLLM.Provider
  def extract_usage(%{"usage" => usage, "choices" => choices}, _) do
    has_reasoning_content =
      Enum.any?(choices, fn choice ->
        case get_in(choice, ["message", "reasoning_content"]) do
          content when is_binary(content) and content != "" -> true
          _ -> false
        end
      end)

    completion_tokens = Map.get(usage, "completion_tokens", 0)
    prompt_tokens = Map.get(usage, "prompt_tokens", 0)
    total_tokens = Map.get(usage, "total_tokens", 0)

    cached_tokens =
      get_in(usage, ["prompt_tokens_details", "cached_tokens"]) ||
        Map.get(usage, "cached_tokens", 0)

    normalized_usage = %{
      input_tokens: prompt_tokens,
      output_tokens: completion_tokens,
      total_tokens: total_tokens,
      cached_tokens: cached_tokens,
      reasoning_tokens: if(has_reasoning_content, do: completion_tokens, else: 0)
    }

    {:ok, normalized_usage}
  end

  def extract_usage(%{"usage" => u}, _), do: {:ok, u}
  def extract_usage(_, _), do: {:error, :no_usage}

  # Private helper functions

  defp ensure_parsed_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, parsed} -> parsed
      {:error, _} -> %{}
    end
  end

  defp ensure_parsed_body(body) when is_map(body), do: body
  defp ensure_parsed_body(_), do: %{}

  defp merge_response_with_context(req, response) do
    case req.options[:context] do
      %ReqLLM.Context{messages: existing_messages} = ctx when is_list(existing_messages) ->
        new_message = response.message
        updated_context = %{ctx | messages: existing_messages ++ [new_message]}
        %{response | context: updated_context}

      _ ->
        response
    end
  end

  defp extract_and_set_object(response, req) do
    provider_opts = req.options[:provider_options] || []
    response_format = provider_opts[:response_format]

    extracted_object =
      case response_format do
        %{type: "json_schema"} ->
          extract_from_json_schema_content(response)

        %{"type" => "json_schema"} ->
          extract_from_json_schema_content(response)

        _ ->
          extract_from_tool_calls(response)
      end

    %{response | object: extracted_object}
  end

  defp extract_from_json_schema_content(response) do
    %ReqLLM.Message{content: content_parts} = response.message

    text_content =
      content_parts
      |> Enum.find_value(fn
        %ReqLLM.Message.ContentPart{type: :text, text: text} when is_binary(text) -> text
        _ -> nil
      end)

    case text_content do
      nil ->
        nil

      json_string ->
        case Jason.decode(json_string) do
          {:ok, parsed_object} -> parsed_object
          {:error, _} -> nil
        end
    end
  end

  defp extract_from_tool_calls(response) do
    case response.message do
      %ReqLLM.Message{tool_calls: [%ReqLLM.ToolCall{function: %{arguments: args_json}} | _]}
      when is_binary(args_json) ->
        case Jason.decode(args_json) do
          {:ok, args} -> args
          {:error, _} -> nil
        end

      _ ->
        nil
    end
  end

  defp encode_zai_chat_body(request) do
    context_data =
      case request.options[:context] do
        %ReqLLM.Context{} = ctx ->
          model_name = request.options[:model]
          encode_context_to_zai_format(ctx, model_name)

        _ ->
          %{messages: request.options[:messages] || []}
      end

    model_name = request.options[:model]

    body =
      %{model: model_name}
      |> Map.merge(context_data)
      |> add_basic_options(request.options)
      |> ReqLLM.Provider.Utils.maybe_put(:stream, request.options[:stream])
      |> then(fn body ->
        if request.options[:stream],
          do: Map.put(body, :stream_options, %{include_usage: true}),
          else: body
      end)
      |> ReqLLM.Provider.Utils.maybe_put(:max_tokens, request.options[:max_tokens])

    body =
      case request.options[:tools] do
        tools when is_list(tools) and tools != [] ->
          body = Map.put(body, :tools, Enum.map(tools, &ReqLLM.Tool.to_schema(&1, :openai)))

          case request.options[:tool_choice] do
            nil -> body
            choice -> Map.put(body, :tool_choice, choice)
          end

        _ ->
          body
      end

    provider_opts = request.options[:provider_options] || []
    response_format = request.options[:response_format] || provider_opts[:response_format]

    case response_format do
      format when is_map(format) -> Map.put(body, :response_format, format)
      _ -> body
    end
  end

  defp encode_context_to_zai_format(%ReqLLM.Context{messages: messages}, _model_name) do
    %{
      messages: Enum.map(messages, &encode_zai_message/1)
    }
  end

  defp encode_zai_message(%ReqLLM.Message{role: r, content: c, tool_calls: tc}) do
    # Separate tool calls from other content
    {tool_call_parts, other_content} =
      Enum.split_with(c, fn part -> part.type == :tool_call end)

    # Encode non-tool-call content
    encoded_content = encode_zai_content(other_content)

    # Build base message with content
    base_message = %{
      role: to_string(r),
      content: encoded_content
    }

    # Add tool_calls array if we have tool call ContentParts
    base_message =
      if tool_call_parts == [] do
        base_message
      else
        zai_tool_calls =
          Enum.map(tool_call_parts, fn part ->
            %{
              id: part.tool_call_id,
              type: "function",
              function: %{
                name: part.tool_name,
                arguments: Jason.encode!(part.input)
              }
            }
          end)

        Map.put(base_message, :tool_calls, zai_tool_calls)
      end

    # Also add tool_calls field from Message if present (though usually tool calls are in content)
    case tc do
      nil -> base_message
      [] -> base_message
      calls -> Map.put(base_message, :tool_calls, calls)
    end
  end

  defp encode_zai_content(content) when is_list(content) do
    content
    |> Enum.map(&encode_zai_content_part/1)
    |> maybe_flatten_single_text()
  end

  defp maybe_flatten_single_text([%{type: "text", text: text}]), do: text

  defp maybe_flatten_single_text(content) do
    filtered = Enum.reject(content, &is_nil/1)

    case filtered do
      [%{type: "text", text: text}] -> text
      _ -> filtered
    end
  end

  # ZAI content part encoding (tool calls are handled at message level, not in content)
  defp encode_zai_content_part(%ReqLLM.Message.ContentPart{type: :text, text: text}) do
    %{type: "text", text: text}
  end

  # Skip thinking ContentParts - ZAI doesn't support this type in content
  defp encode_zai_content_part(%ReqLLM.Message.ContentPart{type: :thinking}) do
    nil
  end

  # Skip tool_call ContentParts - they're handled at message level
  defp encode_zai_content_part(%ReqLLM.Message.ContentPart{type: :tool_call}) do
    nil
  end

  defp encode_zai_content_part(%ReqLLM.Message.ContentPart{
         type: :image,
         data: data,
         media_type: media_type
       }) do
    base64 = Base.encode64(data)

    %{
      type: "image_url",
      image_url: %{
        url: "data:#{media_type};base64,#{base64}"
      }
    }
  end

  defp encode_zai_content_part(%ReqLLM.Message.ContentPart{type: :image_url, url: url}) do
    %{
      type: "image_url",
      image_url: %{
        url: url
      }
    }
  end

  defp encode_zai_content_part(_), do: nil

  defp encode_embedding_body(request) do
    input = request.options[:text]
    provider_opts = request.options[:provider_options] || []

    %{
      model: request.options[:model],
      input: input
    }
    |> ReqLLM.Provider.Utils.maybe_put(:user, request.options[:user])
    |> ReqLLM.Provider.Utils.maybe_put(:dimensions, provider_opts[:dimensions])
    |> ReqLLM.Provider.Utils.maybe_put(:encoding_format, provider_opts[:encoding_format])
  end

  defp add_basic_options(body, request_options) do
    body_options = [
      :temperature,
      :top_p,
      :frequency_penalty,
      :presence_penalty,
      :user,
      :seed,
      :stop
    ]

    Enum.reduce(body_options, body, fn key, acc ->
      ReqLLM.Provider.Utils.maybe_put(acc, key, request_options[key])
    end)
  end
end
