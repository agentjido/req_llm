# Coverage Testing Guide

This guide covers testing and verification workflows for ReqLLM, focusing on live API coverage tests with fixture support for local testing without API calls.

## Overview

ReqLLM's testing system is built around two core principles:

1. **Provider coverage testing** - Tests verify that provider implementations work correctly across different features
2. **Fixture-based testing** - Tests can run against live APIs or cached fixtures for fast local development

## Testing Modes

### Fixture Mode (Default)

By default, tests use cached fixtures for fast, reliable testing:

```bash
mix test                    # Uses fixtures
mix test --only openai      # Test specific provider with fixtures
```

### Live Mode

Set `LIVE=true` to test against real APIs and capture new fixtures:

```bash
LIVE=true mix test                    # Run all tests live
LIVE=true mix test --only openai      # Test specific provider live
LIVE=true mix test --only coverage    # Run coverage tests live
```

**Live mode will:**
- Make real API calls to providers
- Capture responses as JSON fixtures
- Overwrite existing fixtures with new responses
- Require valid API keys for each provider

## Quality & CI

CI runs `mix quality` alias before tests. Locally:

```bash
mix quality    # or mix q - runs format, compile --warnings-as-errors, dialyzer, credo
```

## Test Organization

### Directory Structure

```
test/
├── coverage/                 # Provider capability coverage tests
│   ├── anthropic/
│   │   ├── core_test.exs            # Basic generation
│   │   ├── streaming_test.exs       # Streaming responses
│   │   └── tool_calling_test.exs    # Tool calling
│   └── openai/               # Similar structure for each provider
├── support/
│   ├── fixtures/             # Cached API responses
│   │   ├── anthropic/
│   │   └── openai/
│   ├── live_fixture.ex       # Test fixture system
│   └── provider_test/        # Shared test macros
├── req_llm/
└── req_llm_test.exs         # Core library tests
```

### Test Tags

Tests use ExUnit tags for organization:

```elixir
@moduletag :coverage       # Coverage test
@moduletag :openai         # Provider-specific
@moduletag :streaming      # Feature-specific
@moduletag :tools          # Capability-specific
```

Run specific test groups:
```bash
mix test --only coverage
mix test --only openai
mix test --only streaming
```

## Writing Capability Tests

### Using Provider Test Macros

ReqLLM uses shared test macros to eliminate duplication while maintaining clear per-provider organization:

```elixir
defmodule ReqLLM.Coverage.MyProvider.CoreTest do
  use ReqLLM.ProviderTest.Core,
    provider: :my_provider,
    model: "my_provider:my-model"

  # Provider-specific tests can be added here
end
```

Available macros:
- `ReqLLM.ProviderTest.Core` - Basic text generation
- `ReqLLM.ProviderTest.Streaming` - Streaming responses  
- `ReqLLM.ProviderTest.ToolCalling` - Tool/function calling

### Manual Testing with LiveFixture

For custom tests, use the LiveFixture API directly:

```elixir
defmodule ReqLLM.Coverage.MyProvider.CustomTest do
  use ExUnit.Case, async: false
  
  import ReqLLM.Test.LiveFixture
  
  @moduletag :coverage
  @moduletag :my_provider
  
  @model "my_provider:my-model"
  
  test "basic text generation", fixture: "basic_generation" do
    ctx = ReqLLM.Context.new([ReqLLM.Context.user("Hello!")])
    {:ok, resp} = ReqLLM.generate_text(@model, ctx, max_tokens: 50)
    
    text = ReqLLM.Response.text(resp)
    assert is_binary(text)
    assert text != ""
    assert resp.id != nil
  end
end
```

### Capability-Driven Tests

Verify capabilities match metadata before testing:

