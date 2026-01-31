# xAI (Grok)

Access Grok models with real-time web search and reasoning capabilities.

## Configuration

```bash
XAI_API_KEY=xai-...
```

## Attachments

xAI Chat Completions API only supports image attachments (JPEG, PNG, GIF, WebP).
For document support (PDFs, etc.), use Anthropic or Google providers.

## Provider Options

Passed via `:provider_options` keyword:

### `max_completion_tokens`
- **Type**: Integer
- **Purpose**: Preferred over `max_tokens` for Grok-4 models
- **Note**: ReqLLM auto-translates `max_tokens` for models requiring it
- **Example**: `provider_options: [max_completion_tokens: 2000]`

### `xai_tools`
- **Type**: List of maps
- **Purpose**: Enable agent tools such as web search
- **Supported tools**: `web_search`, `x_search`
- **Example**:
  ```elixir
  provider_options: [
    xai_tools: [
      %{type: "web_search"}
    ]
  ]
  ```
- **Web search options**:
  - `allowed_domains` - Allow list of domains
  - `excluded_domains` - Block list of domains
  - `enable_image_understanding` - Enable image understanding during search
- **Note**: `search_parameters` is deprecated and will be removed in a future release
- **Note**: `live_search` is no longer supported by xAI and will be filtered out

### `parallel_tool_calls`

- **Type**: Boolean
- **Default**: `true`
- **Purpose**: Allow parallel function calls
- **Example**: `provider_options: [parallel_tool_calls: true]`

### `stream_options`
- **Type**: Map
- **Purpose**: Configure streaming behavior
- **Example**: `provider_options: [stream_options: %{include_usage: true}]`

### `xai_structured_output_mode`
- **Type**: `:auto` | `:json_schema` | `:tool_strict`
- **Default**: `:auto`
- **Purpose**: Control structured output strategy
- **`:auto`**: Automatic selection based on model
- **`:json_schema`**: Native response_format (grok-2-1212+)
- **`:tool_strict`**: Strict tool calling fallback
- **Example**: `provider_options: [xai_structured_output_mode: :json_schema]`

### `response_format`
- **Type**: Map
- **Purpose**: Custom response format configuration
- **Example**:
  ```elixir
  provider_options: [
    response_format: %{
      type: "json_schema",
      json_schema: %{...}
    }
  ]
  ```

## Model-Specific Notes

### Grok-4 Models
- Do NOT support `stop`, `presence_penalty`, or `frequency_penalty`
- Use `max_completion_tokens` instead of `max_tokens`
- Support native structured outputs

### Grok-3-mini Models
- Support `reasoning_effort` parameter (`"low"`, `"medium"`, `"high"`)
- Efficient for cost-sensitive applications

### Grok-2 Models (1212+)
- Support native structured outputs
- Vision support (grok-2-vision-1212)

## Structured Output Schema Constraints

xAI's native structured outputs have limitations (auto-sanitized by ReqLLM):

**Not Supported:**
- `minLength`/`maxLength` for strings
- `minItems`/`maxItems`/`minContains`/`maxContains` for arrays
- `pattern` constraints
- `allOf` (must be flattened)

**Supported:**
- `anyOf`
- `additionalProperties: false` (enforced on root)

## Web Search Cost Tracking

Web search usage and costs are tracked in `response.usage`:

```elixir
{:ok, response} = ReqLLM.generate_text(
  "xai:grok-4-1-fast-reasoning",
  "What are the latest news about AI?",
  xai_tools: [%{type: "web_search"}]
)

# Access web search usage
response.usage.tool_usage.web_search
#=> %{count: 3, unit: "call"}

# Access cost breakdown
response.usage.cost
#=> %{tokens: 0.002, tools: 0.03, images: 0.0, total: 0.032}
```

xAI may report usage in different units (`"call"` or `"source"`) depending on the response format.

## Resources

- [xAI API Documentation](https://docs.x.ai/)
- [Grok Models](https://x.ai/grok)
