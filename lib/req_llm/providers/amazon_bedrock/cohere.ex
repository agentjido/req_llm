defmodule ReqLLM.Providers.AmazonBedrock.Cohere do
  @moduledoc """
  Cohere model family support for AWS Bedrock.

  Currently supports Cohere embedding models (cohere.embed-v4) on AWS Bedrock.

  ## Supported Models

  - `cohere.embed-v4:0` - Cohere Embed v4 with support for text and image embeddings

  ## Input Modes

  Cohere Embed v4 supports three input modes:

  1. **Text-only** - Pass strings directly via the `text` parameter
  2. **Image-only** - Pass base64-encoded images via `:images` provider option
  3. **Mixed (interleaved)** - Pass content parts via `:inputs` provider option

  """

  alias ReqLLM.Error

  @content_part_schema Zoi.object(%{
                         type: Zoi.enum(["text", "image_url"]),
                         text: Zoi.optional(Zoi.string()),
                         image_url: Zoi.optional(Zoi.string())
                       })

  @input_item_schema Zoi.object(%{
                       content: Zoi.array(@content_part_schema)
                     })

  @embedding_request_schema Zoi.object(%{
                              input_type:
                                Zoi.enum([
                                  "search_document",
                                  "search_query",
                                  "classification",
                                  "clustering"
                                ])
                                |> Zoi.default("search_document"),
                              embedding_types:
                                Zoi.array(
                                  Zoi.enum(["float", "int8", "uint8", "binary", "ubinary"])
                                )
                                |> Zoi.default(["float"]),
                              texts: Zoi.optional(Zoi.array(Zoi.string())),
                              images: Zoi.optional(Zoi.array(Zoi.string())),
                              inputs: Zoi.optional(Zoi.array(@input_item_schema)),
                              output_dimension: Zoi.optional(Zoi.enum([256, 512, 1024, 1536])),
                              max_tokens:
                                Zoi.number() |> Zoi.min(1) |> Zoi.max(128_000) |> Zoi.optional(),
                              truncate: Zoi.optional(Zoi.enum(["NONE", "LEFT", "RIGHT"]))
                            })

  @embedding_response_schema Zoi.object(%{
                               embeddings:
                                 Zoi.any(metadata: [description: "Embeddings in various formats"]),
                               texts: Zoi.optional(Zoi.array(Zoi.string())),
                               response_type: Zoi.optional(Zoi.string())
                             })

  def embedding_request_schema, do: @embedding_request_schema
  def embedding_response_schema, do: @embedding_response_schema

  @doc """
  Formats text, images, or mixed content into Cohere embedding request format for Bedrock.
  """
  def format_embedding_request(_model_id, text, opts) do
    provider_opts = opts[:provider_options] || []

    request_data = %{
      input_type: provider_opts[:input_type] || "search_document",
      embedding_types: provider_opts[:embedding_types] || ["float"]
    }

    request_data =
      request_data
      |> add_input_content(text, provider_opts)
      |> maybe_put(:output_dimension, opts[:dimensions] || provider_opts[:dimensions])
      |> maybe_put(:truncate, provider_opts[:truncate])
      |> maybe_put(:max_tokens, provider_opts[:max_tokens])

    case Zoi.parse(@embedding_request_schema, request_data) do
      {:ok, validated} ->
        {:ok, to_json_keys(validated)}

      {:error, errors} ->
        {:error,
         Error.Validation.Error.exception(
           tag: :invalid_embedding_request,
           reason: format_zoi_errors(errors),
           context: [request: request_data]
         )}
    end
  end

  defp add_input_content(request, text, provider_opts) do
    cond do
      provider_opts[:inputs] != nil ->
        Map.put(request, :inputs, format_inputs(provider_opts[:inputs]))

      provider_opts[:images] != nil ->
        Map.put(request, :images, provider_opts[:images])

      is_list(text) and not Enum.empty?(text) ->
        Map.put(request, :texts, text)

      is_binary(text) and text != "" ->
        Map.put(request, :texts, [text])

      true ->
        request
    end
  end

  defp format_inputs(inputs) when is_list(inputs) do
    Enum.map(inputs, fn
      %{content: content} when is_list(content) ->
        %{content: Enum.map(content, &format_content_part/1)}

      input ->
        input
    end)
  end

  defp format_content_part(%{type: type, text: text}) when type in ["text", :text] do
    %{type: "text", text: text}
  end

  defp format_content_part(%{type: type, image_url: url})
       when type in ["image_url", :image_url] do
    %{type: "image_url", image_url: url}
  end

  defp format_content_part(part), do: part

  @doc """
  Parses Cohere embedding response into OpenAI-compatible format.
  """
  def parse_embedding_response(response) when is_map(response) do
    case Zoi.parse(@embedding_response_schema, atomize_keys(response)) do
      {:ok, validated} ->
        extract_embeddings(validated)

      {:error, errors} ->
        {:error,
         Error.API.Response.exception(
           reason: "Invalid Cohere embedding response: #{format_zoi_errors(errors)}",
           response_body: response
         )}
    end
  end

  def parse_embedding_response(response) do
    {:error,
     Error.API.Response.exception(
       reason: "Expected map response from Cohere embedding API",
       response_body: response
     )}
  end

  defp extract_embeddings(%{embeddings: %{float: embeddings}}) when is_list(embeddings) do
    data = build_embedding_data(embeddings)
    {:ok, %{"data" => data}}
  end

  defp extract_embeddings(%{embeddings: embeddings}) when is_list(embeddings) do
    data = build_embedding_data(embeddings)
    {:ok, %{"data" => data}}
  end

  defp extract_embeddings(%{embeddings: embeddings}) when is_map(embeddings) do
    float_embeddings = Map.get(embeddings, :float) || Map.get(embeddings, "float")

    if is_list(float_embeddings) do
      data = build_embedding_data(float_embeddings)
      {:ok, %{"data" => data}}
    else
      {:error,
       Error.API.Response.exception(
         reason: "No float embeddings found in response",
         response_body: embeddings
       )}
    end
  end

  defp extract_embeddings(response) do
    {:error,
     Error.API.Response.exception(
       reason: "Unexpected embedding response structure",
       response_body: response
     )}
  end

  defp build_embedding_data(embeddings) do
    embeddings
    |> Enum.with_index()
    |> Enum.map(fn {embedding, idx} ->
      %{"index" => idx, "embedding" => embedding}
    end)
  end

  defp to_json_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), to_json_keys(v)}
      {k, v} -> {k, to_json_keys(v)}
    end)
  end

  defp to_json_keys(list) when is_list(list), do: Enum.map(list, &to_json_keys/1)
  defp to_json_keys(value), do: value

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {safe_to_existing_atom(k), atomize_keys(v)}
      {k, v} -> {k, atomize_keys(v)}
    end)
  end

  defp atomize_keys(list) when is_list(list), do: Enum.map(list, &atomize_keys/1)
  defp atomize_keys(value), do: value

  defp safe_to_existing_atom(string) do
    String.to_existing_atom(string)
  rescue
    ArgumentError -> string
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp format_zoi_errors(errors) do
    Enum.map_join(errors, ", ", fn %Zoi.Error{path: path, message: message} ->
      case path do
        [] -> message
        _ -> "#{Enum.map_join(path, ".", &to_string/1)}: #{message}"
      end
    end)
  end
end
