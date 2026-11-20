defmodule ReqLLM.Kino.ModelPicker.Source do
  @moduledoc false

  alias LLMDB.Model
  alias ReqLLM.Keys
  alias ReqLLM.Provider.Options
  alias ReqLLM.Providers.LMStudio

  def base_url!(:lmstudio, opts) do
    default_model = %Model{provider: :lmstudio, id: ""}
    base_url = Options.effective_base_url(LMStudio, default_model, opts)

    with base_url when is_binary(base_url) <- base_url,
         base_url = String.trim_trailing(base_url, "/"),
         {:ok,
          %URI{scheme: scheme, host: host, path: path, userinfo: nil, query: nil, fragment: nil}} <-
           URI.new(base_url),
         true <- scheme in ["http", "https"] and host not in [nil, ""],
         true <- is_binary(path) and String.ends_with?(path, "/v1") do
      base_url
    else
      _ -> raise ArgumentError, "Use an HTTP or HTTPS base URL that ends in /v1 for LM Studio."
    end
  end

  def base_url!(_provider, _opts), do: nil

  def choices(provider, base_url, operation \\ :text)

  def choices(:lmstudio, base_url, :text) do
    auth =
      case Keys.get(:lmstudio, request_options(:lmstudio)) do
        {:ok, key, _source} -> {:bearer, key}
        {:error, _reason} -> nil
      end

    Req.get(
      url: base_url <> "/models",
      auth: auth,
      retry: false,
      redirect: false,
      connect_options: [timeout: 2_000],
      receive_timeout: 3_000
    )
    |> parse_local_models()
  end

  def choices(provider, nil, operation) do
    choices =
      provider
      |> LLMDB.models()
      |> Enum.filter(&listed_model?(&1, operation))
      |> Enum.map(&{&1.id, &1.id})
      |> Enum.sort()

    case choices do
      [] ->
        {:error, "The catalog has no #{operation} models for this provider. Enter a model ID."}

      choices ->
        {:ok, choices}
    end
  end

  def model(provider, id, base_url, operation \\ :text)

  def model(_provider, nil, _url, _operation), do: {:error, "Select a model or enter a model ID."}

  def model(:lmstudio, id, base_url, :text) do
    ReqLLM.model(%{provider: :lmstudio, id: id, base_url: base_url})
    |> model_result(:text)
  end

  def model(provider, id, nil, operation) do
    result =
      case LLMDB.model(provider, id) do
        {:ok, model} -> {:ok, model}
        {:error, _reason} -> ReqLLM.model(%{provider: provider, id: id})
      end

    model_result(result, operation)
  end

  def request_options(provider) do
    case ReqLLM.Provider.Utils.present_env("LB_" <> Keys.env_var_name(provider)) do
      nil -> []
      key -> [api_key: key]
    end
  end

  defp parse_local_models({:ok, %Req.Response{status: 200, body: %{"data" => models}}})
       when is_list(models) do
    ids = for %{"id" => id} <- models, is_binary(id), byte_size(id) > 0, do: id

    case ids do
      [] -> {:error, "LM Studio returned no models. Download a text model or enter its ID."}
      ids -> {:ok, ids |> Enum.uniq() |> Enum.sort() |> Enum.map(&{&1, &1})}
    end
  end

  defp parse_local_models({:ok, %Req.Response{status: 200}}) do
    {:error,
     "LM Studio returned an invalid model list. Check the server URL or enter a model ID."}
  end

  defp parse_local_models({:ok, %Req.Response{status: status}}) when status in [401, 403] do
    {:error, "LM Studio rejected the request. Check the LMSTUDIO_API_KEY secret."}
  end

  defp parse_local_models({:ok, %Req.Response{status: status}}) do
    {:error, "LM Studio returned HTTP #{status}. Check the server URL or enter a model ID."}
  end

  defp parse_local_models({:error, _reason}) do
    {:error, "Could not get the LM Studio model list. Check the server or enter a model ID."}
  end

  defp model_result({:ok, model}, operation) do
    if supports_operation?(model, operation) do
      {:ok, model}
    else
      {:error, "Choose a model that supports #{operation} generation."}
    end
  end

  defp model_result({:error, _reason}, _operation), do: {:error, "Check the model ID."}

  defp listed_model?(%Model{capabilities: %{chat: true}} = model, :text) do
    Model.effective_status(model) == "active" and supports_operation?(model, :text)
  end

  defp listed_model?(%Model{} = model, :image) do
    Model.effective_status(model) == "active" and supports_operation?(model, :image)
  end

  defp listed_model?(%Model{}, :text), do: false

  defp supports_operation?(%Model{catalog_only: true}, _operation), do: false
  defp supports_operation?(%Model{execution: %{image: _}}, :image), do: true

  defp supports_operation?(%Model{modalities: %{output: output}}, :image) when is_list(output),
    do: :image in output

  defp supports_operation?(%Model{} = model, :image),
    do: match?({:ok, _}, ReqLLM.Images.validate_model(model))

  defp supports_operation?(%Model{capabilities: %{chat: false}}, :text), do: false

  defp supports_operation?(%Model{execution: execution}, :text)
       when is_map(execution) and not is_map_key(execution, :text),
       do: false

  defp supports_operation?(%Model{modalities: %{input: input, output: output}}, :text)
       when is_list(input) and is_list(output) do
    :text in input and :text in output
  end

  defp supports_operation?(%Model{}, :text), do: true
end
