defmodule ReqLLM.Output do
  @moduledoc """
  Describes the value expected from text generation.

  Output descriptors are additive request values for `ReqLLM.generate_text/3`
  and `ReqLLM.stream_text/3`. Omitting `:output`, or passing `text/0`, keeps the
  existing text-generation path. Structured descriptors reuse ReqLLM's existing
  object-generation path and preserve the returned `ReqLLM.Response` or
  `ReqLLM.StreamResponse` shape.

  Use `ReqLLM.Response.output/2` to project a buffered response. For streaming,
  materialize once with `ReqLLM.StreamResponse.to_response/1`, then project that
  response so the parsed output remains beside usage and provider metadata. Raw
  generated text and structured tool-call arguments remain available through
  their existing response accessors.

  Streaming responses continue to expose the existing one-consumer stream of
  `ReqLLM.StreamChunk` values. Content and structured tool-call chunks are
  partial transport values and are not claimed to satisfy the final schema.

  ## Examples

      output = ReqLLM.Output.object(
        [name: [type: :string, required: true]],
        name: "person",
        description: "A generated person"
      )

      {:ok, response} = ReqLLM.generate_text(model, "Generate a person", output: output)
      ReqLLM.Response.output(response, output)
      #=> %{"name" => "Ada"}

      output = ReqLLM.Output.array(
        Zoi.object(%{name: Zoi.string()}),
        name: "people"
      )

      output = ReqLLM.Output.choice(["sunny", "rainy", "snowy"])
      output = ReqLLM.Output.json(description: "Any valid JSON value")

  Omitting `:output_validation` retains the current V1 validation and repair
  behavior. `:compatible`, `:warn`, and `:strict` make local final validation
  explicit without changing provider requests. Partial stream values are never
  final-schema validation evidence; streaming policies apply when the stream is
  materialized.

  ## Result and error semantics

  `ReqLLM.Response.output/2` returns text for `text/0`, a map for `object/2`, a
  list for `array/2`, a string for `choice/2`, and any JSON-compatible value for
  `json/1`. It returns `nil` when the existing provider path did not materialize
  a structured value.

  `ReqLLM.Response.output_result/3` exposes the retained raw output, projected
  value, final validity, validation errors, warnings, extraction source, repair
  attempts, and provider metadata separately. It is local and never triggers a
  follow-up model call.

  Constructors raise `ArgumentError` for invalid descriptor metadata options.
  Schema and choice contracts are checked before an HTTP request; generation
  returns `{:error, %ReqLLM.Error.Invalid.Parameter{}}` when a contract cannot be
  compiled. `output_validation: :strict` turns an invalid complete value into a
  validation error. `:warn` returns the response with structured warnings, and
  `:compatible` reports validity while retaining V1 success behavior.

  `:output_repair` accepts a callback returning `{:ok, candidate}` or
  `{:error, reason}`. It runs locally at most once after invalid final output,
  and a candidate replaces the value only after it passes the same final
  validation. Existing light `json_repair` remains enabled by default and is
  reported when detected.
  """

  @type output_type :: :text | :object | :array | :choice | :json
  @type validation_policy :: :compatible | :warn | :strict
  @type repair_callback :: (ReqLLM.Output.Result.t() -> {:ok, term()} | {:error, term()})

  @type runtime_config :: %{
          enabled?: boolean(),
          policy: validation_policy(),
          repair: repair_callback() | nil
        }

  @type t :: %__MODULE__{
          type: output_type(),
          schema: term() | nil,
          element: term() | nil,
          choices: [String.t()] | nil,
          name: String.t() | nil,
          description: String.t() | nil
        }

  @type contract :: %{
          descriptor: t(),
          operation: :chat | :object,
          compiled_schema: map() | nil,
          wrapped?: boolean()
        }

  @enforce_keys [:type]
  defstruct [:type, :schema, :element, :choices, :name, :description]

  @doc "Returns the default plain-text output descriptor."
  @spec text() :: t()
  def text, do: %__MODULE__{type: :text}

  @doc """
  Returns an object output descriptor.

  The schema may be a NimbleOptions-style keyword schema, JSON Schema map, or
  Zoi schema. Optional `:name` and `:description` values provide provider
  guidance where the selected structured-output surface supports it.
  """
  @spec object(term(), keyword()) :: t()
  def object(schema, opts \\ []) do
    build(:object, [schema: schema], opts)
  end

  @doc """
  Returns an array output descriptor.

  `element` is the schema for one array element and accepts the same schema
  forms as `object/2`.
  """
  @spec array(term(), keyword()) :: t()
  def array(element, opts \\ []) do
    build(:array, [element: element], opts)
  end

  @doc "Returns a descriptor requesting one of the provided unique strings."
  @spec choice([String.t()], keyword()) :: t()
  def choice(choices, opts \\ []) do
    build(:choice, [choices: choices], opts)
  end

  @doc "Returns a descriptor for any JSON value without a shape constraint."
  @spec json(keyword()) :: t()
  def json(opts \\ []) do
    build(:json, [], opts)
  end

  @doc false
  @spec normalize(nil | t()) :: {:ok, t()} | {:error, ReqLLM.Error.t()}
  def normalize(nil), do: {:ok, text()}
  def normalize(%__MODULE__{} = output), do: validate_descriptor(output)

  def normalize(output) do
    invalid_output(":output must be a ReqLLM.Output descriptor, got: #{inspect(output)}")
  end

  @doc false
  @spec compile(t()) :: {:ok, contract()} | {:error, ReqLLM.Error.t()}
  def compile(%__MODULE__{type: :text} = descriptor) do
    {:ok,
     %{
       descriptor: descriptor,
       operation: :chat,
       compiled_schema: nil,
       wrapped?: false
     }}
  end

  def compile(%__MODULE__{type: :object, schema: schema} = descriptor) do
    with {:ok, compiled_schema} <- compile_schema(schema),
         {:ok, json_schema} <- schema_to_json(schema),
         :ok <- ensure_object_schema(json_schema) do
      {:ok,
       structured_contract(
         descriptor,
         decorate_schema(json_schema, descriptor),
         compiled_schema.compiled,
         false
       )}
    end
  end

  def compile(%__MODULE__{type: :array, element: element} = descriptor) do
    with {:ok, _compiled_element} <- compile_schema(element),
         {:ok, element_schema} <- schema_to_json(element),
         {:ok, compiled_wrapper} <- compile_array_wrapper(element) do
      value_schema = %{"type" => "array", "items" => element_schema}

      {:ok,
       structured_contract(
         descriptor,
         wrap_value_schema(value_schema, descriptor),
         compiled_wrapper.compiled,
         true
       )}
    end
  end

  def compile(%__MODULE__{type: :choice, choices: choices} = descriptor) do
    with :ok <- validate_choices(choices),
         {:ok, compiled_wrapper} <- compile_choice_wrapper(choices) do
      value_schema = %{"type" => "string", "enum" => choices}

      {:ok,
       structured_contract(
         descriptor,
         wrap_value_schema(value_schema, descriptor),
         compiled_wrapper.compiled,
         true
       )}
    end
  end

  def compile(%__MODULE__{type: :json} = descriptor) do
    {:ok, structured_contract(descriptor, wrap_value_schema(%{}, descriptor), nil, true)}
  end

  def compile(%__MODULE__{type: type}) do
    invalid_output("unsupported ReqLLM.Output type: #{inspect(type)}")
  end

  @doc false
  @spec value(t(), term()) :: term()
  def value(%__MODULE__{type: :text}, response) do
    ReqLLM.Response.text(response)
  end

  def value(%__MODULE__{type: :object}, response) do
    Map.get(response, :object)
  end

  def value(%__MODULE__{type: type}, response) when type in [:array, :choice, :json] do
    response
    |> Map.get(:object)
    |> unwrap_value()
  end

  @doc """
  Computes a complete structured-output result without changing the response.

  The default `:compatible` policy reports final validity without converting an
  invalid V1 response into an error. Pass `policy: :warn` or `policy: :strict`
  to describe the policy used for the projection. Runtime enforcement is
  configured on generation calls with `:output_validation`.
  """
  @spec result(ReqLLM.Response.t(), t(), keyword()) :: ReqLLM.Output.Result.t()
  def result(response, descriptor, opts \\ []) do
    ReqLLM.Output.Validation.result(response, descriptor, opts)
  end

  defp build(type, fields, opts) do
    metadata = validate_metadata!(opts)

    struct!(
      __MODULE__,
      [type: type] ++ fields ++ [name: metadata.name, description: metadata.description]
    )
  end

  defp validate_metadata!(opts) do
    unless Keyword.keyword?(opts) do
      raise ArgumentError, "output descriptor options must be a keyword list"
    end

    unknown = Keyword.keys(opts) -- [:name, :description]

    if unknown != [] do
      raise ArgumentError, "unknown output descriptor options: #{inspect(unknown)}"
    end

    name = Keyword.get(opts, :name)
    description = Keyword.get(opts, :description)

    unless is_nil(name) or is_binary(name) do
      raise ArgumentError, "output descriptor :name must be a string"
    end

    unless is_nil(description) or is_binary(description) do
      raise ArgumentError, "output descriptor :description must be a string"
    end

    %{name: name, description: description}
  end

  defp validate_descriptor(%__MODULE__{type: type} = output)
       when type in [:text, :object, :array, :choice, :json] do
    with :ok <- validate_descriptor_metadata(:name, output.name),
         :ok <- validate_descriptor_metadata(:description, output.description) do
      {:ok, output}
    end
  end

  defp validate_descriptor(%__MODULE__{type: type}) do
    invalid_output("unsupported ReqLLM.Output type: #{inspect(type)}")
  end

  defp validate_descriptor_metadata(_key, nil), do: :ok
  defp validate_descriptor_metadata(_key, value) when is_binary(value), do: :ok

  defp validate_descriptor_metadata(key, value) do
    invalid_output("output descriptor #{inspect(key)} must be a string, got: #{inspect(value)}")
  end

  defp structured_contract(descriptor, schema, compiled, wrapped?) do
    compiled_schema =
      %{schema: schema, compiled: compiled}
      |> maybe_put(:name, descriptor.name)
      |> maybe_put(:description, descriptor.description)

    %{
      descriptor: descriptor,
      operation: :object,
      compiled_schema: compiled_schema,
      wrapped?: wrapped?
    }
  end

  defp schema_to_json(schema) do
    {:ok, ReqLLM.Schema.to_json(schema)}
  rescue
    error ->
      invalid_output("invalid output schema: #{Exception.message(error)}")
  end

  defp compile_schema(schema) do
    case ReqLLM.Schema.compile(schema) do
      {:ok, compiled_schema} -> {:ok, compiled_schema}
      {:error, error} -> invalid_output("invalid output schema: #{Exception.message(error)}")
    end
  end

  defp compile_array_wrapper(element) when is_list(element) do
    compile_schema(value: [type: {:list, {:map, element}}, required: true])
  end

  defp compile_array_wrapper(_element), do: {:ok, %{compiled: nil}}

  defp compile_choice_wrapper(choices) do
    compile_schema(value: [type: {:in, choices}, required: true])
  end

  defp ensure_object_schema(%{"type" => type}) when type not in ["object", nil] do
    invalid_output("object output requires a top-level object schema, got: #{inspect(type)}")
  end

  defp ensure_object_schema(%{type: type}) when type not in [:object, nil] do
    invalid_output("object output requires a top-level object schema, got: #{inspect(type)}")
  end

  defp ensure_object_schema(_schema), do: :ok

  defp validate_choices(choices) when is_list(choices) and choices != [] do
    cond do
      not Enum.all?(choices, &is_binary/1) ->
        invalid_output("choice output options must all be strings")

      Enum.uniq(choices) != choices ->
        invalid_output("choice output options must be unique")

      true ->
        :ok
    end
  end

  defp validate_choices(_choices) do
    invalid_output("choice output requires a non-empty list of strings")
  end

  defp wrap_value_schema(value_schema, descriptor) do
    %{
      "type" => "object",
      "properties" => %{"value" => value_schema},
      "required" => ["value"],
      "additionalProperties" => false
    }
    |> decorate_schema(descriptor)
  end

  defp decorate_schema(schema, %__MODULE__{description: nil}), do: schema

  defp decorate_schema(schema, %__MODULE__{description: description}) do
    Map.put(schema, "description", description)
  end

  defp unwrap_value(%{} = object) do
    case Map.fetch(object, "value") do
      {:ok, value} -> value
      :error -> Map.get(object, :value)
    end
  end

  defp unwrap_value(_object), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp invalid_output(message) do
    {:error, ReqLLM.Error.Invalid.Parameter.exception(parameter: message)}
  end
end
