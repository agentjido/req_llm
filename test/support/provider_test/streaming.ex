defmodule ReqLLM.ProviderTest.Streaming do
  @moduledoc """
  Streaming text generation tests.

  Tests stream-based generation features:
  - Basic streaming with text chunks
  - Stream completion and metadata
  - StreamChunk validation and parsing

  ## Usage

      defmodule ReqLLM.Coverage.Anthropic.StreamingTest do
        use ReqLLM.ProviderTest.Streaming, provider: :anthropic
      end

  This will generate tests for all models selected by ModelMatrix for the provider.

  ## Debug Output

  Set REQ_LLM_DEBUG=1 to enable verbose fixture output during test runs.
  """

  defmacro __using__(opts) do
    provider = Keyword.fetch!(opts, :provider)

    quote bind_quoted: [provider: provider] do
      use ExUnit.Case, async: false

      import ReqLLM.Test.Helpers

      alias ReqLLM.Test.ModelMatrix

      @moduletag :coverage
      @moduletag category: :streaming
      @moduletag provider: provider

      defp debug?, do: System.get_env("REQ_LLM_DEBUG") in ["1", "true"]

      @provider provider
      @models ModelMatrix.models_for_provider(provider)

      for model_spec <- @models do
        @model_spec model_spec

        describe "#{model_spec}" do
          test "basic streaming" do
            require Logger

            model_name =
              @model_spec |> String.split(":") |> List.last() |> String.replace("-", "_")

            fixture_name = "#{model_name}_streaming_basic"

            if debug?() do
              IO.puts("\n[StreamingTest] model_spec=#{@model_spec}, model_name=#{model_name}")
              IO.puts("[StreamingTest] fixture_name=#{fixture_name}, provider=#{@provider}")
            end

            Logger.debug("StreamingTest: model_spec=#{@model_spec}")
            Logger.debug("StreamingTest: fixture_name=#{fixture_name}")

            {:ok, stream_response} =
              ReqLLM.stream_text(
                @model_spec,
                "Say hello briefly",
                fixture_opts(@provider, fixture_name, param_bundles(@provider).deterministic)
              )

            # Verify StreamResponse structure
            assert %ReqLLM.StreamResponse{} = stream_response
            assert stream_response.stream
            assert stream_response.metadata_task

            # Extract text first (consumes the stream)
            text = ReqLLM.StreamResponse.text(stream_response)
            assert is_binary(text)
            assert String.length(text) > 0

            # Verify we can get metadata
            usage = ReqLLM.StreamResponse.usage(stream_response)
            assert is_map(usage) or is_nil(usage)
          end
        end
      end
    end
  end
end
