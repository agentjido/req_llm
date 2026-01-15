defmodule ReqLLM.Providers.Venice do
  @moduledoc """
  Venice AI provider – OpenAI-compatible Chat Completions API with privacy-first inference.

  ## Implementation

  Uses built-in OpenAI-style encoding/decoding defaults with Venice-specific extensions.
  Venice is fully OpenAI-compatible with additional parameters via `venice_parameters`.

  ## Venice-Specific Extensions

  Beyond standard OpenAI parameters, Venice supports provider-specific options
  via the `venice_parameters` object in the request body:

  - `character_slug` - Use a specific AI character persona
  - `enable_web_search` - Enable real-time web search (off, on, auto)
  - `enable_web_scraping` - Scrape URLs in user messages
  - `enable_web_citations` - Include citations in web search results
  - `strip_thinking_response` - Strip `<think>` blocks from response
  - `disable_thinking` - Disable reasoning mode entirely
  - `include_venice_system_prompt` - Include Venice's default system prompts

  See `provider_schema/0` for the complete Venice-specific schema and
  `ReqLLM.Provider.Options` for inherited OpenAI parameters.

  ## Configuration

      # Add to .env file (automatically loaded)
      VENICE_API_KEY=your-api-key

  ## Examples

      # Basic usage
      ReqLLM.generate_text("venice:llama-3.3-70b", "Hello!")

      # With web search enabled
      ReqLLM.generate_text("venice:zai-org-glm-4.6", "What happened today?",
        provider_options: [enable_web_search: "on"]
      )

      # With a Venice character
      ReqLLM.generate_text("venice:venice-uncensored", "Tell me a story",
        provider_options: [character_slug: "my-character"]
      )
  """

  use ReqLLM.Provider,
    id: :venice,
    default_base_url: "https://api.venice.ai/api/v1",
    default_env_key: "VENICE_API_KEY"

  use ReqLLM.Provider.Defaults

  import ReqLLM.Provider.Utils, only: [maybe_put: 3]

  @provider_schema [
    character_slug: [
      type: :string,
      doc: "The character slug of a public Venice character."
    ],
    strip_thinking_response: [
      type: :boolean,
      doc: "Strip <think></think> blocks from the response.",
      default: false
    ],
    disable_thinking: [
      type: :boolean,
      doc: "Disable thinking and strip <think></think> blocks.",
      default: false
    ],
    enable_web_search: [
      type: {:in, ["off", "on", "auto"]},
      doc: "Enable web search for this request (off, on, auto).",
      default: "off"
    ],
    enable_web_scraping: [
      type: :boolean,
      doc: "Enable Venice web scraping of URLs in the latest user message.",
      default: false
    ],
    enable_web_citations: [
      type: :boolean,
      doc: "When web search is enabled, request that the LLM cite its sources.",
      default: false
    ],
    include_search_results_in_stream: [
      type: :boolean,
      doc: "Experimental: Include search results in the stream as the first chunk.",
      default: false
    ],
    return_search_results_as_documents: [
      type: :boolean,
      doc: "Surface search results in an OpenAI-compatible tool call."
    ],
    include_venice_system_prompt: [
      type: :boolean,
      doc: "Whether to include the Venice supplied system prompts.",
      default: true
    ]
  ]

  @venice_keys [
    :character_slug,
    :strip_thinking_response,
    :disable_thinking,
    :enable_web_search,
    :enable_web_scraping,
    :enable_web_citations,
    :include_search_results_in_stream,
    :return_search_results_as_documents,
    :include_venice_system_prompt
  ]

  @doc false
  def supported_provider_options do
    Keyword.keys(@provider_schema) ++ [:venice_parameters]
  end

  @impl ReqLLM.Provider
  def translate_options(_operation, _model, opts) do
    venice_opts = Keyword.take(opts, @venice_keys)
    remaining_opts = Keyword.drop(opts, @venice_keys)

    venice_params =
      venice_opts
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    opts_with_venice =
      if map_size(venice_params) > 0 do
        Keyword.put(remaining_opts, :venice_parameters, venice_params)
      else
        remaining_opts
      end

    {opts_with_venice, []}
  end

  @impl ReqLLM.Provider
  def encode_body(request) do
    request = ReqLLM.Provider.Defaults.default_encode_body(request)
    body = Jason.decode!(request.body)

    venice_params = request.options[:venice_parameters]

    enhanced_body =
      body
      |> maybe_put(:venice_parameters, encode_venice_parameters(venice_params))

    encoded_body = Jason.encode!(enhanced_body)
    Map.put(request, :body, encoded_body)
  end

  defp encode_venice_parameters(nil), do: nil
  defp encode_venice_parameters(params) when map_size(params) == 0, do: nil

  defp encode_venice_parameters(params) when is_map(params) do
    params
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
  end
end
