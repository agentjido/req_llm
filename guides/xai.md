# xAI (Grok)

Access Grok models with real-time web search and reasoning capabilities.

## Configuration

```bash
XAI_API_KEY=xai-...
```

## Provider Options

Passed via `:provider_options` keyword:

### `max_completion_tokens`
- **Type**: Integer
- **Purpose**: Preferred over `max_tokens` for Grok-4 models
- **Note**: ReqLLM auto-translates `max_tokens` for models requiring it
- **Example**: `provider_options: [max_completion_tokens: 2000]`

### `search_parameters`
- **Type**: Map
- **Purpose**: Enable Live Search with real-time web access
- **Keys**:
  - `mode`: `"auto"` (default), `"always"`, or `"never"`
  - `max_sources`: Maximum sources to cite (integer)
  - `date_range`: `"recent"`, `"week"`, `"month"`, `"year"`
  - `citations`: Include citations (boolean)
- **Example**:
  ```elixir
  provider_options: [
    search_parameters: %{
      mode: "auto",
      max_sources: 5,
      date_range: "recent",
      citations: true
    }
  ]
  ```
- **Note**: Live Search incurs additional costs per source

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

## Resources

- [xAI API Documentation](https://docs.x.ai/)
- [Grok Models](https://x.ai/grok)