```elixir
test "temperature parameter works as advertised" do
  # Check if model advertises temperature support
  supports_temp = ReqLLM.Capability.supports?(@model, :temperature)
  
  if supports_temp do
    result = use_fixture(:my_provider, "temperature_test", fn ->
      ctx = ReqLLM.Context.new([ReqLLM.Context.user("Be creative")])
      ReqLLM.generate_text(@model, ctx, temperature: 1.0, max_tokens: 50)
    end)
    
    {:ok, resp} = result
    assert resp.id != nil
  else
    skip("Model does not advertise temperature support")
  end
end
```

### Testing Tool Calling

Comprehensive tool calling tests:

```elixir
describe "tool calling capabilities" do
  @weather_tool %{
    name: "get_weather",
    description: "Get weather for a location",
    parameter_schema: %{
      type: "object",
      properties: %{
        location: %{type: "string", description: "City name"}
      },
      required: ["location"]
    }
  }

  test "basic tool calling", fixture: "tool_calling_basic" do
    ctx = ReqLLM.Context.new([
      ReqLLM.Context.user("What's the weather in Paris?")
    ])
    
    {:ok, resp} = ReqLLM.generate_text(@model, ctx, 
      tools: [@weather_tool],
      max_tokens: 200
    )
    
    assert resp.id != nil
  end
  
  test "tool choice control" do
    if ReqLLM.Capability.supports?(@model, :tool_choice) do
      result = use_fixture(:my_provider, "tool_choice_specific", fn ->
        ctx = ReqLLM.Context.new([
          ReqLLM.Context.user("Tell me about weather")
        ])
        
        ReqLLM.generate_text(@model, ctx, 
          tools: [@weather_tool],
          tool_choice: %{type: "tool", name: "get_weather"}
        )
      end)
      
      {:ok, resp} = result
      assert resp.id != nil
    else
      skip("Model does not support tool choice control")
    end
  end

  test "tool result handling" do
    result = use_fixture(:my_provider, "tool_with_result", fn ->
      ctx = ReqLLM.Context.new([
        ReqLLM.Context.user("What's the weather like?"),
        ReqLLM.Context.assistant("", tool_calls: [
          %{id: "call_1", name: "get_weather", arguments: %{"location" => "Paris"}}
        ]),
        ReqLLM.Context.tool_result("call_1", %{"weather" => "sunny", "temp" => 22})
      ])
      
      ReqLLM.generate_text(@model, ctx, tools: [@weather_tool])
    end)
    
    {:ok, resp} = result
    assert resp.id != nil
  end
end
```

### Testing Streaming

Test streaming with proper chunk handling:

```elixir
test "streaming text generation", fixture: "streaming_test" do
  if ReqLLM.Capability.supports?(@model, :streaming) do
    ctx = ReqLLM.Context.new([ReqLLM.Context.user("Tell me a story")])
    
    {:ok, resp} = ReqLLM.stream_text(@model, ctx, max_tokens: 100)
    
    assert resp.id != nil
    text = ReqLLM.Response.text(resp)
    assert is_binary(text)
  else
    skip("Model does not support streaming")
  end
end
```

### Testing Multimodal Capabilities

Test image and other modality support:

```elixir
test "image input processing" do
  modalities = ReqLLM.Capability.modalities(@model)
  input_modalities = get_in(modalities, [:input]) || []
  
  if "image" in input_modalities do
    result = use_fixture(:my_provider, "image_input", fn ->
      # Base64 encoded test image
      image_data = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
      
      ctx = ReqLLM.Context.new([
        ReqLLM.Context.user([
          %{type: "text", text: "What do you see in this image?"},
          %{type: "image", source: %{
            type: "base64",
            media_type: "image/png", 
            data: image_data
          }}
        ])
      ])
      
      ReqLLM.generate_text(@model, ctx, max_tokens: 100)
    end)
    
    {:ok, resp} = result
    assert resp.id != nil
  else
    skip("Model does not support image input")
  end
end
```

## Fixture Management

### Fixture Format

Fixtures are stored as JSON with metadata:

