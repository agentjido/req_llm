defmodule ReqLLM.Providers.OpenAICodex.ResponsesLite do
  @moduledoc false

  @header "x-openai-internal-codex-responses-lite"
  @hosted_tool_types ~w(web_search web_search_preview file_search mcp x_search code_interpreter image_generation)
  @remote_image_omission "image content omitted because remote image URLs are not supported"

  @bundled_model_metadata %{
    "gpt-5.6-sol" => %{use_responses_lite: true},
    "gpt-5.6-terra" => %{use_responses_lite: true},
    "gpt-5.6-luna" => %{use_responses_lite: true}
  }

  @spec enabled?(LLMDB.Model.t()) :: boolean()
  def enabled?(%LLMDB.Model{} = model) do
    case model_metadata_value(model, :use_responses_lite) do
      enabled when is_boolean(enabled) -> enabled
      _other -> bundled_model_value(model, :use_responses_lite) == true
    end
  end

  @spec apply_body(map(), LLMDB.Model.t()) :: map()
  def apply_body(body, %LLMDB.Model{} = model) when is_map(body) do
    if enabled?(model), do: apply_lite_contract(body), else: body
  end

  @spec put_req_header(Req.Request.t(), LLMDB.Model.t()) :: Req.Request.t()
  def put_req_header(request, %LLMDB.Model{} = model) do
    if enabled?(model) do
      Req.Request.put_header(request, @header, "true")
    else
      request
    end
  end

  @spec put_header([{String.t(), String.t()}], LLMDB.Model.t()) ::
          [{String.t(), String.t()}]
  def put_header(headers, %LLMDB.Model{} = model) when is_list(headers) do
    if enabled?(model), do: [{@header, "true"} | headers], else: headers
  end

  defp apply_lite_contract(body) do
    tools = body |> Map.get("tools") |> List.wrap() |> client_executed_tools()
    instructions = Map.get(body, "instructions", "")

    input =
      [%{"type" => "additional_tools", "role" => "developer", "tools" => tools}]
      |> maybe_add_instructions(instructions)
      |> Kernel.++(body |> Map.get("input") |> List.wrap() |> prepare_images())

    body
    |> Map.put("input", input)
    |> Map.delete("instructions")
    |> Map.delete("tools")
    |> Map.delete("previous_response_id")
    |> Map.put("parallel_tool_calls", false)
    |> Map.update("reasoning", %{"context" => "all_turns"}, &put_reasoning_context/1)
  end

  defp maybe_add_instructions(prefix, instructions)
       when is_binary(instructions) and instructions != "" do
    prefix ++
      [
        %{
          "type" => "message",
          "role" => "developer",
          "content" => [%{"type" => "input_text", "text" => instructions}]
        }
      ]
  end

  defp maybe_add_instructions(prefix, _instructions), do: prefix

  defp put_reasoning_context(reasoning) when is_map(reasoning),
    do: Map.put(reasoning, "context", "all_turns")

  defp put_reasoning_context(_reasoning), do: %{"context" => "all_turns"}

  defp client_executed_tools(tools) do
    Enum.reject(tools, fn tool -> tool_type(tool) in @hosted_tool_types end)
  end

  defp tool_type(%{"type" => type}) when is_atom(type), do: Atom.to_string(type)
  defp tool_type(%{"type" => type}), do: type
  defp tool_type(%{type: type}) when is_atom(type), do: Atom.to_string(type)
  defp tool_type(%{type: type}), do: type
  defp tool_type(_tool), do: nil

  defp prepare_images(items) when is_list(items), do: Enum.map(items, &prepare_images/1)

  defp prepare_images(%{"type" => "input_image", "image_url" => "data:" <> _rest} = item) do
    item
    |> Map.delete("detail")
    |> Map.new(fn {key, value} -> {key, prepare_images(value)} end)
  end

  defp prepare_images(%{"type" => "input_image", "image_url" => image_url})
       when is_binary(image_url) do
    %{"type" => "input_text", "text" => @remote_image_omission}
  end

  defp prepare_images(%{"type" => "input_image"} = item) do
    Map.delete(item, "detail")
  end

  defp prepare_images(%{} = item) do
    Map.new(item, fn {key, value} -> {key, prepare_images(value)} end)
  end

  defp prepare_images(value), do: value

  defp model_metadata_value(%LLMDB.Model{extra: extra}, key) when is_map(extra) do
    metadata = Map.get(extra, :openai_codex) || Map.get(extra, "openai_codex") || %{}

    case Map.fetch(metadata, key) do
      {:ok, value} -> value
      :error -> Map.get(metadata, Atom.to_string(key))
    end
  end

  defp model_metadata_value(_model, _key), do: nil

  defp bundled_model_value(model, key) do
    model
    |> effective_model_id()
    |> then(&get_in(@bundled_model_metadata, [&1, key]))
  end

  defp effective_model_id(%LLMDB.Model{provider_model_id: id}) when is_binary(id), do: id
  defp effective_model_id(%LLMDB.Model{id: id}), do: id
end
