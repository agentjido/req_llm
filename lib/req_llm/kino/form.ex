defmodule ReqLLM.Kino.Form do
  @moduledoc false

  @compile {:no_warn_undefined, [Kino, Kino.Control, Kino.Frame, Kino.Layout, Kino.Text]}

  defstruct [:state, :view]
  @opaque t :: %__MODULE__{state: pid(), view: struct()}

  def ensure_kino! do
    unless Code.ensure_loaded?(Kino.Input) do
      raise ArgumentError,
            "Add :kino to Mix.install/1 before you use ReqLLM's Livebook utilities."
    end
  end

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

  def view(%__MODULE__{view: view}), do: view
  def result(%__MODULE__{state: state}), do: Agent.get(state, & &1)

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
  end

  defp execute(_data, _frame, _run, _render), do: error_output("Enter a prompt.")

  defp error_output(message), do: {{:error, message}, Kino.Text.new(message)}
end
