defmodule ReqLLM.StreamingCase do
  @moduledoc """
  Test case template for streaming tests that need to configure Finch pools.

  Automatically saves and restores Finch configuration between tests.

  ## Example

      defmodule MyStreamingTest do
        use ReqLLM.StreamingCase

        test "something with HTTP/2" do
          configure_http2_pools!()
          # test code
        end
      end
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use ExUnit.Case, async: false

      import ReqLLM.StreamingCase
    end
  end

  setup do
    original_finch = Application.get_env(:req_llm, :finch, [])
    original_mode = System.get_env("REQ_LLM_FIXTURES_MODE")
    original_api_key = System.get_env("OPENAI_API_KEY")

    System.put_env("REQ_LLM_FIXTURES_MODE", "replay")
    System.put_env("OPENAI_API_KEY", "test-streaming-key")

    on_exit(fn ->
      Application.put_env(:req_llm, :finch, original_finch)

      case original_mode do
        nil -> System.delete_env("REQ_LLM_FIXTURES_MODE")
        _ -> System.put_env("REQ_LLM_FIXTURES_MODE", original_mode)
      end

      case original_api_key do
        nil -> System.delete_env("OPENAI_API_KEY")
        _ -> System.put_env("OPENAI_API_KEY", original_api_key)
      end
    end)

    :ok
  end

  @doc """
  Configure Finch pools with custom protocol list.
  """
  def configure_pools!(protocols) when is_list(protocols) do
    Application.put_env(:req_llm, :finch,
      name: ReqLLM.Finch,
      pools: %{
        default: [protocols: protocols, size: 1, count: 8]
      }
    )
  end

  @doc """
  Configure Finch pools to use HTTP/2 with HTTP/1 fallback.
  """
  def configure_http2_pools! do
    configure_pools!([:http2, :http1])
  end

  @doc """
  Configure Finch pools to use HTTP/1 only (default).
  """
  def configure_http1_pools! do
    configure_pools!([:http1])
  end
end
