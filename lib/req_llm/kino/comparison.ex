defmodule ReqLLM.Kino.Comparison do
  @moduledoc """
  Compare text responses to the same prompt across models in Livebook. Each row
  records the model, elapsed time in milliseconds, and response or error.

  See the [Livebook Tools example](livebook-model-picker.livemd).
  """

  alias ReqLLM.Kino.{Form, Prompt, Request}
  alias ReqLLM.Response

  @compile {:no_warn_undefined, [Kino.Layout, Kino.Text]}

  @type row :: %{
          model: LLMDB.Model.t(),
          elapsed_ms: non_neg_integer(),
          result: {:ok, Response.t()} | {:error, String.t()}
        }

  @doc """
  Creates a comparison form for at least two model specs. It accepts `:default_prompt`,
  `:system_message`, and `:request_options`. Pass a three-element model tuple to
  set request defaults for one model. Shared request options take precedence.

  Each submission sends one request per model. Results stay in the order of the
  model list. A failed request does not stop the other requests.
  """
  @spec new([ReqLLM.model_input()], keyword()) :: ReqLLM.Kino.form()
  def new(model_specs, opts \\ [])

  def new([_, _ | _] = model_specs, opts) do
    Form.ensure_kino!()
    opts = Keyword.validate!(opts, default_prompt: "", system_message: "", request_options: [])
    requests = Enum.map(model_specs, &Request.resolve!(&1, :chat, opts[:request_options]))
    title = Enum.map_join(requests, "\n", fn {model, _} -> LLMDB.Model.spec(model) end)

    Form.new(
      title,
      Prompt.fields(opts),
      "Run #{length(requests)} requests",
      fn data ->
        compare(requests, Prompt.messages(data))
      end,
      &render/1
    )
  end

  def new(_model_specs, _opts), do: raise(ArgumentError, "Supply at least two models to compare.")

  defp compare(requests, messages) do
    rows =
      requests
      |> Task.async_stream(&run_model(&1, messages), max_concurrency: 4, timeout: :infinity)
      |> Enum.map(fn {:ok, row} -> row end)

    {:ok, rows}
  end

  defp run_model({model, _options} = request, messages) do
    started_at = System.monotonic_time(:millisecond)
    result = Request.run(&ReqLLM.generate_text/3, request, messages)

    %{model: model, elapsed_ms: System.monotonic_time(:millisecond) - started_at, result: result}
  end

  defp render(rows) do
    Kino.Layout.grid(Enum.map(rows, &render_row/1), columns: min(length(rows), 3))
  end

  defp render_row(row) do
    details = [LLMDB.Model.spec(row.model), "Time: #{row.elapsed_ms} ms"]

    lines =
      case row.result do
        {:ok, response} ->
          details ++ Request.measurements(response) ++ [Response.text(response) || ""]

        {:error, message} ->
          details ++ [message]
      end

    Kino.Text.new(Enum.join(lines, "\n\n"))
  end
end
