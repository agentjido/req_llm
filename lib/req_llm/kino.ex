defmodule ReqLLM.Kino do
  @moduledoc """
  Use ReqLLM forms in Livebook. Install `:kino` and `:req_llm` in the notebook.

  Create a form with `ReqLLM.Kino.Prompt`, `ReqLLM.Kino.Image`, or
  `ReqLLM.Kino.Comparison`. Render it with `view/1` and use `result/1` in a later
  cell to read the most recent result.

  Forms send requests when a user submits them. Results are shared within the
  notebook session. Give access only to users who can use the selected credentials.
  """

  alias ReqLLM.Kino.Form

  @type form :: Form.t()

  @doc "Returns the Kino layout to display in the notebook."
  @spec view(form()) :: struct()
  defdelegate view(form), to: Form

  @doc """
  Reads the latest form result.

  Returns `:idle` before the first request, `:running` while a request is in
  progress, `{:ok, value}` on success, or `{:error, message}` on failure. The
  value is a `ReqLLM.Response` for text and images, or a list of comparison rows.
  """
  @spec result(form()) ::
          :idle
          | :running
          | {:ok, ReqLLM.Response.t() | [ReqLLM.Kino.Comparison.row()]}
          | {:error, String.t()}
  defdelegate result(form), to: Form
end