```json
{
  "captured_at": "2024-01-15T10:30:00Z",
  "result": {
    "type": "ok_req_llm_response",
    "data": {
      "id": "resp_123",
      "model": "openai:gpt-4o",
      "message": {
        "role": "assistant",
        "content": [{"type": "text", "text": "Hello there!"}]
      },
      "usage": {"input_tokens": 5, "output_tokens": 3}
    }
  }
}
```

### Fixture Organization

Organize fixtures by provider and test name:

```
test/support/fixtures/
├── anthropic/
│   ├── basic_completion.json
│   ├── system_prompt_completion.json
│   ├── temperature_test.json
│   ├── streaming_test.json
│   ├── tool_calling_basic.json
│   ├── tool_choice_specific.json
│   └── tool_with_result.json
└── openai/
    ├── basic_completion.json
    └── tool_calling_basic.json
```

### LiveFixture API Changes (1.0.0-rc.1)

The LiveFixture API now requires the provider as the first argument:

```elixir
# Current API (1.0.0-rc.1)
use_fixture(:provider_atom, "fixture_name", fn ->
  # test code
end)

# Old API (deprecated)
use_fixture("fixture_name", [], fn ->
  # test code  
end)
```

### Fixture Best Practices

1. **Descriptive naming** - Use clear fixture names that indicate what they test
2. **Minimal responses** - Use `max_tokens` to keep fixtures small
3. **Deterministic content** - Use low temperature for reproducible responses
4. **Regular updates** - Refresh fixtures when APIs change

```elixir
# Good fixture usage
use_fixture(:openai, "low_temperature", fn ->
  ReqLLM.generate_text(@model, ctx, 
    temperature: 0.1,  # Deterministic
    max_tokens: 20     # Minimal
  )
end)
```

## Provider Verification Workflows

### Adding a New Provider

1. **Create provider module** with DSL
2. **Add metadata file** in `priv/models_dev/`
3. **Create coverage tests** using provider macros
4. **Run live tests** to capture fixtures
5. **Validate capabilities** match implementation

```bash
# Create provider tests using macros
# test/coverage/my_provider/core_test.exs
# test/coverage/my_provider/streaming_test.exs
# test/coverage/my_provider/tool_calling_test.exs

# Run live tests to capture fixtures
LIVE=true mix test --only coverage --only my_provider

# Quality check
mix quality
```

### Ongoing Verification

Regular verification workflows:

```bash
# Daily: Validate all providers with fixtures
mix test --only coverage

# Weekly: Refresh critical fixtures
LIVE=true mix test test/coverage/*/core_test.exs

# Release: Full live test suite
LIVE=true mix test --only coverage

# API Changes: Update specific provider
LIVE=true mix test --only anthropic --only coverage
```

## Best Practices

### Test Organization

1. **Use provider macros** - Leverage shared test patterns for consistency
2. **Group by capability** - Organize tests around features, not just providers
3. **Use descriptive names** - Test names should explain what capability is tested
4. **Tag appropriately** - Use ExUnit tags for selective test execution

### Fixture Management

1. **Keep fixtures small** - Use minimal token limits to reduce file size
2. **Use deterministic settings** - Low temperature for consistent responses  
3. **Version control fixtures** - Commit fixtures to track API changes over time
4. **Update regularly** - Refresh fixtures when provider APIs change

### Error Handling

Test error conditions with proper fixture handling:

```elixir
test "handles invalid model gracefully" do
  result = use_fixture(:anthropic, "invalid_model_error", fn ->
    ReqLLM.generate_text("anthropic:invalid-model", "Hello")
  end)
  
  {:error, error} = result
  assert %ReqLLM.Error.API{} = error
end
```

### Environment Management

Handle API keys and environment variables properly:

```elixir
# Skip tests if API key not available  
# Keys are automatically loaded from .env via dotenvy at startup
setup do
  case ReqLLM.Keys.get(:anthropic_api_key) do
    {:ok, _key} -> :ok
    {:error, _reason} -> skip("ANTHROPIC_API_KEY not configured in .env")
  end
end
```

This coverage testing approach ensures that ReqLLM providers work correctly across all supported features and helps maintain compatibility as APIs evolve.
