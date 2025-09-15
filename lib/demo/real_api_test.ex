defmodule Demo.RealApiTest do
  @moduledoc """
  Real API test to demonstrate the max_tokens vs max_completion_tokens issue
  with actual OpenAI API calls.
  """

  def run do
    IO.puts("Real API Test: max_tokens vs max_completion_tokens")
    IO.puts("=" <> String.duplicate("=", 60))

    case check_api_key() do
      {:ok, _key} ->
        test_different_models()

      {:error, reason} ->
        IO.puts("❌ #{reason}")
        IO.puts("To run this test, set: export OPENAI_API_KEY=your_key_here")
    end
  end

  defp check_api_key do
    case ReqLLM.get_key(:openai_api_key) do
      nil -> {:error, "OPENAI_API_KEY not available"}
      "" -> {:error, "OPENAI_API_KEY is empty"}
      key -> {:ok, key}
    end
  end

  defp test_different_models do
    # Test models that should work vs those that should fail
    test_cases = [
      %{
        model: "openai:gpt-4o-mini",
        description: "GPT-4o Mini (should work with max_tokens)",
        should_work: true
      },
      %{
        model: "openai:o1-mini",
        description: "O1 Mini (should fail with max_tokens)",
        should_work: false
      }
    ]

    opts = [
      max_tokens: 50,
      temperature: 0.7
    ]

    Enum.each(test_cases, fn test_case ->
      test_model(test_case.model, test_case.description, test_case.should_work, opts)
    end)
  end

  defp test_model(model_spec, description, should_work, opts) do
    IO.puts("\n--- Testing #{description} ---")

    result = ReqLLM.Generation.generate_text!(model_spec, "Say 'hello' briefly", opts)

    case {result, should_work} do
      {{:ok, text}, true} ->
        IO.puts("✅ SUCCESS (as expected): #{String.slice(text, 0, 100)}")

      {{:error, %ReqLLM.Error.API.Request{} = error}, false} ->
        IO.puts("❌ API ERROR (as expected): #{inspect(error.reason)}")

        if error.status do
          IO.puts("   Status: #{error.status}")
        end

        # Show request and response bodies for debugging
        if error.request_body do
          IO.puts("   Request Body: #{String.slice(inspect(error.request_body), 0, 300)}...")
        end

        if error.response_body do
          body_str = inspect(error.response_body)

          if String.contains?(body_str, "max_tokens") or
               String.contains?(body_str, "max_completion_tokens") do
            IO.puts("   🎯 Found max_tokens parameter issue!")
          end

          IO.puts("   Response Body: #{String.slice(body_str, 0, 300)}...")
        end

      {{:ok, text}, false} ->
        IO.puts("🤔 UNEXPECTED SUCCESS: #{String.slice(text, 0, 100)}")
        IO.puts("   (This model might now support max_tokens)")

      {{:error, error}, true} ->
        IO.puts("❌ UNEXPECTED ERROR: #{inspect(error)}")

      {{:error, error}, false} ->
        IO.puts("❌ ERROR (expected but wrong type): #{inspect(error)}")
    end
  end

  def test_with_provider_options do
    IO.puts("\n--- Testing with provider_options workaround ---")

    # Try using provider_options as a workaround
    opts = [
      temperature: 0.7,
      provider_options: [
        max_completion_tokens: 50
      ]
    ]

    case ReqLLM.Generation.generate_text!("openai:o1-mini", "Say 'hello' briefly", opts) do
      {:ok, text} ->
        IO.puts("✅ Provider options workaround worked: #{String.slice(text, 0, 100)}")

      {:error, error} ->
        IO.puts("❌ Provider options workaround failed: #{inspect(error)}")
    end
  end
end
