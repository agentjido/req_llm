# Data Structures Guide

ReqLLM 1.0.0-rc.1 core data structures and practical usage patterns. Six primary structures provide unified, provider-agnostic AI interactions.

## Table of Contents

1. [Core Structure Overview](#core-structure-overview)
2. [Model Configuration](#model-configuration)
3. [Context and Message Management](#context-and-message-management)
4. [Multimodal Content Handling](#multimodal-content-handling)
5. [Tool Calling Patterns](#tool-calling-patterns)
6. [Streaming Response Processing](#streaming-response-processing)
7. [Type Safety and Validation](#type-safety-and-validation)
8. [Advanced Composition Patterns](#advanced-composition-patterns)

## Core Structure Overview

Hierarchical data structure design:

```
ReqLLM.Model          # Model configuration and capabilities
    ↓
ReqLLM.Context        # Collection of conversation messages  
    ↓
ReqLLM.Message        # Individual conversation turn
    ↓
ReqLLM.Message.ContentPart  # Typed content within messages
    ↓
ReqLLM.StreamChunk    # Streaming response chunks
    ↓
ReqLLM.Tool           # Function calling definitions
```

Design principles: provider-agnostic, type-safe with discriminated unions, composable immutable structures, extensible via metadata.

## Model Configuration

### Basic Model Creation

`ReqLLM.Model` struct represents AI model configurations with provider information, runtime parameters, and optional metadata.

```elixir
# From string specification (simplest)
{:ok, model} = ReqLLM.Model.from("anthropic:claude-3-5-sonnet")

# From tuple with configuration
{:ok, model} = ReqLLM.Model.from({:anthropic, 
  "claude-3-5-sonnet", 
  temperature: 0.7, 
  max_tokens: 1000
})

# Direct construction with full control
model = ReqLLM.Model.new(:anthropic, "claude-3-5-sonnet", 
  temperature: 0.5,
  max_tokens: 2000,
  capabilities: %{reasoning?: true, tool_call?: true}
)
```

### Advanced Model Configuration

```elixir
# Model with comprehensive metadata
model = ReqLLM.Model.new(:anthropic, "claude-3-5-sonnet",
  temperature: 0.3,
  max_tokens: 4000,
  max_retries: 5,
  limit: %{context: 200_000, output: 8192},
  modalities: %{
    input: [:text, :image, :pdf],
    output: [:text]
  },
  capabilities: %{
    reasoning?: true,
    tool_call?: true,
    supports_temperature?: true
  },
  cost: %{input: 3.0, output: 15.0}  # Per 1K tokens
)

# Provider-agnostic model switching
models = [
  ReqLLM.Model.from("anthropic:claude-3-5-sonnet"),
  ReqLLM.Model.from("openai:gpt-4"),
  ReqLLM.Model.from("google:gemini-pro")
]

# All use identical API
context = ReqLLM.Context.new([
  ReqLLM.Context.user("What's 2+2?")
])

for {:ok, model} <- models do
  {:ok, response} = ReqLLM.generate_text(model, context)
  IO.puts("#{model.provider}: #{response.message.content}")
end
```

## Context and Message Management

### Building Conversations

`ReqLLM.Context` struct manages conversation history as a collection of messages with convenient constructor functions.

```elixir
import ReqLLM.Context
alias ReqLLM.Message.ContentPart

# Build natural conversations
context = Context.new([
  system("You are a helpful assistant specializing in data analysis."),
  user("Can you help me analyze some data?"),
  assistant("I'd be happy to help! Please share your data."),
  user([
    ContentPart.text("Here's my sales data:"),
    ContentPart.file(csv_data, "sales.csv", "text/csv")
  ])
])
```

### Message Composition Patterns

Messages always contain lists of `ContentPart` structs, eliminating polymorphism:

```elixir
# Text-only message (still uses list)
simple_message = %ReqLLM.Message{
  role: :user,
  content: [ContentPart.text("Hello world")]
}

# Complex multimodal message
complex_message = %ReqLLM.Message{
  role: :user,
  content: [
    ContentPart.text("Please analyze this document and image:"),
    ContentPart.file(pdf_data, "report.pdf", "application/pdf"),
    ContentPart.text("Compare it with this chart:"),
    ContentPart.image_url("https://example.com/chart.png"),
    ContentPart.text("What trends do you see?")
  ]
}

# Adding to existing context
updated_context = Context.add_message(context, complex_message)
```

### Context Enumeration and Manipulation

```elixir
# Context implements Enumerable
user_messages = context
|> Enum.filter(&(&1.role == :user))
|> length()

# Context implements Collectable
new_message = user("What about pricing trends?")
extended_context = Enum.into([new_message], context)

# Transform conversation
anonymized_context = context
|> Enum.map(fn msg ->
  %{msg | content: Enum.map(msg.content, &anonymize_content/1)}
end)
|> Context.new()
```

## Multimodal Content Handling

### Content Type Overview

`ReqLLM.Message.ContentPart` supports multiple content types through a discriminated union:

```elixir
# Text content
text_part = ContentPart.text("Explain this data")

# Reasoning content (for models supporting chain-of-thought)
thinking_part = ContentPart.thinking("Let me think step by step...")

# Image from URL
image_url_part = ContentPart.image_url("https://example.com/chart.jpg")

# Image from binary data  
{:ok, image_data} = File.read("photo.png")
image_part = ContentPart.image(image_data, "image/png")

# File attachment
{:ok, document_data} = File.read("report.pdf")
file_part = ContentPart.file(document_data, "report.pdf", "application/pdf")
```

### Building Complex Multimodal Conversations

```elixir
# Document analysis conversation
analyze_documents = fn documents ->
  content_parts = [
    ContentPart.text("Please analyze these documents for key insights:")
  ]
  
  doc_parts = Enum.flat_map(documents, fn {filename, data, mime_type} ->
    [
      ContentPart.text("Document: #{filename}"),
      ContentPart.file(data, filename, mime_type)
    ]
  end)
  
  question_parts = [
    ContentPart.text("Questions:"),
    ContentPart.text("1. What are the main themes?"),
    ContentPart.text("2. Are there any concerning patterns?"),
    ContentPart.text("3. What recommendations do you have?")
  ]
  
  content_parts ++ doc_parts ++ question_parts
end

documents = [
  {"quarterly_report.pdf", report_data, "application/pdf"},
  {"sales_data.csv", csv_data, "text/csv"},
  {"customer_feedback.txt", feedback_data, "text/plain"}
]

context = Context.new([
  system("You are an expert business analyst."),
  user(analyze_documents.(documents))
])
```

### Image Processing Workflows

```elixir
# Multi-image comparison
compare_images = fn image_urls ->
  Context.new([
    system("You are an expert image analyst."),
    user([
      ContentPart.text("Compare these images and identify differences:")
    ] ++ Enum.with_index(image_urls, 1)
    |> Enum.flat_map(fn {url, idx} ->
      [
        ContentPart.text("Image #{idx}:"),
        ContentPart.image_url(url)
      ]
    end) ++ [
      ContentPart.text("Provide a detailed comparison focusing on:"),
      ContentPart.text("- Visual differences"),
      ContentPart.text("- Quality variations"),
      ContentPart.text("- Content changes")
    ])
  ])
end

# Usage
image_urls = [
  "https://example.com/before.jpg",
  "https://example.com/after.jpg"
]

context = compare_images.(image_urls)
{:ok, response} = ReqLLM.generate_text(model, context)
```

## Tool Calling Patterns

### Basic Tool Definition

`ReqLLM.Tool` struct defines functions that AI models can call:

```elixir
# Simple weather tool
{:ok, weather_tool} = ReqLLM.Tool.new(
  name: "get_weather",
  description: "Get current weather conditions for a location",
  parameter_schema: [
    location: [type: :string, required: true, doc: "City name or coordinates"],
    units: [type: :string, default: "celsius", doc: "Temperature units (celsius/fahrenheit)"]
  ],
  callback: {WeatherService, :get_current_weather}
)

# Execute tool directly
{:ok, result} = ReqLLM.Tool.execute(weather_tool, %{location: "New York"})
# => {:ok, %{temperature: 22, conditions: "sunny", units: "celsius"}}
```

### Advanced Tool Patterns

```elixir
# Database query tool with validation
{:ok, db_tool} = ReqLLM.Tool.new(
  name: "query_database",
  description: "Execute read-only SQL queries on the sales database",
  parameter_schema: [
    query: [type: :string, required: true, doc: "SELECT SQL query"],
    limit: [type: :pos_integer, default: 100, doc: "Maximum rows to return"]
  ],
  callback: fn params ->
    # Validate query safety
    if String.contains?(String.downcase(params.query), ["insert", "update", "delete", "drop"]) do
      {:error, "Only SELECT queries are allowed"}
    else
      DatabaseService.execute_query(params.query, params.limit)
    end
  end
)

# File system tool with path restrictions
{:ok, file_tool} = ReqLLM.Tool.new(
  name: "read_file",
  description: "Read contents of files in the allowed directory",
  parameter_schema: [
    filename: [type: :string, required: true, doc: "Filename to read"],
    encoding: [type: :string, default: "utf-8", doc: "File encoding"]
  ],
  callback: {FileService, :read_safe_file, ["/safe/directory"]}
)
```

### Tool Calling in Conversations

```elixir
# Multi-tool conversation
tools = [weather_tool, db_tool, file_tool]

context = Context.new([
  system("You have access to weather data, database queries, and file reading. Use these tools to help users."),
  user("What's the weather in NYC, and can you also show me the top 5 sales from our database?")
])

# Generate with tools
{:ok, response} = ReqLLM.generate_text(model, context, 
  tools: tools,
  max_tokens: 1000
)

# Process tool calls from response
response.context.messages
|> Enum.flat_map(fn msg -> msg.content end)
|> Enum.filter(&(&1.type == :tool_call))
|> Enum.each(fn tool_call ->
  tool = Enum.find(tools, &(&1.name == tool_call.tool_name))
  {:ok, result} = ReqLLM.Tool.execute(tool, tool_call.input)
  IO.puts("#{tool_call.tool_name}: #{inspect(result)}")
end)
```

### Tool Result Integration

```elixir
# Handle tool execution in conversation flow
execute_tools_in_context = fn context, tools ->
  # Find tool calls in the latest assistant message
  latest_message = List.last(context.messages)
  
  tool_calls = latest_message.content
  |> Enum.filter(&(&1.type == :tool_call))
  
  # Execute each tool call
  tool_results = Enum.map(tool_calls, fn tool_call ->
    tool = Enum.find(tools, &(&1.name == tool_call.tool_name))
    {:ok, result} = ReqLLM.Tool.execute(tool, tool_call.input)
    
    ContentPart.tool_result(tool_call.tool_call_id, result)
  end)
  
  # Add tool results as a user message
  if tool_results != [] do
    Context.add_message(context, %ReqLLM.Message{
      role: :user,
      content: tool_results
    })
  else
    context
  end
end

# Multi-turn tool conversation
{:ok, response1} = ReqLLM.generate_text(model, context, tools: tools)
context_with_results = execute_tools_in_context.(response1.context, tools)

# Continue conversation with tool results
{:ok, response2} = ReqLLM.generate_text(model, context_with_results, tools: tools)
```

## Streaming Response Processing

### Basic Streaming

`ReqLLM.StreamChunk` struct provides a unified format for streaming responses with fields `type`, `text`, `name`, `arguments`, `metadata`:

```elixir
{:ok, response} = ReqLLM.stream_text(model, context)

# Basic text streaming
response.body
|> Stream.filter(&(&1.type == :content))
|> Stream.map(&(&1.text))
|> Stream.each(&IO.write/1)
|> Stream.run()
```

### Advanced Stream Processing

```elixir
# Stream processor with chunk type handling
process_stream = fn stream ->
  stream.body
  |> Stream.each(fn chunk ->
    case chunk.type do
      :content -> 
        IO.write(chunk.text)
        
      :thinking -> 
        IO.puts(IO.ANSI.cyan() <> "[thinking: #{chunk.text}]" <> IO.ANSI.reset())
        
      :tool_call -> 
        IO.puts(IO.ANSI.yellow() <> "[calling #{chunk.name}(#{inspect(chunk.arguments)})]" <> IO.ANSI.reset())
        
      :meta -> 
        case chunk.metadata do
          %{finish_reason: reason} -> 
            IO.puts(IO.ANSI.green() <> "\n[finished: #{reason}]" <> IO.ANSI.reset())
          %{usage: usage} -> 
            IO.puts(IO.ANSI.blue() <> "[tokens: #{usage.input_tokens + usage.output_tokens}]" <> IO.ANSI.reset())
          _ -> 
            :ok
        end
    end
  end)
  |> Stream.run()
end

{:ok, response} = ReqLLM.stream_text(model, context)
process_stream.(response)
```

### Streaming with Real-time Processing

```elixir
# Accumulate content while streaming
stream_with_accumulation = fn model, context ->
  {:ok, response} = ReqLLM.stream_text(model, context)
  
  {final_content, tool_calls, metadata} = 
    response.body
    |> Enum.reduce({"", [], %{}}, fn chunk, {content, tools, meta} ->
      case chunk.type do
        :content -> 
          new_content = content <> chunk.text
          IO.write(chunk.text)  # Real-time display
          {new_content, tools, meta}
          
        :tool_call -> 
          new_tools = [chunk | tools]
          {content, new_tools, meta}
          
        :meta -> 
          new_meta = Map.merge(meta, chunk.metadata)
          {content, tools, new_meta}
          
        _ -> 
          {content, tools, meta}
      end
    end)
  
  %{content: final_content, tool_calls: Enum.reverse(tool_calls), metadata: metadata}
end

result = stream_with_accumulation.(model, context)
IO.puts("\n\nFinal result: #{result.content}")
```

### Streaming Tool Execution

```elixir
# Stream with live tool execution
stream_with_tools = fn model, context, tools ->
  {:ok, response} = ReqLLM.stream_text(model, context, tools: tools)
  
  response.body
  |> Stream.transform(%{}, fn chunk, state ->
    case chunk.type do
      :content ->
        IO.write(chunk.text)
        {[], state}
        
      :tool_call ->
        # Execute tool immediately when streaming completes the call
        if Map.has_key?(chunk.arguments, :complete) do
          tool = Enum.find(tools, &(&1.name == chunk.name))
          {:ok, result} = ReqLLM.Tool.execute(tool, chunk.arguments)
          IO.puts("\n[Tool #{chunk.name} result: #{inspect(result)}]")
        end
        {[], state}
        
      _ ->
        {[], state}
    end
  end)
  |> Stream.run()
end
```

## Type Safety and Validation

### Struct Validation

ReqLLM provides validation functions for type safety:

```elixir
# Context validation
validate_conversation = fn context ->
  case ReqLLM.Context.validate(context) do
    {:ok, valid_context} -> 
      IO.puts("✓ Context is valid with #{length(valid_context.messages)} messages")
      valid_context
      
    {:error, reason} -> 
      IO.puts("✗ Context validation failed: #{reason}")
      raise ArgumentError, "Invalid context: #{reason}"
  end
end

# StreamChunk validation
validate_chunk = fn chunk ->
  case ReqLLM.StreamChunk.validate(chunk) do
    {:ok, valid_chunk} -> valid_chunk
    {:error, reason} -> raise ArgumentError, "Invalid chunk: #{reason}"
  end
end

# Usage in processing pipeline
context
|> validate_conversation.()
|> ReqLLM.generate_text(model)
```

### ContentPart Type Guards

```elixir
# Type-safe content processing
process_content_parts = fn parts ->
  Enum.map(parts, fn part ->
    case part.type do
      :text -> 
        String.length(part.text)
        
      :image_url -> 
        {:url, URI.parse(part.url)}
        
      :image -> 
        {:binary, byte_size(part.data)}
        
      :file -> 
        {:file, part.filename, byte_size(part.data)}
        
      :tool_call -> 
        {:tool, part.tool_name, map_size(part.input)}
        
      :tool_result -> 
        {:result, part.tool_call_id, part.output}
        
      :reasoning -> 
        {:thinking, String.length(part.text)}
    end
  end)
end

# Safe content extraction
extract_text_content = fn message ->
  message.content
  |> Enum.filter(&(&1.type == :text))
  |> Enum.map(&(&1.text))
  |> Enum.join(" ")
end
```

### Custom Validation Patterns

```elixir
# Simple validation
defmodule ContextValidator do
  def validate(context) do
    cond do
      length(context.messages) > 100 -> {:error, "Too many messages"}
      alternates_properly?(context) -> {:ok, context}
      true -> {:error, "Invalid role flow"}
    end
  end
  
  defp alternates_properly?(context) do
    roles = Enum.map(context.messages, & &1.role)
    # Check user/assistant alternation logic here
    true
  end
end
```

## Advanced Composition Patterns

### Conversation Templates

```elixir
# Reusable templates
defmodule Templates do
  import ReqLLM.Context
  alias ReqLLM.Message.ContentPart
  
  def code_review(code, language) do
    Context.new([
      system("You are a code reviewer. Provide concise, actionable feedback."),
      user([
        ContentPart.text("Review this #{language} code:"),
        ContentPart.text("```#{language}\n#{code}\n```")
      ])
    ])
  end
  
  def document_analysis(files) do
    content_parts = [ContentPart.text("Analyze these documents:")] ++
      Enum.map(files, fn {data, name, type} ->
        ContentPart.file(data, name, type)
      end)
    
    Context.new([
      system("You are a document analyst. Provide key insights."),
      user(content_parts)
    ])
  end
end

# Usage
context = Templates.code_review("def hello, do: :world", "elixir")
{:ok, response} = ReqLLM.generate_text(model, context)
```

### Analysis Pipeline

```elixir
# Simple analysis pipeline
defmodule SimpleAnalysis do
  def analyze(text, model) do
    context = ReqLLM.Context.new([
      ReqLLM.Context.system("You are a data analyst. Provide concise insights."),
      ReqLLM.Context.user(text)
    ])
    
    {:ok, response} = ReqLLM.generate_text(model, context)
    
    response.context.messages
    |> List.last()
    |> Map.get(:content, [])
    |> Enum.find(&(&1.type == :text))
    |> Map.get(:text, "")
  end
end

# Usage
analysis = SimpleAnalysis.analyze("Sales increased 15%", model)
```

### Multi-Model Orchestration

```elixir
# Use different models for specialized tasks
text_model = ReqLLM.Model.from!("anthropic:claude-3-haiku")
vision_model = ReqLLM.Model.from!("anthropic:claude-3-5-sonnet")

# Text analysis
{:ok, text_result} = ReqLLM.generate_text(text_model, text_context)

# Vision analysis  
{:ok, vision_result} = ReqLLM.generate_text(vision_model, image_context)

# Combine results
final_analysis = text_result.content <> " " <> vision_result.content
```

ReqLLM 1.0.0-rc.1 provides type-safe, provider-agnostic data structures for building composable AI workflows. Each structure builds on the others to create a unified foundation for AI application development.
