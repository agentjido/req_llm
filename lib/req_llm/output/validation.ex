defmodule ReqLLM.Output.Validation do
  @moduledoc false

  alias ReqLLM.Output
  alias ReqLLM.Output.Result
  alias ReqLLM.Response
  alias ReqLLM.StreamResponse
  alias ReqLLM.StreamResponse.MetadataHandle

  @stream_config_key :req_llm_output_config
  @diagnostic_key :req_llm_output

  @spec result(Response.t(), Output.t(), keyword()) :: Result.t()
  def result(response, descriptor, opts \\ []) do
    policy = Keyword.get(opts, :policy, diagnostic_policy(response, descriptor))

    with {:ok, normalized} <- Output.normalize(descriptor),
         {:ok, contract} <- Output.compile(normalized),
         :ok <- validate_policy(policy) do
      response
      |> evaluate(contract, policy)
      |> merge_attached_diagnostic(response, contract)
    else
      {:error, error} -> raise error
    end
  end

  @spec take_runtime_options(keyword()) ::
          {:ok, Output.runtime_config(), keyword()} | {:error, ReqLLM.Error.t()}
  def take_runtime_options(opts) do
    policy_supplied? = Keyword.has_key?(opts, :output_validation)
    repair_supplied? = Keyword.has_key?(opts, :output_repair)
    {policy, opts} = Keyword.pop(opts, :output_validation, :compatible)
    {repair, opts} = Keyword.pop(opts, :output_repair)

    with :ok <- validate_policy(policy),
         :ok <- validate_repair(repair) do
      {:ok,
       %{
         enabled?: policy_supplied? or repair_supplied?,
         policy: policy,
         repair: repair
       }, opts}
    end
  end

  @spec validation_contract(Output.t(), map()) :: Output.contract()
  def validation_contract(%Output{} = descriptor, compiled_schema) do
    schema =
      case compiled_schema do
        %{schema: schema} -> ReqLLM.Schema.to_json(schema)
        _other -> nil
      end

    %{
      descriptor: descriptor,
      operation: if(descriptor.type == :text, do: :chat, else: :object),
      compiled_schema:
        if(is_nil(schema), do: nil, else: Map.put(compiled_schema, :schema, schema)),
      wrapped?: descriptor.type in [:array, :choice, :json]
    }
  end

  @spec finalize_result(
          {:ok, Response.t()} | {:error, term()},
          Output.contract(),
          Output.runtime_config()
        ) :: {:ok, Response.t()} | {:error, term()}
  def finalize_result(result, _contract, %{enabled?: false}), do: result

  def finalize_result({:ok, response}, contract, config) do
    finalize_response(response, contract, config)
  end

  def finalize_result({:error, _error} = error, _contract, _config), do: error

  @spec validate_runtime_config(Output.contract(), Output.runtime_config()) ::
          :ok | {:error, ReqLLM.Error.t()}
  def validate_runtime_config(%{descriptor: %{type: :text}}, %{repair: repair})
      when not is_nil(repair) do
    invalid_output(":output_repair is available only for structured output descriptors")
  end

  def validate_runtime_config(_contract, _config), do: :ok

  @spec attach_stream_result(
          {:ok, StreamResponse.t()} | {:error, term()},
          Output.contract(),
          Output.runtime_config()
        ) :: {:ok, StreamResponse.t()} | {:error, term()}
  def attach_stream_result(result, _contract, %{enabled?: false}), do: result

  def attach_stream_result({:ok, stream_response}, contract, config) do
    original_handle = stream_response.metadata_handle

    fetch_metadata = fn ->
      metadata = await_original_metadata(original_handle)
      Map.put(metadata, @stream_config_key, {contract, config})
    end

    case MetadataHandle.start_link(fetch_metadata) do
      {:ok, metadata_handle} ->
        cancel = fn ->
          try do
            stream_response.cancel.()
          after
            MetadataHandle.stop(metadata_handle)
          end
        end

        {:ok,
         %{
           stream_response
           | metadata_handle: metadata_handle,
             cancel: cancel
         }}

      {:error, reason} ->
        StreamResponse.close(stream_response)
        {:error, reason}
    end
  end

  def attach_stream_result({:error, _error} = error, _contract, _config), do: error

  @spec pop_stream_config(map()) ::
          {nil | {Output.contract(), Output.runtime_config()}, map()}
  def pop_stream_config(metadata) when is_map(metadata) do
    Map.pop(metadata, @stream_config_key)
  end

  @spec finalize_stream_response(
          {:ok, Response.t()} | {:error, term()},
          nil | {Output.contract(), Output.runtime_config()}
        ) :: {:ok, Response.t()} | {:error, term()}
  def finalize_stream_response(result, nil), do: result

  def finalize_stream_response(result, {contract, config}) do
    finalize_result(result, contract, config)
  end

  defp finalize_response(response, contract, config) do
    initial_result = evaluate(response, contract, config.policy)
    {response, result} = maybe_repair(response, contract, config, initial_result)
    response = attach_diagnostic(response, contract, result, config.policy)

    if config.policy == :strict and not result.valid? do
      {:error, strict_validation_error(result)}
    else
      {:ok, response}
    end
  end

  defp maybe_repair(response, _contract, %{repair: nil}, result), do: {response, result}

  defp maybe_repair(response, _contract, _config, %{valid?: true} = result),
    do: {response, result}

  defp maybe_repair(response, contract, %{repair: repair, policy: policy}, result) do
    case invoke_repair(repair, result) do
      {:ok, candidate} ->
        candidate_response = put_candidate(response, contract, candidate)
        candidate_result = evaluate(candidate_response, contract, policy)

        if candidate_result.valid? do
          repair_entry = %{type: :callback, status: :applied}
          warnings = Enum.uniq(result.warnings ++ ["Local output repair callback applied once."])

          {candidate_response,
           %{
             candidate_result
             | raw: result.raw,
               source: result.source,
               repairs: result.repairs ++ [repair_entry],
               warnings: warnings
           }}
        else
          failed_callback_result(response, result, validation_summary(candidate_result.errors))
        end

      {:error, reason} ->
        failed_callback_result(response, result, format_reason(reason))

      other ->
        failed_callback_result(response, result, invalid_callback_return(other))
    end
  end

  defp invoke_repair(repair, result) do
    repair.(result)
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp failed_callback_result(response, result, reason) do
    repair_entry = %{type: :callback, status: :failed, reason: reason}
    warning = "Local output repair callback failed: #{reason}"

    {response,
     %{
       result
       | repairs: result.repairs ++ [repair_entry],
         warnings: Enum.uniq(result.warnings ++ [warning])
     }}
  end

  defp put_candidate(response, %{descriptor: %{type: :object}}, candidate) do
    %{response | object: candidate}
  end

  defp put_candidate(response, %{wrapped?: true}, candidate) do
    %{response | object: %{"value" => candidate}}
  end

  defp evaluate(response, contract, policy) do
    descriptor = contract.descriptor
    value = Output.value(descriptor, response)
    %{raw: raw, source: source} = raw_value(response, descriptor)
    repairs = detect_legacy_repairs(raw, response.object)
    errors = validation_errors(response, contract, value)
    warnings = evaluation_warnings(descriptor, source, repairs, errors, policy)

    %Result{
      value: value,
      raw: raw,
      valid?: errors == [],
      errors: errors,
      warnings: warnings,
      repairs: repairs,
      source: source,
      policy: policy,
      provider_metadata: Map.delete(response.provider_meta, @diagnostic_key)
    }
  end

  defp raw_value(response, %Output{type: :text}) do
    case Response.text(response) do
      nil -> %{raw: nil, source: :missing}
      text -> %{raw: text, source: :text}
    end
  end

  defp raw_value(response, _descriptor) do
    case structured_tool_call(response) do
      %ReqLLM.ToolCall{} = tool_call ->
        %{raw: ReqLLM.ToolCall.args_json(tool_call), source: :tool_call}

      nil ->
        raw_structured_value(response)
    end
  end

  defp raw_structured_value(response) do
    case Response.text(response) do
      text when is_binary(text) and text != "" -> %{raw: text, source: :text}
      _other when not is_nil(response.object) -> %{raw: response.object, source: :response_object}
      _other -> %{raw: nil, source: :missing}
    end
  end

  defp structured_tool_call(response) do
    Enum.find(
      Response.tool_calls(response),
      &ReqLLM.ToolCall.matches_name?(&1, "structured_output")
    )
  end

  defp detect_legacy_repairs(raw, object) when is_binary(raw) do
    case {ReqLLM.JSON.decode(raw, json_repair: false), ReqLLM.JSON.decode(raw)} do
      {{:error, _error}, {:ok, repaired}} when not is_nil(object) and repaired == object ->
        [%{type: :json_repair, status: :applied}]

      {{:error, _error}, {:ok, repaired}} when not is_nil(object) ->
        [
          %{type: :json_repair, status: :applied},
          %{type: :legacy_type_coercion, status: :applied, reason: coercion_reason(repaired)}
        ]

      {{:ok, parsed}, _repaired} when parsed != object and not is_nil(object) ->
        [%{type: :legacy_type_coercion, status: :applied}]

      _other ->
        []
    end
  end

  defp detect_legacy_repairs(_raw, _object), do: []

  defp coercion_reason(_value), do: "parsed value changed during legacy materialization"

  defp validation_errors(_response, %{descriptor: %{type: :text}}, value)
       when is_binary(value),
       do: []

  defp validation_errors(_response, %{descriptor: %{type: :text}}, _value) do
    [%{type: :invalid_type, message: "Final text output is not a string."}]
  end

  defp validation_errors(%{object: nil}, _contract, _value) do
    [%{type: :missing_value, message: "No complete structured output value was materialized."}]
  end

  defp validation_errors(response, %{compiled_schema: %{schema: schema}}, _value) do
    validate_schema(response.object, schema)
  end

  defp validation_errors(_response, _contract, _value), do: []

  defp validate_schema(value, schema) do
    case ReqLLM.Schema.validate(value, schema) do
      {:ok, _validated} -> []
      {:error, error} -> [%{type: :schema_validation, message: Exception.message(error)}]
    end
  rescue
    error -> [%{type: :schema_validation, message: Exception.message(error)}]
  end

  defp evaluation_warnings(descriptor, source, repairs, errors, policy) do
    extraction_warnings(descriptor, source) ++
      repair_warnings(repairs) ++ policy_warnings(errors, policy)
  end

  defp extraction_warnings(%{type: :text}, _source), do: []

  defp extraction_warnings(_descriptor, :text),
    do: ["Structured output was extracted from retained response text."]

  defp extraction_warnings(_descriptor, :tool_call),
    do: ["Structured output was extracted from retained tool-call arguments."]

  defp extraction_warnings(_descriptor, _source), do: []

  defp repair_warnings(repairs) do
    Enum.map(repairs, fn
      %{type: :json_repair} ->
        "Legacy light JSON repair was applied."

      %{type: :legacy_type_coercion} ->
        "Legacy structured-output type coercion was applied."

      %{type: :callback, status: :applied} ->
        "Local output repair callback applied once."

      %{type: :callback, status: :failed, reason: reason} ->
        "Local output repair callback failed: #{reason}"
    end)
  end

  defp policy_warnings([], _policy), do: []

  defp policy_warnings(errors, :warn) do
    ["Structured output failed final validation: #{validation_summary(errors)}"]
  end

  defp policy_warnings(_errors, _policy), do: []

  defp attach_diagnostic(response, contract, result, policy) do
    diagnostic = %{
      contract: contract_fingerprint(contract),
      policy: policy,
      valid?: result.valid?,
      errors: result.errors,
      warnings: result.warnings,
      repairs: result.repairs,
      source: result.source
    }

    provider_meta = Map.put(response.provider_meta, @diagnostic_key, diagnostic)
    provider_meta = maybe_attach_warnings(provider_meta, result, policy)

    %{response | provider_meta: provider_meta}
  end

  defp merge_attached_diagnostic(result, response, contract) do
    fingerprint = contract_fingerprint(contract)

    case Map.get(response.provider_meta, @diagnostic_key) do
      %{contract: ^fingerprint} = diagnostic ->
        %{
          result
          | valid?: diagnostic.valid?,
            errors: diagnostic.errors,
            warnings: diagnostic.warnings,
            repairs: diagnostic.repairs,
            source: diagnostic.source,
            policy: diagnostic.policy
        }

      _other ->
        result
    end
  end

  defp diagnostic_policy(response, descriptor) do
    with {:ok, contract} <- Output.compile(descriptor),
         %{contract: fingerprint, policy: policy} <-
           Map.get(response.provider_meta, @diagnostic_key),
         true <- fingerprint == contract_fingerprint(contract) do
      policy
    else
      _other -> :compatible
    end
  end

  defp contract_fingerprint(contract) do
    schema = get_in(contract, [:compiled_schema, :schema])
    :erlang.phash2({contract.descriptor.type, schema, contract.wrapped?})
  end

  defp maybe_attach_warnings(provider_meta, %{warnings: warnings}, :warn)
       when warnings != [] do
    existing =
      case Map.get(provider_meta, :warnings) do
        values when is_list(values) -> values
        value when is_binary(value) -> [value]
        _other -> []
      end

    Map.put(provider_meta, :warnings, Enum.uniq(existing ++ warnings))
  end

  defp maybe_attach_warnings(provider_meta, _result, _policy), do: provider_meta

  defp strict_validation_error(result) do
    ReqLLM.Error.Validation.Error.exception(
      tag: :structured_output_validation_failed,
      reason: "Structured output failed final validation: #{validation_summary(result.errors)}",
      context: [output_result: result]
    )
  end

  defp validation_summary(errors) do
    Enum.map_join(errors, "; ", & &1.message)
  end

  defp format_reason(reason) when is_exception(reason), do: Exception.message(reason)
  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason) when is_atom(reason) or is_number(reason), do: inspect(reason)
  defp format_reason(_reason), do: "callback returned an error"

  defp invalid_callback_return(_value) do
    "expected {:ok, value} or {:error, reason}"
  end

  defp validate_policy(policy) when policy in [:compatible, :warn, :strict], do: :ok

  defp validate_policy(policy) do
    invalid_output(
      ":output_validation must be :compatible, :warn, or :strict, got: #{inspect(policy)}"
    )
  end

  defp validate_repair(nil), do: :ok
  defp validate_repair(repair) when is_function(repair, 1), do: :ok

  defp validate_repair(repair) do
    invalid_output(":output_repair must be a one-argument function, got: #{inspect(repair)}")
  end

  defp await_original_metadata(original_handle) do
    MetadataHandle.await(original_handle)
  catch
    :exit, _reason -> %{}
  after
    MetadataHandle.stop(original_handle)
  end

  defp invalid_output(message) do
    {:error, ReqLLM.Error.Invalid.Parameter.exception(parameter: message)}
  end
end
