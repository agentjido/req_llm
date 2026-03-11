defmodule UsageCostSearchImage do
  @moduledoc """
  Smoke test for usage metadata covering search tool costs and image generation costs.

  Usage:

      mix run lib/examples/scripts/usage_cost_search_image.exs [options]

  Options:

    * `--search-models` - Comma-separated model specs for search-enabled text requests
    * `--image-models` - Comma-separated model specs for image generation requests
    * `--search-prompt` - Prompt to use for search requests
    * `--image-prompt` - Prompt to use for image generation
    * `--system-prompt` - System prompt for search requests
    * `--max-tokens` - Maximum tokens to generate for search requests
    * `--temperature` - Sampling temperature for search requests
    * `--image-size` - Image size (e.g. 1024x1024)
    * `--image-aspect-ratio` - Image aspect ratio (e.g. 1:1 or 16:9)
    * `--image-output-format` - Image output format (png, jpeg, webp)
    * `--image-response-format` - Image response format (binary or url)
    * `--xai-web-search` - Enable xAI web search tool (true or false)
    * `--xai-web-search-allowed-domains` - Comma-separated allowed domains
    * `--xai-web-search-excluded-domains` - Comma-separated excluded domains
    * `--xai-web-search-image-understanding` - Enable xAI image understanding in search (true or false)
    * `--openai-web-search` - Enable OpenAI web search tool (true or false)
    * `--anthropic-search-max-uses` - Anthropic web search max uses
    * `--google-grounding` - Enable Google grounding (true or false)
    * `--log-level` - Log level (debug, info, warning, error)

  Examples:

      mix run lib/examples/scripts/usage_cost_search_image.exs

      mix run lib/examples/scripts/usage_cost_search_image.exs \\
        --search-models "xai:grok-4-1-fast-reasoning,google:gemini-3-flash-preview,openai:gpt-5-mini,anthropic:claude-sonnet-4-5" \\
        --image-models "google:gemini-2.5-flash-image,openai:gpt-image-1.5"
  """

  alias ReqLLM.Scripts.Helpers

  @script_name "usage_cost_search_image.exs"

  @schema [
    search_models: [
      type: :string,
      doc: "Comma-separated model specs for search-enabled requests"
    ],
    image_models: [
      type: :string,
      doc: "Comma-separated model specs for image generation"
    ],
    search_prompt: [
      type: :string,
      default:
        "Use web search to find two recent AI model announcements and summarize them in two sentences with sources.",
      doc: "Prompt to use for search requests"
    ],
    image_prompt: [
      type: :string,
      default: "Generate a single image of a small banana rocket on a clean white background.",
      doc: "Prompt to use for image generation"
    ],
    system_prompt: [
      type: :string,
      doc: "System prompt for search requests"
    ],
    max_tokens: [
      type: :integer,
      doc: "Maximum tokens to generate for search requests"
    ],
    temperature: [
      type: :float,
      doc: "Sampling temperature for search requests"
    ],
    image_size: [
      type: :string,
      doc: "Image size (e.g. 1024x1024)"
    ],
    image_aspect_ratio: [
      type: :string,
      doc: "Image aspect ratio (e.g. 1:1 or 16:9)"
    ],
    image_output_format: [
      type: :string,
      doc: "Image output format (png, jpeg, webp)"
    ],
    image_response_format: [
      type: :string,
      doc: "Image response format (binary or url)"
    ],
    xai_web_search: [
      type: :boolean,
      default: true,
      doc: "Enable xAI web search tool"
    ],
    xai_web_search_allowed_domains: [
      type: :string,
      doc: "Comma-separated allowed domains"
    ],
    xai_web_search_excluded_domains: [
      type: :string,
      doc: "Comma-separated excluded domains"
    ],
    xai_web_search_image_understanding: [
      type: :boolean,
      doc: "Enable xAI image understanding in search"
    ],
    openai_web_search: [
      type: :boolean,
      default: true,
      doc: "Enable OpenAI web search tool"
    ],
    anthropic_search_max_uses: [
      type: :integer,
      default: 3,
      doc: "Anthropic web search max uses"
    ],
    google_grounding: [
      type: :boolean,
      default: true,
      doc: "Enable Google grounding"
    ],
    log_level: [
      type: :string,
      default: "warning",
      doc: "Log level: debug, info, warning, error"
    ]
  ]

  def run(argv) do
    Helpers.ensure_app!()
    opts = Helpers.parse_args(argv, @schema, @script_name)

    Logger.configure(level: Helpers.log_level(opts[:log_level]))

    search_models = parse_models(opts[:search_models], default_search_models())
    image_models = parse_models(opts[:image_models], default_image_models())

    Helpers.banner!(@script_name, "Usage cost smoke test for search and image generation",
      search_models: search_models,
      image_models: image_models,
      search_prompt: opts[:search_prompt],
      image_prompt: opts[:image_prompt],
      system_prompt: opts[:system_prompt],
      max_tokens: opts[:max_tokens],
      temperature: opts[:temperature],
      image_size: opts[:image_size],
      image_aspect_ratio: opts[:image_aspect_ratio],
      image_output_format: opts[:image_output_format],
      image_response_format: opts[:image_response_format],
      xai_web_search: opts[:xai_web_search],
      xai_web_search_allowed_domains: opts[:xai_web_search_allowed_domains],
      xai_web_search_excluded_domains: opts[:xai_web_search_excluded_domains],
      xai_web_search_image_understanding: opts[:xai_web_search_image_understanding],
      openai_web_search: opts[:openai_web_search],
      anthropic_search_max_uses: opts[:anthropic_search_max_uses],
      google_grounding: opts[:google_grounding]
    )

    Enum.each(image_models, fn model_spec ->
      run_image(model_spec, opts)
    end)

    Enum.each(search_models, fn model_spec ->
      run_search(model_spec, opts)
    end)
  rescue
    error -> Helpers.handle_error!(error, @script_name, [])
  end

  defp default_image_models do
    ["google:gemini-2.5-flash-image", "openai:gpt-image-1.5"]
  end

  defp default_search_models do
    [
      "xai:grok-4-1-fast-reasoning",
      "google:gemini-3-flash-preview",
      "openai:gpt-5-mini",
      "anthropic:claude-sonnet-4-5"
    ]
  end

  defp parse_models(nil, defaults), do: defaults

  defp parse_models(models, defaults) when is_binary(models) do
    parsed =
      models
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if parsed == [], do: defaults, else: parsed
  end

  defp run_image(model_spec, opts) do
    prompt = opts[:image_prompt]

    generation_opts =
      []
      |> Helpers.maybe_put(:size, opts[:image_size])
      |> Helpers.maybe_put(:aspect_ratio, opts[:image_aspect_ratio])
      |> Helpers.maybe_put(:output_format, parse_image_output_format(opts[:image_output_format]))
      |> Helpers.maybe_put(
        :response_format,
        parse_image_response_format(opts[:image_response_format])
      )

    {result, duration_ms} =
      Helpers.time(fn -> ReqLLM.generate_image(model_spec, prompt, generation_opts) end)

    render_result(:image, model_spec, result, duration_ms)
  end

  defp run_search(model_spec, opts) do
    context = Helpers.context(opts[:search_prompt], system: opts[:system_prompt])

    base_opts =
      []
      |> Helpers.maybe_put(:max_tokens, opts[:max_tokens])
      |> Helpers.maybe_put(:temperature, opts[:temperature])

    {provider_opts, extra_opts, notice} = search_provider_options(model_spec, opts)

    if notice do
      IO.puts("\nNOTICE | #{model_spec}")
      IO.puts(notice)
    end

    generation_opts = merge_generation_opts(base_opts, provider_opts, extra_opts)

    {result, duration_ms} =
      Helpers.time(fn -> ReqLLM.generate_text(model_spec, context, generation_opts) end)

    render_result(:search, model_spec, result, duration_ms)
  end

  defp search_provider_options(model_spec, opts) do
    case provider_from_spec(model_spec) do
      :xai ->
        tools = build_xai_web_search_tools(opts)

        if tools == [] do
          {[], [], "xAI web search disabled; running without search configuration."}
        else
          {[], [xai_tools: tools], nil}
        end

      :google ->
        if opts[:google_grounding] do
          {[google_grounding: %{enable: true}], [], nil}
        else
          {[], [], "Google grounding disabled; running without search configuration."}
        end

      :anthropic ->
        {[web_search: %{max_uses: opts[:anthropic_search_max_uses]}], [], nil}

      :openai ->
        case ReqLLM.model(model_spec) do
          {:ok, model} ->
            protocol = get_in(model, [Access.key(:extra, %{}), :wire, :protocol])

            if protocol == "openai_responses" do
              tools = build_openai_web_search_tools(opts)

              if tools == [] do
                {[], [], "OpenAI web search disabled; running without search configuration."}
              else
                {[], [tools: tools], nil}
              end
            else
              {[], [],
               "OpenAI web search requires Responses API models; running without search configuration."}
            end

          _ ->
            {[], [], "OpenAI model metadata unavailable; running without search configuration."}
        end

      _ ->
        {[], [], "No search configuration available for this provider."}
    end
  end

  defp build_xai_web_search_tools(opts) do
    if opts[:xai_web_search] == false do
      []
    else
      tool =
        %{type: "web_search"}
        |> maybe_put_map(:allowed_domains, parse_csv_list(opts[:xai_web_search_allowed_domains]))
        |> maybe_put_map(
          :excluded_domains,
          parse_csv_list(opts[:xai_web_search_excluded_domains])
        )
        |> maybe_put_map(:enable_image_understanding, opts[:xai_web_search_image_understanding])

      [tool]
    end
  end

  defp build_openai_web_search_tools(opts) do
    if opts[:openai_web_search] == false do
      []
    else
      [%{"type" => "web_search"}]
    end
  end

  defp merge_generation_opts(opts, provider_opts, extra_opts) do
    opts
    |> merge_provider_options(provider_opts)
    |> Keyword.merge(extra_opts, fn
      :tools, left, right when is_list(left) and is_list(right) -> left ++ right
      _key, _left, right -> right
    end)
  end

  defp parse_csv_list(nil), do: nil

  defp parse_csv_list(values) when is_binary(values) do
    values
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> nil
      list -> list
    end
  end

  defp parse_csv_list(other), do: other

  defp provider_from_spec(model_spec) when is_binary(model_spec) do
    case String.split(model_spec, ":", parts: 2) do
      ["xai", _] -> :xai
      ["google", _] -> :google
      ["anthropic", _] -> :anthropic
      ["openai", _] -> :openai
      _ -> nil
    end
  end

  defp provider_from_spec(_), do: nil

  defp merge_provider_options(opts, provider_opts) do
    if provider_opts == [] do
      opts
    else
      Keyword.update(opts, :provider_options, provider_opts, fn existing ->
        Keyword.merge(existing, provider_opts)
      end)
    end
  end

  defp render_result(kind, model_spec, {:ok, response}, duration_ms) do
    label = if kind == :image, do: "IMAGE", else: "SEARCH"

    IO.puts("\n#{label} | #{model_spec}")
    IO.puts("status: ok")
    IO.puts("duration_ms: #{duration_ms}")

    case kind do
      :image -> print_image_summary(response)
      :search -> print_search_summary(response)
    end

    print_usage_details(ReqLLM.Response.usage(response), kind)
  end

  defp render_result(_kind, model_spec, {:error, error}, _duration_ms) do
    IO.puts("\nERROR | #{model_spec}")
    IO.puts("error: #{format_error(error)}")
  end

  defp print_image_summary(response) do
    images = ReqLLM.Response.images(response)
    IO.puts("images: #{length(images)}")

    case images do
      [%{type: :image, data: data, media_type: media_type} | _] ->
        IO.puts("first_image: #{media_type}, bytes=#{byte_size(data)}")

      [%{type: :image_url, url: url} | _] ->
        IO.puts("first_image_url: #{url}")

      _ ->
        IO.puts("first_image: none")
    end
  end

  defp print_search_summary(response) do
    text = ReqLLM.Response.text(response)

    case text do
      nil -> IO.puts("text: none")
      "" -> IO.puts("text: empty")
      _ -> IO.puts("text: #{preview(text, 240)}")
    end
  end

  defp print_usage_details(nil, kind) do
    IO.puts("usage: missing")

    case kind do
      :image -> IO.puts("expected: image_usage, cost fields")
      :search -> IO.puts("expected: tool_usage.web_search, cost fields")
    end
  end

  defp print_usage_details(usage, kind) when is_map(usage) do
    print_token_usage(usage)
    print_cost_usage(usage)

    case kind do
      :image -> print_image_usage(usage)
      :search -> print_search_usage(usage)
    end
  end

  defp print_token_usage(usage) do
    input = usage_value(usage, :input_tokens) || 0
    output = usage_value(usage, :output_tokens) || 0
    total = usage_value(usage, :total_tokens) || input + output
    reasoning = usage_value(usage, :reasoning_tokens) || 0

    IO.puts("tokens: input=#{input} output=#{output} total=#{total}")

    if reasoning > 0 do
      IO.puts("reasoning_tokens: #{reasoning}")
    end
  end

  defp print_cost_usage(usage) do
    missing = missing_cost_fields(usage)

    if missing == [] do
      input_cost = usage_value(usage, :input_cost)
      output_cost = usage_value(usage, :output_cost)
      total_cost = usage_value(usage, :total_cost)

      IO.puts(
        "cost: input=#{format_decimal(input_cost)} output=#{format_decimal(output_cost)} total=#{format_decimal(total_cost)}"
      )
    else
      IO.puts("cost: missing fields #{Enum.join(missing, ", ")}")
    end

    cost = usage_value(usage, :cost)

    if is_map(cost) do
      tokens = usage_value(cost, :tokens)
      tools = usage_value(cost, :tools)
      images = usage_value(cost, :images)
      total = usage_value(cost, :total)

      IO.puts(
        "cost_breakdown: tokens=#{format_decimal(tokens)} tools=#{format_decimal(tools)} images=#{format_decimal(images)} total=#{format_decimal(total)}"
      )
    else
      IO.puts("cost_breakdown: missing")
    end
  end

  defp print_search_usage(usage) do
    tool_usage = usage_value(usage, :tool_usage) || %{}
    web_search = usage_value(tool_usage, :web_search) || %{}
    count = usage_value(web_search, :count) || 0
    unit = usage_value(web_search, :unit)

    if count > 0 do
      IO.puts("web_search: count=#{count} unit=#{format_unit(unit)}")
    else
      IO.puts("web_search: missing")
    end
  end

  defp print_image_usage(usage) do
    image_usage = usage_value(usage, :image_usage) || %{}
    generated = usage_value(image_usage, :generated) || %{}
    count = usage_value(generated, :count) || 0
    size_class = usage_value(generated, :size_class)

    if count > 0 do
      line =
        if size_class do
          "image_usage: generated=#{count} size_class=#{size_class}"
        else
          "image_usage: generated=#{count}"
        end

      IO.puts(line)
    else
      IO.puts("image_usage: missing")
    end
  end

  defp usage_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp usage_value(_, _), do: nil

  defp missing_cost_fields(usage) do
    [:input_cost, :output_cost, :total_cost]
    |> Enum.reject(fn key -> usage_value(usage, key) != nil end)
    |> Enum.map(&Atom.to_string/1)
  end

  defp format_decimal(nil), do: "n/a"
  defp format_decimal(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 6)
  defp format_decimal(value), do: to_string(value)

  defp format_unit(nil), do: "n/a"
  defp format_unit(value) when is_atom(value), do: Atom.to_string(value)
  defp format_unit(value), do: to_string(value)

  defp preview(text, max_len) do
    if String.length(text) > max_len do
      String.slice(text, 0, max_len) <> "..."
    else
      text
    end
  end

  defp parse_image_output_format(nil), do: nil

  defp parse_image_output_format(format) when is_binary(format) do
    case String.downcase(format) do
      "png" -> :png
      "jpeg" -> :jpeg
      "jpg" -> :jpeg
      "webp" -> :webp
      other -> String.to_atom(other)
    end
  end

  defp parse_image_output_format(other), do: other

  defp parse_image_response_format(nil), do: nil

  defp parse_image_response_format(format) when is_binary(format) do
    case String.downcase(format) do
      "binary" -> :binary
      "url" -> :url
      other -> String.to_atom(other)
    end
  end

  defp parse_image_response_format(other), do: other

  defp maybe_put_map(map, _key, nil), do: map
  defp maybe_put_map(map, key, value), do: Map.put(map, key, value)

  defp format_error(%{__struct__: _} = error), do: Exception.message(error)
  defp format_error(other), do: inspect(other)
end

UsageCostSearchImage.run(System.argv())
