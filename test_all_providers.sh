#!/bin/bash

# Simple test script for all ReqLLM providers
# Tests both normal and streaming text generation

echo "=========================================="
echo "    ReqLLM Provider Test Suite"
echo "=========================================="
echo ""

PROMPT="Write a haiku about programming"

# Test function
test_provider() {
    local model=$1
    local mode=$2
    local stream_flag=$3
    
    echo "Testing: $model ($mode)"
    echo "Command: mix req_llm.gen \"$PROMPT\" --model \"$model\" $stream_flag"
    echo ""
    
    if mix req_llm.gen "$PROMPT" --model "$model" $stream_flag; then
        echo "✅ SUCCESS"
    else
        echo "❌ FAILED"
    fi
    
    echo ""
    echo "----------------------------------------"
    echo ""
}

# OpenAI
echo "=== Testing OpenAI ==="
test_provider "openai:gpt-4o-mini" "normal" ""
test_provider "openai:gpt-4o-mini" "streaming" "--stream"

# Anthropic
echo "=== Testing Anthropic ==="
test_provider "anthropic:claude-3-haiku-20240307" "normal" ""
test_provider "anthropic:claude-3-haiku-20240307" "streaming" "--stream"

# Google
echo "=== Testing Google ==="
test_provider "google:gemini-2.0-flash" "normal" ""
test_provider "google:gemini-2.0-flash" "streaming" "--stream"

# Groq
echo "=== Testing Groq ==="
test_provider "groq:llama-3.1-8b-instant" "normal" ""
test_provider "groq:llama-3.1-8b-instant" "streaming" "--stream"

# OpenRouter
echo "=== Testing OpenRouter ==="
test_provider "openrouter:meta-llama/llama-3.3-70b-instruct:free" "normal" ""
test_provider "openrouter:meta-llama/llama-3.3-70b-instruct:free" "streaming" "--stream"

# xAI
echo "=== Testing xAI ==="
test_provider "xai:grok-3" "normal" ""
test_provider "xai:grok-3" "streaming" "--stream"

echo "=========================================="
echo "All tests completed!"
echo "=========================================="
