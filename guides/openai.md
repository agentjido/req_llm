# OpenAI

Access GPT models including standard chat models and reasoning models (o1, o3, GPT-5).

## Configuration

```bash
OPENAI_API_KEY=sk-...
```

## Dual API Architecture

OpenAI provider automatically routes between two APIs based on model metadata:

- **Chat Completions API**: Standard GPT models (gpt-4o, gpt-4-turbo, gpt-3.5-turbo)
- **Responses API**: Reasoning models (o1, o3, o4-mini, gpt-5) with extended thinking

## Provider Options

Passed via `:provider_options` keyword:

### `max_completion_tokens`
- **Type**: Integer
- **Purpose**: Required for reasoning models (o1, o3, gpt-5)
- **Note**: ReqLLM auto-translates `max_tokens` to `max_completion_tokens` for reasoning models
- **Example**: `provider_options: [max_completion_tokens: 4000]`

### `openai_structured_output_mode`
- **Type**: `:auto` | `:json_schema` | `:tool_strict`
- **Default**: `:auto`
- **Purpose**: Control structured output strategy
- **`:auto`**: Use json_schema when supported, else strict tools
- **`:json_schema`**: Force response_format with json_schema
- **`:tool_strict`**: Force strict: true on function tools
- **Example**: `provider_options: [openai_structured_output_mode: :json_schema]`

### `response_format`
- **Type**: Map
- **Purpose**: Custom response format configuration
- **Example**:
  ```elixir
  provider_options: [
    response_format: %{
      type: "json_schema",
      json_schema: %{
        name: "person",
        schema: %{type: "object", properties: %{name: %{type: "string"}}}
      }
    }
  ]
  ```

### `openai_parallel_tool_calls`
- **Type**: Boolean | nil
- **Default**: `nil`
- **Purpose**: Override parallel tool call behavior
- **Example**: `provider_options: [openai_parallel_tool_calls: false]`

### `reasoning_effort`
- **Type**: `:low` | `:medium` | `:high`
- **Purpose**: Control reasoning effort (Responses API only)
- **Example**: `reasoning_effort: :high`

### `seed`
- **Type**: Integer
- **Purpose**: Set seed for reproducible outputs
- **Example**: `provider_options: [seed: 42]`

### `logprobs`
- **Type**: Boolean
- **Purpose**: Request log probabilities
- **Example**: `provider_options: [logprobs: true, top_logprobs: 3]`

### `top_logprobs`
- **Type**: Integer (1-20)
- **Purpose**: Number of log probabilities to return
- **Requires**: `logprobs: true`
- **Example**: `provider_options: [logprobs: true, top_logprobs: 5]`

### `user`
- **Type**: String
- **Purpose**: Track usage by user identifier
- **Example**: `provider_options: [user: "user_123"]`

### Embedding Options

#### `dimensions`
- **Type**: Positive integer
- **Purpose**: Control embedding dimensions (model-specific ranges)
- **Example**: `provider_options: [dimensions: 512]`

#### `encoding_format`
- **Type**: `"float"` | `"base64"`
- **Purpose**: Format for embedding output
- **Example**: `provider_options: [encoding_format: "base64"]`

### Responses API Resume Flow

#### `previous_response_id`
- **Type**: String
- **Purpose**: Resume tool calling flow from previous response
- **Example**: `provider_options: [previous_response_id: "resp_abc123"]`

#### `tool_outputs`
- **Type**: List of `%{call_id, output}` maps
- **Purpose**: Provide tool execution results for resume flow
- **Example**: `provider_options: [tool_outputs: [%{call_id: "call_1", output: "result"}]]`

## Usage Metrics

OpenAI provides comprehensive usage data including:
- `reasoning_tokens` - For reasoning models (o1, o3, gpt-5)
- `cached_tokens` - Cached input tokens
- Standard input/output/total tokens and costs

## Resources

- [OpenAI API Documentation](https://platform.openai.com/docs/api-reference)
- [Model Overview](https://platform.openai.com/docs/models)
