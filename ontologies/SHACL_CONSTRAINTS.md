# SHACL Constraints Documentation (Q Phase)

## Overview

This document describes the semantic validation constraints defined in `reqllm.shapes.ttl` for the req_llm ontology. These constraints enforce invariants that ensure data integrity and compliance with the domain model.

## Constraint Categories

### 1. Message Constraints (`req:MessageShape`)

**Required Properties:**
- `req:role` - Exactly 1, must be one of: `system`, `user`, `assistant`, `tool`
- `req:hasPart` - At least 1 content part

**Optional Properties:**
- `req:position` - Non-negative integer (0-based index in Context)

**Rationale**: Every message must have a role to identify the speaker and at least one content element to convey information.

**Example Valid Message:**
```json
{
  "@type": "Message",
  "role": "user",
  "hasPart": [
    {"@type": "TextPart", "text": "Hello!"}
  ]
}
```

**Example Invalid Message:**
```json
{
  "@type": "Message",
  "role": "user",
  "hasPart": []  // ❌ No parts
}
```

---

### 2. ContentPart Constraints (By Subtype)

#### 2.1 TextPart (`req:TextPartShape`)

**Required Properties:**
- `req:text` - Non-empty string

**Example:**
```json
{"@type": "TextPart", "text": "Hello, world!"}
```

#### 2.2 ImageURLPart (`req:ImageURLPartShape`)

**Required Properties:**
- `req:url` - Valid IRI/URL

**Example:**
```json
{"@type": "ImageURLPart", "url": "https://example.com/image.png"}
```

#### 2.3 ImagePart (`req:ImagePartShape`)

**Required Properties:**
- `req:mediaType` - String starting with `image/`
- `req:payload` - Base64 binary data

**Example:**
```json
{
  "@type": "ImagePart",
  "mediaType": "image/png",
  "payload": "iVBORw0KGgoAAAANSUhEUg..."
}
```

#### 2.4 FilePart (`req:FilePartShape`)

**Required Properties:**
- `req:mediaType` - String (MIME type)
- `req:payload` - Binary data

**Example:**
```json
{
  "@type": "FilePart",
  "mediaType": "application/pdf",
  "payload": "JVBERi0xLjQKJeLjz9..."
}
```

#### 2.5 ThinkingPart (`req:ThinkingPartShape`)

**Required Properties:**
- `req:thinkingText` - String (reasoning/chain-of-thought)

**Example:**
```json
{
  "@type": "ThinkingPart",
  "thinkingText": "Let me analyze this step by step..."
}
```

#### 2.6 ToolCallPart (`req:ToolCallPartShape`)

**Required Properties:**
- `req:toolName` - Non-empty string
- `req:argumentsJson` - JSON string

**Example:**
```json
{
  "@type": "ToolCallPart",
  "toolName": "get_weather",
  "argumentsJson": "{\"location\": \"San Francisco\"}"
}
```

#### 2.7 ToolResultPart (`req:ToolResultPartShape`)

**Required Properties:**
- `req:toolCallId` - String (links back to ToolCallPart)
- `req:resultJson` - JSON string

**Example:**
```json
{
  "@type": "ToolResultPart",
  "toolCallId": "call_abc123",
  "resultJson": "{\"temperature\": 72, \"conditions\": \"sunny\"}"
}
```

---

### 3. Response Constraints (`req:ResponseShape`)

