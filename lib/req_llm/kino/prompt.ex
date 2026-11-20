defmodule ReqLLM.Kino.Prompt do
  @moduledoc """
  Run a text prompt from Livebook. The form has a prompt, an optional system
  message, and a Run button. Use `ReqLLM.Kino.result/1` to read the response.

  See the [Livebook Tools example](livebook-model-picker.livemd).
  """

  alias ReqLLM.{Context, Response}
  alias ReqLLM.Kino, as: Notebook
  alias ReqLLM.Kino.Request

  @compile {:no_warn_undefined, [Kino.Input, Kino.Text]}

  @doc """
  Creates a text prompt form for a model spec or a model from `ReqLLM.Kino.ModelPicker`.

  Options include `:default_prompt`, `:system_message`, and `:request_options`.
  The last option goes to `ReqLLM.generate_text/3`. Grant access to the provider's
  Livebook secret to use it as the API key. An explicit request key takes precedence.
  """
  @spec new(ReqLLM.model_input(), keyword()) :: ReqLLM.Kino.form()
  def new(model_spec, opts \\ []) do
    Notebook.ensure_kino!()
    opts = Keyword.validate!(opts, default_prompt: "", system_message: "", request_options: [])
    {model, _options} = request = Request.resolve!(model_spec, :chat, opts[:request_options])

    Notebook.new(
      LLMDB.Model.spec(model),
      fields(opts),
      "Run",
      fn data ->
        Request.run(&ReqLLM.generate_text/3, request, messages(data))
      end,
      &render/1
    )
  end

  @doc false
  def fields(opts) do
    [
      prompt: Kino.Input.textarea("Prompt", default: opts[:default_prompt]),
      system: Kino.Input.textarea("System message (optional)", default: opts[:system_message])
    ]
  end

  @doc false
  def messages(%{prompt: prompt, system: system}) when is_binary(system) do
    if String.trim(system) == "" do
      prompt
    else
      [Context.system(system), Context.user(prompt)]
    end
  end

  def messages(%{prompt: prompt}), do: prompt

  defp render(response) do
    text = Response.text(response) || ""
    text = if text == "", do: "The model returned no text.", else: text
    Kino.Text.new(Enum.join([text | Request.measurements(response)], "\n\n"))
  end
end
