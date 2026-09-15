defmodule ReqLLM.Providers.AmazonBedrock.PromptCache do
  @moduledoc """
  Prompt caching options shared by the Amazon Bedrock formatters.

  Resolves the `prompt_cache`, `prompt_cache_ttl` and `cache_messages` provider
  options, builds Converse `cachePoint` blocks and bridges the options to the
  keys consumed by `ReqLLM.Providers.Anthropic`.

  See https://docs.aws.amazon.com/bedrock/latest/userguide/prompt-caching.html
  """

  alias ReqLLM.Error.Invalid

  @ttls ["5m", "1h"]

  @type config :: %{
          enabled: boolean(),
          ttl: String.t() | nil,
          message_offset: integer() | nil
        }

  @doc """
  Resolve the prompt cache options into a config map.

  Top-level options win over `provider_options`, and the generic keys win over
  their `anthropic_*` aliases.
  """
  @spec resolve(keyword()) :: config()
  def resolve(opts) when is_list(opts) do
    opts = Keyword.merge(Keyword.get(opts, :provider_options, []), opts)

    %{
      enabled: option(opts, :prompt_cache, :anthropic_prompt_cache) == true,
      ttl: option(opts, :prompt_cache_ttl, :anthropic_prompt_cache_ttl),
      message_offset:
        opts |> option(:cache_messages, :anthropic_cache_messages) |> message_offset()
    }
  end

  defp option(opts, key, alias_key), do: Keyword.get(opts, key, Keyword.get(opts, alias_key))

  defp message_offset(true), do: -1
  defp message_offset(offset) when is_integer(offset), do: offset
  defp message_offset(_other), do: nil

  @doc "Build a Converse `cachePoint` block. `ttl` is omitted when nil."
  @spec checkpoint(String.t() | nil) :: map()
  def checkpoint(nil), do: %{"cachePoint" => %{"type" => "default"}}

  def checkpoint(ttl) when ttl in @ttls,
    do: %{"cachePoint" => %{"type" => "default", "ttl" => ttl}}

  def checkpoint(ttl),
    do:
      raise(Invalid.Parameter,
        parameter: "cache ttl must be \"5m\" or \"1h\", got: #{inspect(ttl)}"
      )

  @doc """
  Return the `cachePoint` block declared by the `cache_control` metadata of a
  `ContentPart` or a `Message`, or nil. Only the `ttl` is carried over.
  """
  @spec explicit_checkpoint(any()) :: map() | nil
  def explicit_checkpoint(%ReqLLM.Message.ContentPart{metadata: metadata}),
    do: metadata_checkpoint(metadata)

  def explicit_checkpoint(%ReqLLM.Message{metadata: metadata}),
    do: metadata_checkpoint(metadata)

  def explicit_checkpoint(_other), do: nil

  defp metadata_checkpoint(metadata) when is_map(metadata) do
    case metadata[:cache_control] || metadata["cache_control"] do
      %{} = cache_control -> checkpoint(cache_control[:ttl] || cache_control["ttl"])
      _ -> nil
    end
  end

  defp metadata_checkpoint(_metadata), do: nil

  @doc "True for a Converse `cachePoint` block."
  @spec checkpoint?(any()) :: boolean()
  def checkpoint?(%{"cachePoint" => _}), do: true
  def checkpoint?(_block), do: false

  @doc """
  Rewrite the generic options into the `anthropic_*` keys read by the
  Anthropic provider's prompt caching helper.
  """
  @spec to_anthropic_opts(keyword()) :: keyword()
  def to_anthropic_opts(opts) when is_list(opts) do
    %{enabled: enabled, ttl: ttl, message_offset: offset} = resolve(opts)

    opts
    |> Keyword.put(:anthropic_prompt_cache, enabled)
    |> put_or_delete(:anthropic_prompt_cache_ttl, ttl)
    |> put_or_delete(:anthropic_cache_messages, offset)
  end

  defp put_or_delete(opts, key, nil), do: Keyword.delete(opts, key)
  defp put_or_delete(opts, key, value), do: Keyword.put(opts, key, value)

  @doc """
  Place automatic checkpoints after the tools, the system prompt and the
  `cache_messages` position of an encoded Converse request, then check that no
  1h checkpoint follows a 5m one.
  """
  @spec apply_converse(map(), config(), String.t() | nil) :: map()
  def apply_converse(request, config, model_id) do
    request
    |> place_automatic(config, model_id)
    |> validate_ttl_order()
  end

  defp place_automatic(request, %{enabled: false}, _model_id), do: request

  defp place_automatic(request, config, model_id) do
    block = checkpoint(config.ttl)

    request
    |> cache_tools(block, model_id)
    |> cache_system(block)
    |> cache_message(block, config.message_offset)
  end

  defp cache_tools(%{"toolConfig" => %{"tools" => [_ | _] = tools}} = request, block, model_id) do
    if amazon_family?(model_id),
      do: request,
      else: put_in(request, ["toolConfig", "tools"], append_checkpoint(tools, block))
  end

  defp cache_tools(request, _block, _model_id), do: request

  defp cache_system(%{"system" => [_ | _] = system} = request, block),
    do: Map.put(request, "system", append_checkpoint(system, block))

  defp cache_system(request, _block), do: request

  defp cache_message(request, _block, nil), do: request

  defp cache_message(%{"messages" => messages} = request, block, offset) do
    messages =
      List.update_at(messages, offset, fn message ->
        Map.update!(message, "content", &append_checkpoint(&1, block))
      end)

    Map.put(request, "messages", messages)
  end

  defp append_checkpoint(blocks, block) do
    if checkpoint?(List.last(blocks)), do: blocks, else: blocks ++ [block]
  end

  defp validate_ttl_order(request) do
    blocks =
      (get_in(request, ["toolConfig", "tools"]) || []) ++
        (request["system"] || []) ++
        Enum.flat_map(request["messages"] || [], & &1["content"])

    ttls =
      Enum.flat_map(blocks, fn
        %{"cachePoint" => point} -> [Map.get(point, "ttl", "5m")]
        _block -> []
      end)

    if "1h" in Enum.drop_while(ttls, &(&1 == "1h")) do
      raise Invalid.Parameter,
        parameter: "cache checkpoints with a 1h ttl must come before those with a 5m ttl"
    end

    request
  end

  defp amazon_family?(model_id) when is_binary(model_id),
    do: Regex.match?(~r{(^|[./])amazon\.}, model_id)

  defp amazon_family?(_model_id), do: false
end