**Required Properties:**
- `req:hasContext` - Exactly 1 Context
- `req:hasMessageOut` - Exactly 1 Message (assistant's response)
- `req:finishReason` - One of: `Stop`, `Length`, `ToolCalls`, `ContentFilter`, `Error`

**Optional Properties:**
- `req:id` - String
- `req:hasUsage` - At most 1 Usage instance

**Rationale**: Response represents a complete interaction result and must have context, output message, and termination reason.

**Example:**
```json
{
  "@type": "Response",
  "id": "resp_123",
  "hasContext": {...},
  "hasMessageOut": {...},
  "finishReason": "stop",
  "hasUsage": {...}
}
```

---

### 4. StreamResponse Constraints (`req:StreamResponseShape`)

**Required Properties:**
- `req:hasContext` - Exactly 1 Context
- `req:streamChunk` - At least 1 StreamChunk

**Rationale**: StreamResponse handles incremental results and must have context and chunk stream.

**Example:**
```json
{
  "@type": "StreamResponse",
  "hasContext": {...},
  "streamChunk": [
    {"@type": "StreamChunk", "chunkType": "content", "chunkText": "Hello"},
    {"@type": "StreamChunk", "chunkType": "content", "chunkText": " world"}
  ]
}
```

---

### 5. Context Constraints (`req:ContextShape`)

**Required Properties:**
- `req:hasMessage` - At least 1 Message

**Optional Properties:**
- `req:externalId` - String (session/conversation ID)

**Rationale**: Context represents conversation history and must contain at least one message.

**Example:**
```json
{
  "@type": "Context",
  "externalId": "session_456",
  "hasMessage": [
    {"@type": "Message", "role": "user", "hasPart": [...]},
    {"@type": "Message", "role": "assistant", "hasPart": [...]}
  ]
}
```

---

### 6. Usage Constraints (`req:UsageShape`)

**Token Fields** (non-negative integers):
- `req:inputTokens` - ≥ 0
- `req:outputTokens` - ≥ 0
- `req:reasoningTokens` - ≥ 0 (optional)
- `req:totalTokens` - ≥ 0 (optional)

**Cost Fields** (non-negative decimals):
- `req:inputCost` - ≥ 0.0
- `req:outputCost` - ≥ 0.0
- `req:totalCost` - ≥ 0.0

**Rationale**: Usage metrics must be non-negative for billing and monitoring.

**Example:**
```json
{
  "@type": "Usage",
  "inputTokens": 100,
  "outputTokens": 50,
  "totalTokens": 150,
  "inputCost": 0.001,
  "outputCost": 0.002,
  "totalCost": 0.003
}
```

---

### 7. StreamChunk Constraints (`req:StreamChunkShape`)

**Required Properties:**
- `req:chunkType` - One of: `content`, `thinking`, `tool_call`, `meta`

**Optional Properties:**
- `req:chunkText` - String
- `req:chunkMeta` - String (provider metadata)

**Rationale**: Streaming chunks must declare their type for proper handling.

**Example:**
```json
{
  "@type": "StreamChunk",
  "chunkType": "content",
  "chunkText": "Hello"
}
```

---

### 8. Tool Constraints (`req:ToolShape`)

**Required Properties:**
- `req:name` - Non-empty string
- `req:description` - String

**Optional Properties:**
- `req:parameterSchema` - String (JSON schema)

**Rationale**: Tools must have unique identifiers and descriptions for discoverability.

**Example:**
```json
{
  "@type": "Tool",
  "name": "get_weather",
  "description": "Get current weather for a location",
  "parameterSchema": "{\"type\": \"object\", \"properties\": {...}}"
}
```

---

### 9. Model Constraints (`req:ModelShape`)

**Required Properties:**
- `req:provider` - Provider instance
- `req:modelName` - String

**Optional Properties:**
- `req:temperature` - Decimal between 0.0 and 2.0
- `req:maxTokens` - Positive integer ≥ 1

**Rationale**: Model configuration must specify provider and model name.

**Example:**
```json
{
  "@type": "Model",
  "provider": {"@type": "Provider"},
  "modelName": "gpt-4",
  "temperature": 0.7,
  "maxTokens": 4096
}
```

---

## Validation Methods

### 1. Runtime Validation (Elixir)

Use `ReqLLM.Ontology.Validator` for runtime checks:

```elixir
alias ReqLLM.Ontology.Validator

response = %{
  id: "resp_123",
  finish_reason: :stop,
  context: %{messages: [...]},
  message: %{role: :assistant, parts: [...]},
  usage: %{input_tokens: 10, output_tokens: 5}
}

case Validator.validate_response(response) do
  :ok ->
    IO.puts("✅ Valid response")
  {:error, errors} ->
    IO.puts("❌ Validation failed:")
    Enum.each(errors, &IO.puts("  - #{&1}"))
end
```

### 2. SHACL Validation (Apache Jena)

For full W3C SHACL compliance, use Apache Jena:

```bash
# Validate RDF data against SHACL shapes
bash script/validate_shacl.sh \
  ontologies/reqllm.shapes.ttl \
  ontologies/reqllm.sigma_observed.ttl
```

### 3. CI Integration

SHACL validation runs automatically in CI on every push:

```yaml
- name: Run SHACL validation tests
  run: mix test test/ontology_validation_test.exs

- name: Validate SHACL constraints (Apache Jena)
  run: bash script/validate_shacl.sh
```

---

## Common Validation Errors

### Error: "Message must have at least one content part"

**Cause**: Message has empty `parts` array

**Fix**: Add at least one content part
```elixir
# ❌ Invalid
%{role: :user, parts: []}

# ✅ Valid
%{role: :user, parts: [%{type: :text, text: "Hello"}]}
```

### Error: "Response finishReason must be one of: stop, length, tool_calls, content_filter, error"

**Cause**: Invalid finish reason

**Fix**: Use valid enumeration value
```elixir
# ❌ Invalid
%{finish_reason: :unknown}

# ✅ Valid
%{finish_reason: :stop}
```

### Error: "Usage inputTokens must be a non-negative integer"

**Cause**: Negative or non-integer token count

**Fix**: Ensure token counts are non-negative integers
```elixir
# ❌ Invalid
%{input_tokens: -5}
%{input_tokens: 10.5}

# ✅ Valid
%{input_tokens: 10}
```

---

## Testing

Run validation tests:

```bash
# All validation tests
mix test test/ontology_validation_test.exs

# Specific test
mix test test/ontology_validation_test.exs:42
```

Test coverage:
- ✅ 34 validation tests
- ✅ All ContentPart variants
- ✅ Message, Context, Response validation
- ✅ Usage metrics validation
- ✅ Round-trip validation with Emitter

---

## References

- **SHACL Spec**: https://www.w3.org/TR/shacl/
- **Apache Jena SHACL**: https://jena.apache.org/documentation/shacl/
- **Shapes File**: `ontologies/reqllm.shapes.ttl`
- **Validator Module**: `lib/req_llm/ontology/validator.ex`
- **Tests**: `test/ontology_validation_test.exs`

---

**Status**: ✅ **Q Phase Complete**

**Date**: 2025-11-10

**Next Phase**: KNHK (Knowledge Hooks) → gitvan (Versioning)
