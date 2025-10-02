defmodule ReqLLM.Test.Env do
  @moduledoc """
  Centralized environment variable configuration for ReqLLM tests.

  Provides validated, typed access to test configuration via environment variables.
  Supports both new namespaced variables (REQ_LLM_*) and legacy variables for
  backward compatibility.

  ## Environment Variables

  - `REQ_LLM_FIXTURES_MODE` - "record" or "replay" (default: "replay")
  - `REQ_LLM_MODELS` - Model selection pattern (default: from config)
  - `REQ_LLM_SAMPLE` - Number of models to sample per provider
  - `REQ_LLM_EXCLUDE` - Space/comma-separated models to exclude
  - `REQ_LLM_TIMEOUT` - API timeout in milliseconds (default: 30000)

  ## Examples

      # Check fixture mode
      case Env.fixtures_mode() do
        :record -> # Hit live API
        :replay -> # Use cached fixtures
      end
      
      # Get timeout
      timeout = Env.timeout()  # 30000 or custom value
      
      # Debug configuration
      Env.config() |> IO.inspect()
  """

  @default_timeout 30_000

  @doc """
  Get fixture recording/replay mode.

  ## Valid Values

  - `"record"` - Record fixtures from live API calls
  - `"replay"` - Replay from cached fixtures (default)

  ## Examples

      iex> System.put_env("REQ_LLM_FIXTURES_MODE", "record")
      iex> Env.fixtures_mode()
      :record
      
      iex> System.delete_env("REQ_LLM_FIXTURES_MODE")
      iex> Env.fixtures_mode()
      :replay
  """
  @spec fixtures_mode() :: :record | :replay
  def fixtures_mode do
    require Logger

    mode_env = System.get_env("REQ_LLM_FIXTURES_MODE")

    mode =
      case mode_env do
        "record" ->
          :record

        "replay" ->
          :replay

        nil ->
          :replay

        other ->
          raise ArgumentError, """
          Invalid REQ_LLM_FIXTURES_MODE: #{inspect(other)}

          Valid values: "record", "replay"

          Examples:
            REQ_LLM_FIXTURES_MODE=record mix test  # Record new fixtures
            REQ_LLM_FIXTURES_MODE=replay mix test  # Use cached fixtures (default)
          """
      end

    Logger.debug("Env.fixtures_mode: REQ_LLM_FIXTURES_MODE=#{inspect(mode_env)}, mode=#{mode}")

    mode
  end

  @doc """
  Get API timeout in milliseconds.

  Used for live API calls during fixture recording.

  ## Examples

      iex> System.put_env("REQ_LLM_TIMEOUT", "60000")
      iex> Env.timeout()
      60000
      
      iex> System.delete_env("REQ_LLM_TIMEOUT")
      iex> Env.timeout()
      30000  # default
  """
  @spec timeout() :: pos_integer()
  def timeout do
    case System.get_env("REQ_LLM_TIMEOUT") do
      nil ->
        @default_timeout

      timeout_str ->
        case Integer.parse(timeout_str) do
          {timeout, _} when timeout > 0 ->
            timeout

          _ ->
            raise ArgumentError, """
            Invalid REQ_LLM_TIMEOUT: #{inspect(timeout_str)}

            Must be a positive integer (milliseconds).

            Example:
              REQ_LLM_TIMEOUT=60000 mix test  # 60 second timeout
            """
        end
    end
  end

  @doc """
  Get all environment configuration as a map.

  Useful for debugging and logging test configuration.

  ## Examples

      iex> Env.config()
      %{
        fixtures_mode: :replay,
        timeout: 30000,
        models: nil,
        sample: nil,
        exclude: nil
      }
  """
  @spec config() :: map()
  def config do
    %{
      fixtures_mode: fixtures_mode(),
      timeout: timeout(),
      models: System.get_env("REQ_LLM_MODELS"),
      sample: System.get_env("REQ_LLM_SAMPLE"),
      exclude: System.get_env("REQ_LLM_EXCLUDE")
    }
  end
end
