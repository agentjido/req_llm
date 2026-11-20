defmodule ReqLLM.Kino.ModelPicker do
  @moduledoc """
  Select a model for text or image generation in Livebook.

  Kino is an optional ReqLLM dependency. Install `:kino` and `:req_llm` in the notebook.

  Render `provider_input/0` in one cell. In the next cell, read the input with
  `Kino.Input.read/1`, pass the provider to `new/2`, and render `view/1`. Use `read/1`
  in a later cell to get the model. After you change the provider, run the cell
  that calls `new/2` again.

  See the [Model Picker Livebook](livebook-model-picker.livemd) for a complete example.
  """

  alias ReqLLM.Kino.Form
  alias ReqLLM.Kino.ModelPicker.Source

  @compile {:no_warn_undefined, [Kino.Input, Kino.Layout, Kino.Markdown]}

  @text_providers [lmstudio: "LM Studio", anthropic: "Anthropic", openai: "OpenAI"]
  @image_providers [openai: "OpenAI", google: "Google", xai: "xAI", azure: "Azure OpenAI"]

  defstruct [:provider, :operation, :base_url, :model_input, :manual_input, :view]

  @type provider :: :lmstudio | :anthropic | :openai | :google | :xai | :azure
  @type operation :: :text | :image
  @opaque t :: %__MODULE__{
            provider: provider(),
            operation: operation(),
            base_url: String.t() | nil,
            model_input: struct(),
            manual_input: struct(),
            view: struct()
          }

  @doc "Creates a Kino input for the provider. Pass `operation: :image` for image generation."
  @spec provider_input(keyword()) :: struct()
  def provider_input(opts \\ []) do
    Form.ensure_kino!()
    opts = Keyword.validate!(opts, operation: :text)
    Kino.Input.select("Provider", providers!(opts[:operation]))
  end

  @doc """
  Creates a model picker for the selected provider.

  For LM Studio, this sends a `GET /v1/models` request. Pass `:base_url` to use
  a different LM Studio server. Include `/v1` in the URL. Run this function again
  to update the list. LM Studio can also list embedding models. Choose a model
  that generates text. For Anthropic and OpenAI, choices come from the local
  model catalog. You can also enter a model ID.

  Pass `operation: :image` to show image generation models from the catalog.
  Use the same operation when you call `provider_input/1`.
  """
  @spec new(provider(), keyword()) :: t()
  def new(provider, opts \\ []) do
    Form.ensure_kino!()

    allowed_opts =
      if provider == :lmstudio, do: [:base_url, operation: :text], else: [operation: :text]

    opts = Keyword.validate!(opts, allowed_opts)
    operation = opts[:operation]

    name =
      providers!(operation)[provider] ||
        raise(ArgumentError, "Choose a provider for #{operation} generation.")

    base_url = Source.base_url!(provider, opts)
    {choices, notice} = model_choices(provider, base_url, operation)
    model_input = Kino.Input.select("Model", [{nil, "Select a model"} | choices])
    manual_input = Kino.Input.text("#{name} model ID (optional override)")
    view = Kino.Layout.grid(notice ++ [model_input, manual_input])

    %__MODULE__{
      provider: provider,
      operation: operation,
      base_url: base_url,
      model_input: model_input,
      manual_input: manual_input,
      view: view
    }
  end

  @doc "Returns the Kino layout for the picker. Render it before you call `read/1`."
  @spec view(t()) :: struct()
  def view(%__MODULE__{view: view}), do: view

  @doc """
  Reads the selected model. A manual ID takes precedence over the list selection.

  The model includes the LM Studio base URL when applicable. This function returns
  `{:error, message}` if it cannot use the selection.
  """
  @spec read(t()) :: {:ok, LLMDB.Model.t()} | {:error, String.t()}
  def read(%__MODULE__{} = picker) do
    id =
      case picker.manual_input |> Kino.Input.read() |> String.trim() do
        "" -> Kino.Input.read(picker.model_input)
        manual_id -> manual_id
      end

    Source.model(picker.provider, id, picker.base_url, picker.operation)
  end

  @doc """
  Gets the request options for the selected model.

  Use the provider's API key environment variable name for the Livebook secret.
  If you grant access to that secret, the options include the key. Otherwise,
  ReqLLM uses its usual key lookup. Pass the options directly to ReqLLM. Keep
  them out of notebook output because they can contain a key.
  """
  @spec request_options(LLMDB.Model.t()) :: keyword()
  def request_options(%LLMDB.Model{provider: provider}) do
    Source.request_options(provider)
  end

  defp model_choices(provider, base_url, operation) do
    case Source.choices(provider, base_url, operation) do
      {:ok, choices} -> {choices, []}
      {:error, message} -> {[], [Kino.Markdown.new(message)]}
    end
  end

  defp providers!(:text), do: @text_providers
  defp providers!(:image), do: @image_providers
  defp providers!(_operation), do: raise(ArgumentError, "Use :text or :image for the operation.")
end
