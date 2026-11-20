defmodule ReqLLM.Providers.CloudflareWorkersAI.Clairic do
  @moduledoc """
  Experimental text and number extraction through Cloudflare Workers AI.

  Clairic takes source text and named field specifications. The returned
  `ReqLLM.Response.object` contains the field answers, including any spans,
  confidence, null probability, and completion flags reported by Cloudflare.
  The full Workers AI response is available in `provider_meta.raw_response`.
  Inspect each field's `valid` and `complete` flags when present. A null value
  can represent an absent field or a failed extraction.

  ## Example

      alias ReqLLM.Providers.CloudflareWorkersAI.Clairic

      {:ok, response} =
        Clairic.extract(
          "clairic-flash",
          "Invoice INV-7. Total due: $0.00.",
          %{
            invoice_id: %{type: "text", instructions: "Invoice identifier"},
            total: %{type: "number", decimals: 2},
            po_number: %{type: "text", instructions: "Purchase order number"}
          },
          account_id: System.fetch_env!("CLOUDFLARE_ACCOUNT_ID"),
          api_key: System.fetch_env!("CLOUDFLARE_API_TOKEN")
        )

      response.object["invoice_id"]["span"]
  """

  alias ReqLLM.Error.API.Response, as: ResponseError
  alias ReqLLM.Error.Invalid.Parameter
  alias ReqLLM.Provider.Defaults
  alias ReqLLM.Response
  alias ReqLLM.Step
  alias ReqLLM.TimeoutBudget

  @base_url "https://api.cloudflare.com/client/v4"
  @models ["clairic", "clairic-flash"]
  @account_id_pattern ~r/\A[0-9a-fA-F]{32}\z/
  @request_options Zoi.keyword(
                     [
                       account_id: Zoi.string(),
                       api_key: Zoi.string(),
                       base_url: Zoi.string(),
                       receive_timeout: Zoi.integer() |> Zoi.positive(),
                       total_timeout:
                         Zoi.union([Zoi.integer() |> Zoi.positive(), Zoi.literal(:infinity)]),
                       max_retries: Zoi.integer() |> Zoi.min(0),
                       req_http_options: Zoi.array(Zoi.tuple({Zoi.atom(), Zoi.any()}))
                     ],
                     unrecognized_keys: :error
                   )

  @doc """
  Extracts named text and number fields in one Workers AI call.

  Use `"clairic"` or `"clairic-flash"`. Pass `:account_id` and a Workers AI
  API token as `:api_key`, or let `ReqLLM.Keys` resolve the token for
  `:cloudflare_workers_ai`. The HTTP controls are `:base_url`,
  `:receive_timeout`, `:total_timeout`, `:max_retries`, and
  `:req_http_options`.
  """
  @spec extract(String.t(), String.t(), map(), keyword()) ::
          {:ok, Response.t()} | {:error, Exception.t()}
  def extract(model, state, fields, opts \\ []) do
    with :ok <- validate_input(model, state),
         {:ok, fields} <- normalize_fields(fields),
         {:ok, opts} <- validate_options(opts),
         {:ok, url} <- extraction_url(model, opts),
         {:ok, api_key} <- api_key(opts),
         {:ok, body} <- encode_request(model, state, fields),
         request = prepare_request(model, fields, url, api_key, body, opts),
         {:ok, %Req.Response{} = response} <-
           TimeoutBudget.request(request, TimeoutBudget.deadline(opts)) do
      case response.body do
        %Response{} = result -> {:ok, result}
        _ -> {:error, response_error(response)}
      end
    end
  end

  defp validate_input(model, state) when model in @models and is_binary(state) do
    if String.valid?(state) and String.trim(state) != "",
      do: :ok,
      else: invalid("Clairic state must be non-empty UTF-8 text")
  end

  defp validate_input(_model, _state),
    do: invalid("Clairic requires a supported model and a text state")

  defp normalize_fields(fields)
       when is_map(fields) and not is_struct(fields) and map_size(fields) > 0 do
    Enum.reduce_while(fields, {:ok, %{}}, fn {name, spec}, {:ok, normalized} ->
      case normalize_field(name, spec, normalized) do
        {:ok, normalized} -> {:cont, {:ok, normalized}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp normalize_fields(_fields), do: invalid("Clairic requires a non-empty field map")

  defp normalize_field(name, spec, fields)
       when (is_atom(name) or is_binary(name)) and is_map(spec) and not is_struct(spec) do
    key = to_string(name)
    type = Map.get(spec, "type", Map.get(spec, :type))

    cond do
      not String.valid?(key) or String.trim(key) == "" or is_nil(name) ->
        invalid("Clairic field names must be non-empty UTF-8 strings")

      Map.has_key?(fields, key) ->
        invalid("Clairic field names must be unique after string normalization")

      type in [:text, "text", :number, "number"] ->
        spec = spec |> Map.delete(:type) |> Map.put("type", to_string(type))
        {:ok, Map.put(fields, key, spec)}

      true ->
        invalid("Clairic fields must have type text or number")
    end
  end

  defp normalize_field(_name, _spec, _fields),
    do: invalid("Clairic fields must map names to field maps")

  defp validate_options(opts) do
    if Keyword.keyword?(opts) and length(opts) == length(Enum.uniq_by(opts, &elem(&1, 0))) do
      case Zoi.parse(@request_options, opts) do
        {:ok, opts} -> {:ok, opts}
        {:error, _errors} -> invalid("Invalid Clairic options")
      end
    else
      invalid("Clairic options must be a keyword list with unique keys")
    end
  end

  defp extraction_url(model, opts) do
    account_id = opts[:account_id]
    base_url = Keyword.get(opts, :base_url, @base_url)

    with true <- is_binary(account_id) and Regex.match?(@account_id_pattern, account_id),
         {:ok, %URI{scheme: scheme, host: host, userinfo: nil, query: nil, fragment: nil}}
         when scheme in ["http", "https"] and is_binary(host) and host != "" <- URI.new(base_url) do
      {:ok,
       String.trim_trailing(base_url, "/") <>
         "/accounts/#{account_id}/ai/run/@cf/cloudflare/#{model}"}
    else
      false -> invalid("Clairic requires a 32-character hexadecimal account ID")
      _ -> invalid("Clairic requires an HTTP or HTTPS base URL")
    end
  end

  defp api_key(opts) do
    case ReqLLM.Keys.get(:cloudflare_workers_ai, opts) do
      {:ok, key, _source} -> {:ok, key}
      {:error, message} -> invalid(message)
    end
  end

  defp encode_request(model, state, fields) do
    case Jason.encode(%{model: model, state: state, fields: fields}) do
      {:ok, body} -> {:ok, body}
      {:error, _reason} -> invalid("Clairic fields must contain JSON data")
    end
  end

  defp prepare_request(model, fields, url, api_key, body, opts) do
    timeout = Keyword.get(opts, :receive_timeout, 30_000)

    http_options =
      Defaults.merge_finch_options(Keyword.get(opts, :req_http_options, []),
        pool_timeout: timeout
      )

    telemetry_model = %LLMDB.Model{id: model, provider: :cloudflare_workers_ai}

    http_options
    |> Keyword.merge(method: :post, url: url, body: body, receive_timeout: timeout)
    |> Req.new()
    |> Req.Request.put_header("content-type", "application/json")
    |> Req.Request.put_header("authorization", "Bearer " <> api_key)
    |> Step.Retry.attach(opts)
    |> Step.Error.attach()
    |> Req.Request.append_response_steps(clairic_decode: &decode_response(&1, fields))
    |> Step.Telemetry.attach(telemetry_model, opts, operation: :extract)
  end

  defp decode_response({request, %Req.Response{status: status, body: body} = response}, fields)
       when status in 200..299 do
    body = ReqLLM.Provider.Utils.ensure_parsed_body(body)

    case decode_result(body, fields) do
      {:ok, result} -> {request, %{response | body: result}}
      :error -> {request, response_error(%{response | body: body})}
    end
  end

  defp decode_response({request, response}, _fields), do: {request, response_error(response)}

  defp decode_result(
         %{"result" => %{"model" => model, "answers" => answers, "usage" => usage}} = body,
         fields
       )
       when is_binary(model) and is_map(answers) and is_map(usage) do
    if Map.get(body, "success", true) == true and Enum.all?(fields, &valid_answer?(&1, answers)) do
      {:ok,
       %Response{
         id: "extract-#{System.unique_integer([:positive])}",
         model: model,
         context: ReqLLM.Context.new(),
         object: answers,
         usage: ReqLLM.Usage.normalize(usage),
         provider_meta: %{
           operation: :extract,
           provider: :cloudflare_workers_ai,
           raw_response: body
         }
       }}
    else
      :error
    end
  end

  defp decode_result(_body, _fields), do: :error

  defp valid_answer?({field, %{"type" => type}}, answers) do
    case Map.get(answers, field) do
      %{"type" => ^type, "value" => nil} -> true
      %{"type" => "text", "value" => value} -> type == "text" and is_binary(value)
      %{"type" => "number", "value" => value} -> type == "number" and is_number(value)
      _ -> false
    end
  end

  defp response_error(response) do
    ResponseError.exception(
      reason: "Invalid or unsuccessful Clairic extraction response",
      status: response.status,
      response_body: response.body
    )
  end

  defp invalid(reason), do: {:error, Parameter.exception(parameter: reason)}
end
