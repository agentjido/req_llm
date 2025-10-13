defmodule ReqLLM.Debug do
  @moduledoc """
  Centralized debug logging for ReqLLM development and troubleshooting.

  Provides helpers for emitting debug messages when the `REQ_LLM_DEBUG` environment
  variable is set to `"1"`, `"true"`, `"yes"`, or `"on"`.

  ## Usage

      import ReqLLM.Debug, only: [dbug: 1, dbug: 2]

      dbug("Simple message", component: :fixtures)
      dbug(fn -> "Expensive \#{calculation()}" end, component: :stream_server)

  All debug logs are tagged with `req_llm: true` metadata for filtering.
  """

  require Logger

  @env "REQ_LLM_DEBUG"

  @doc """
  Returns true if debug logging is enabled.

  Checks Application config first, then falls back to environment variable.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    case Application.get_env(:req_llm, :debug) do
      nil -> System.get_env(@env) in ["1", "true", "yes", "on"]
      v -> v
    end
  end

  @doc """
  Emit a debug-level log message if debugging is enabled.

  Accepts either a string or a zero-arity function for lazy evaluation.
  Additional metadata can be provided via keyword list.

  ## Examples

      dbg("Starting operation")
      dbg(fn -> "Result: \#{expensive_operation()}" end, component: :fixtures)
  """
  @spec log(String.t() | (-> String.t()), keyword()) :: :ok
  def log(message_or_fun, metadata \\ []) do
    if enabled?() do
      Logger.debug(message_or_fun, Keyword.merge([req_llm: true], metadata))
    else
      :ok
    end
  end

  @doc """
  Emit an info-level log message if debugging is enabled.

  Accepts either a string or a zero-arity function for lazy evaluation.
  Additional metadata can be provided via keyword list.
  """
  @spec info(String.t() | (-> String.t()), keyword()) :: :ok
  def info(message_or_fun, metadata \\ []) do
    if enabled?() do
      Logger.info(message_or_fun, Keyword.merge([req_llm: true], metadata))
    else
      :ok
    end
  end

  @doc """
  Macro alias for `log/2` that can be imported for cleaner syntax.

  ## Examples

      import ReqLLM.Debug, only: [dbug: 2]
      dbug("Message", component: :stream_server)
  """
  defmacro dbug(message_or_fun, metadata \\ []) do
    quote bind_quoted: [message_or_fun: message_or_fun, metadata: metadata] do
      ReqLLM.Debug.log(message_or_fun, metadata)
    end
  end
end
