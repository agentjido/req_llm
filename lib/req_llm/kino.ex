defmodule ReqLLM.Kino do
  @moduledoc """
  Use ReqLLM forms in Livebook. Install `:kino` and `:req_llm` in the notebook.

  Create a form with `ReqLLM.Kino.Prompt`, `ReqLLM.Kino.Image`, or
  `ReqLLM.Kino.Comparison`. Render it with `view/1` and use `result/1` in a later
  cell to read the most recent result.

  Forms send requests when a user submits them. Results are shared within the
  notebook session. Give access only to users who can use the selected credentials.
  """

  @compile {:no_warn_undefined, [Kino, Kino.Control, Kino.Frame, Kino.Layout, Kino.Text]}

  defstruct [:state, :view]

  @type form :: %__MODULE__{state: pid(), view: Kino.Layout.t()}

  @doc "Returns the Kino layout to display in the notebook."
  @spec view(form()) :: Kino.Layout.t()
  def view(%__MODULE__{view: view}), do: view

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
  def result(%__MODULE__{state: state}), do: Agent.get(state, & &1)

  @doc false
  def ensure_kino! do
    unless Code.ensure_loaded?(Kino.Input) do
      raise ArgumentError,
            "Add :kino to Mix.install/1 before you use ReqLLM's Livebook utilities."
    end
  end

  @doc false
  def new(title, fields, submit, run, render) do
    control = Kino.Control.form(fields, submit: submit)
    frame = Kino.Frame.new(placeholder: false)
    state = Kino.start_child!({Agent, fn -> :idle end})

    Kino.async_listen(control, fn
      %{type: :submit, data: data} -> submit(state, frame, data, run, render)
      _event -> :ok
    end)

    view = Kino.Layout.grid([Kino.Text.new(title), control, frame])
    %__MODULE__{state: state, view: view}
  end

  defp submit(state, frame, data, run, render) do
    if Agent.get_and_update(state, &begin_request/1) do
      {result, output} = execute(data, frame, run, render)
      Kino.Frame.render(frame, output)
      Agent.update(state, fn _previous -> result end)
    end
  end

  defp begin_request(:running), do: {false, :running}
  defp begin_request(_previous), do: {true, :running}

  defp execute(%{prompt: prompt} = data, frame, run, render) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      error_output("Enter a prompt.")
    else
      Kino.Frame.render(frame, Kino.Text.new("Request in progress."))

      case run.(data) do
        {:ok, value} = result -> {result, render.(value)}
        {:error, message} -> error_output(message)
      end
    end
  rescue
    _error -> error_output("Could not complete the request.")
  catch
    :exit, _reason -> error_output("Could not complete the request.")
  end

  defp execute(_data, _frame, _run, _render), do: error_output("Enter a prompt.")

  defp error_output(message), do: {{:error, message}, Kino.Text.new(message)}
end
