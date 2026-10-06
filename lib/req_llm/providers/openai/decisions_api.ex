defmodule ReqLLM.Providers.OpenAI.DecisionsAPI do
  @moduledoc """
  OpenAI Decisions endpoint driver.

  The driver compiles provider-neutral evaluation input before transport and
  validates ordered Decisions answers after transport.
  """

  @behaviour ReqLLM.Providers.OpenAI.API

  import ReqLLM.Provider.Utils, only: [ensure_parsed_body: 1]

  alias ReqLLM.Error.API.Response, as: APIResponseError
  alias ReqLLM.Error.Invalid.Parameter, as: InvalidParameter

  @request_private_key :req_llm_openai_decisions

  @impl true
  def path, do: "/decisions"

  @doc false
  @spec compile_request(String.t(), String.t() | map() | list(), map(), String.t() | nil) ::
          {:ok, map(), [map()]} | {:error, Exception.t()}
  def compile_request(model, state, questions, safety_identifier) do
    with :ok <- validate_model(model),
         {:ok, input} <- compile_state(state),
         {:ok, compiled_questions, contract} <- compile_questions(questions),
         :ok <- validate_safety_identifier(safety_identifier) do
      body = %{
        "model" => model,
        "input" => input,
        "questions" => compiled_questions
      }

      body =
        if is_nil(safety_identifier) do
          body
        else
          Map.put(body, "safety_identifier", safety_identifier)
        end

      {:ok, body, contract}
    end
  end

  @impl true
  def encode_body(request) do
    Map.put(request, :body, Jason.encode!(request.options[:decisions_body]))
  end

  @impl true
  def decode_response({request, %Req.Response{status: status} = response})
      when status in 200..299 do
    body = ensure_parsed_body(response.body)
    contract = request.private[@request_private_key]

    case decode_success(body, request.options[:model], contract) do
      {:ok, result} ->
        {request, %{response | body: result}}

      {:error, reason} ->
        {request,
         APIResponseError.exception(
           reason: "Invalid OpenAI Decisions response: #{reason}",
           status: status,
           response_body: body
         )}
    end
  rescue
    error ->
      {request,
       APIResponseError.exception(
         reason: "Invalid OpenAI Decisions response: #{Exception.message(error)}",
         status: response.status,
         response_body: response.body
       )}
  end

  def decode_response({request, %Req.Response{status: status} = response}) do
    {request,
     APIResponseError.exception(
       reason: "OpenAI Decisions request failed",
       status: status,
       response_body: ensure_parsed_body(response.body)
     )}
  end

  @impl true
  def decode_stream_event(_event, _model), do: []

  @impl true
  def attach_stream(_model, _context, _opts, _finch_name) do
    {:error,
     InvalidParameter.exception(
       parameter: "streaming is not supported by OpenAI Decisions; use evaluate/4"
     )}
  end

  @doc false
  def request_private_key, do: @request_private_key

  defp validate_model(model) when is_binary(model), do: :ok
  defp validate_model(_model), do: invalid("OpenAI Decisions model must be a string")

  defp compile_state(state) when is_binary(state), do: {:ok, state}

  defp compile_state(state) when is_map(state) or is_list(state) do
    with {:ok, ordered} <- canonical_json_value(state, "state") do
      {:ok, Jason.encode!(ordered)}
    end
  end

  defp compile_state(_state), do: invalid("OpenAI Decisions state must be text or JSON data")

  defp canonical_json_value(value, path) when is_map(value) do
    value
    |> Enum.reduce_while({:ok, %{}}, fn {key, nested}, {:ok, fields} ->
      with {:ok, normalized_key} <- normalize_json_key(key, path),
           false <- Map.has_key?(fields, normalized_key),
           {:ok, normalized_value} <-
             canonical_json_value(nested, "#{path}.#{normalized_key}") do
        {:cont, {:ok, Map.put(fields, normalized_key, normalized_value)}}
      else
        true -> {:halt, invalid("#{path} object key collision after normalization")}
        {:error, _error} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, fields} ->
        ordered = fields |> Enum.sort_by(&elem(&1, 0)) |> Jason.OrderedObject.new()
        {:ok, ordered}

      error ->
        error
    end
  end

  defp canonical_json_value(value, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {nested, index}, {:ok, items} ->
      case canonical_json_value(nested, "#{path}[#{index}]") do
        {:ok, normalized} -> {:cont, {:ok, [normalized | items]}}
        {:error, _error} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  defp canonical_json_value(value, _path)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: {:ok, value}

  defp canonical_json_value(_value, path), do: invalid("#{path} is not JSON data")

  defp normalize_json_key(key, _path) when is_binary(key), do: {:ok, key}
  defp normalize_json_key(key, _path) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp normalize_json_key(_key, path), do: invalid("#{path} object keys must be strings or atoms")

  defp compile_questions(questions) when is_map(questions) and map_size(questions) > 0 do
    questions
    |> Enum.reduce_while({:ok, %{}}, fn {name, question}, {:ok, compiled} ->
      with {:ok, normalized_name} <- normalize_name(name),
           false <- Map.has_key?(compiled, normalized_name),
           {:ok, provider_question, expected} <-
             compile_question(normalized_name, question) do
        value = %{provider_question: provider_question, expected: expected}
        {:cont, {:ok, Map.put(compiled, normalized_name, value)}}
      else
        true -> {:halt, invalid("OpenAI Decisions question name collision after normalization")}
        {:error, _error} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, compiled} ->
        sorted = compiled |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))
        {:ok, Enum.map(sorted, & &1.provider_question), Enum.map(sorted, & &1.expected)}

      error ->
        error
    end
  end

  defp compile_questions(_questions) do
    invalid("OpenAI Decisions questions must be a non-empty map")
  end

  defp normalize_name(name) when is_binary(name), do: {:ok, name}
  defp normalize_name(name) when is_atom(name), do: {:ok, Atom.to_string(name)}

  defp normalize_name(_name),
    do: invalid("OpenAI Decisions question names must be strings or atoms")

  defp compile_question(name, question) when is_map(question) do
    type = field(question, :type)
    instructions = field(question, :instructions)

    if is_binary(instructions) do
      compile_question_type(name, type, instructions, question)
    else
      invalid("OpenAI Decisions question #{inspect(name)} must have string instructions")
    end
  end

  defp compile_question(name, _question) do
    invalid("OpenAI Decisions question #{inspect(name)} must be a map")
  end

  defp compile_question_type(name, type, instructions, _question)
       when type in [:boolean, "boolean"] do
    provider = %{"name" => name, "type" => "predicate", "instructions" => instructions}
    {:ok, provider, %{name: name, type: "predicate"}}
  end

  defp compile_question_type(name, type, instructions, question)
       when type in [:choice, "choice"] do
    with {:ok, choices, values} <- compile_choices(field(question, :criteria), name) do
      provider = %{
        "name" => name,
        "type" => "choice",
        "instructions" => instructions,
        "choices" => choices
      }

      {:ok, provider, %{name: name, type: "choice", allowed_values: values}}
    end
  end

  defp compile_question_type(name, type, instructions, question)
       when type in [:score, "score"] do
    with {:ok, levels, labels} <- compile_levels(field(question, :criteria), name) do
      provider = %{
        "name" => name,
        "type" => "score",
        "instructions" => instructions,
        "levels" => levels
      }

      {:ok, provider, %{name: name, type: "score", labels: labels}}
    end
  end

  defp compile_question_type(name, _type, _instructions, _question) do
    invalid("OpenAI Decisions question #{inspect(name)} has an unsupported type")
  end

  defp compile_choices(criteria, name) when is_map(criteria) and map_size(criteria) > 0 do
    criteria
    |> Enum.reduce_while({:ok, %{}}, fn {value, description}, {:ok, choices} ->
      with {:ok, normalized_value} <- normalize_choice_value(value, name),
           true <- is_binary(description),
           false <- Map.has_key?(choices, normalized_value) do
        choice = %{"value" => normalized_value, "description" => description}
        {:cont, {:ok, Map.put(choices, normalized_value, choice)}}
      else
        false when not is_binary(description) ->
          {:halt, invalid("OpenAI Decisions choice descriptions must be strings")}

        true ->
          {:halt, invalid("OpenAI Decisions choice value collision after normalization")}

        {:error, _error} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, choices} ->
        values = choices |> Map.keys() |> Enum.sort_by(&choice_sort_key/1)
        {:ok, Enum.map(values, &Map.fetch!(choices, &1)), values}

      error ->
        error
    end
  end

  defp compile_choices(_criteria, name) do
    invalid("OpenAI Decisions choice question #{inspect(name)} needs non-empty map criteria")
  end

  defp normalize_choice_value(value, _name) when is_binary(value) or is_boolean(value),
    do: {:ok, value}

  defp normalize_choice_value(value, _name) when is_atom(value), do: {:ok, Atom.to_string(value)}

  defp normalize_choice_value(_value, name) do
    invalid("OpenAI Decisions choice values for #{inspect(name)} must be strings or booleans")
  end

  defp choice_sort_key(false), do: {0, "false"}
  defp choice_sort_key(true), do: {0, "true"}
  defp choice_sort_key(value), do: {1, value}

  defp compile_levels(criteria, name) when is_list(criteria) and criteria != [] do
    criteria
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn label, {:ok, levels, seen} ->
      with {:ok, normalized} <- normalize_level_label(label, name),
           false <- MapSet.member?(seen, normalized) do
        {:cont, {:ok, [%{"label" => normalized} | levels], MapSet.put(seen, normalized)}}
      else
        true -> {:halt, invalid("OpenAI Decisions score level collision after normalization")}
        {:error, _error} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, levels, _seen} ->
        levels = Enum.reverse(levels)
        {:ok, levels, Enum.map(levels, & &1["label"])}

      error ->
        error
    end
  end

  defp compile_levels(_criteria, name) do
    invalid("OpenAI Decisions score question #{inspect(name)} needs non-empty list criteria")
  end

  defp normalize_level_label(label, _name) when is_binary(label), do: {:ok, label}
  defp normalize_level_label(label, _name) when is_atom(label), do: {:ok, Atom.to_string(label)}

  defp normalize_level_label(_label, name) do
    invalid("OpenAI Decisions score labels for #{inspect(name)} must be strings or atoms")
  end

  defp validate_safety_identifier(nil), do: :ok

  defp validate_safety_identifier(value) when is_binary(value) do
    if String.length(value) <= 128 do
      :ok
    else
      invalid("OpenAI safety_identifier must be at most 128 characters")
    end
  end

  defp validate_safety_identifier(_value) do
    invalid("OpenAI safety_identifier must be a string")
  end

  defp decode_success(body, _request_model, contract) when is_map(body) do
    with model when is_binary(model) <- field(body, :model),
         answers when is_list(answers) <- field(body, :answers),
         usage when is_map(usage) <- field(body, :usage),
         {:ok, normalized_answers} <- validate_answers(answers, contract) do
      id = field(body, :id) || "decision-#{System.unique_integer([:positive])}"

      {:ok,
       %ReqLLM.Response{
         id: id,
         model: model,
         context: ReqLLM.Context.new(),
         object: Map.new(normalized_answers),
         usage: ReqLLM.Usage.normalize(usage),
         provider_meta: %{
           "api_type" => "decisions",
           operation: :evaluate,
           provider: :openai,
           raw_response: body
         }
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, "expected model, answers, and usage fields"}
    end
  end

  defp decode_success(_body, _request_model, _contract), do: {:error, "expected an object"}

  defp validate_answers(answers, nil) do
    answers
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn answer, {:ok, result, names} ->
      with {:ok, name, normalized} <- validate_answer_shape(answer),
           false <- MapSet.member?(names, name) do
        {:cont, {:ok, [{name, normalized} | result], MapSet.put(names, name)}}
      else
        true -> {:halt, {:error, "answer names must be unique"}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, result, _names} -> {:ok, Enum.reverse(result)}
      error -> error
    end
  end

  defp validate_answers(answers, contract) when is_list(contract) do
    if length(answers) == length(contract) do
      answers
      |> Enum.zip(contract)
      |> Enum.reduce_while({:ok, []}, fn {answer, expected}, {:ok, result} ->
        with {:ok, name, normalized} <- validate_answer_shape(answer),
             :ok <- validate_expected_answer(answer, name, expected) do
          {:cont, {:ok, [{name, normalized} | result]}}
        else
          {:error, _reason} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, result} -> {:ok, Enum.reverse(result)}
        error -> error
      end
    else
      {:error, "answer count does not match the request"}
    end
  end

  defp validate_answers(_answers, _contract), do: {:error, "invalid request answer contract"}

  defp validate_answer_shape(answer) when is_map(answer) do
    name = field(answer, :name)
    type = field(answer, :type)

    with true <- is_binary(name),
         {:ok, normalized} <- normalize_answer(type, answer) do
      {:ok, name, normalized}
    else
      false -> {:error, "answer name must be a string"}
      {:error, _reason} = error -> error
    end
  end

  defp validate_answer_shape(_answer), do: {:error, "each answer must be an object"}

  defp normalize_answer("predicate", answer) do
    probability = field(answer, :probability)

    if probability?(probability) do
      {:ok, %{"type" => "boolean", "probability" => probability}}
    else
      {:error, "predicate probability must be a number from 0 through 1"}
    end
  end

  defp normalize_answer("choice", answer) do
    choice = field(answer, :choice)
    confidence = field(answer, :confidence)
    probabilities = field(answer, :probabilities)

    with true <- is_binary(choice) or is_boolean(choice),
         true <- probability?(confidence),
         {:ok, probabilities} <- normalize_choice_probabilities(probabilities) do
      {:ok,
       answer
       |> string_key_map()
       |> Map.drop(["name"])
       |> Map.put("probabilities", probabilities)}
    else
      false -> {:error, "choice answer fields are invalid"}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_answer("score", answer) do
    score = field(answer, :score)
    confidence = field(answer, :confidence)
    probabilities = field(answer, :probabilities)

    with true <- is_number(score),
         true <- probability?(confidence),
         {:ok, probabilities} <- normalize_score_probabilities(probabilities) do
      {:ok,
       answer
       |> string_key_map()
       |> Map.drop(["name"])
       |> Map.put("probabilities", probabilities)}
    else
      false -> {:error, "score answer fields are invalid"}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_answer("refusal", _answer), do: {:ok, %{"type" => "refusal"}}
  defp normalize_answer(_type, _answer), do: {:error, "answer type is invalid"}

  defp normalize_choice_probabilities(values) when is_list(values) and values != [] do
    normalize_probability_list(values, fn item ->
      value = field(item, :value)
      probability = field(item, :probability)

      if (is_binary(value) or is_boolean(value)) and probability?(probability) do
        {:ok, %{"value" => value, "probability" => probability}}
      else
        {:error, "choice probability entry is invalid"}
      end
    end)
  end

  defp normalize_choice_probabilities(_values), do: {:error, "choice probabilities are invalid"}

  defp normalize_score_probabilities(values) when is_list(values) and values != [] do
    normalize_probability_list(values, fn item ->
      label = field(item, :label)
      value = field(item, :value)
      probability = field(item, :probability)

      if is_binary(label) and is_integer(value) and probability?(probability) do
        {:ok, %{"label" => label, "value" => value, "probability" => probability}}
      else
        {:error, "score probability entry is invalid"}
      end
    end)
  end

  defp normalize_score_probabilities(_values), do: {:error, "score probabilities are invalid"}

  defp normalize_probability_list(values, normalize) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, result} ->
      if is_map(value) do
        case normalize.(value) do
          {:ok, normalized} -> {:cont, {:ok, [normalized | result]}}
          {:error, _reason} = error -> {:halt, error}
        end
      else
        {:halt, {:error, "probability entries must be objects"}}
      end
    end)
    |> case do
      {:ok, result} -> {:ok, Enum.reverse(result)}
      error -> error
    end
  end

  defp validate_expected_answer(answer, name, expected) do
    type = field(answer, :type)

    cond do
      name != expected.name ->
        {:error, "answer name or order does not match the request"}

      type == "refusal" ->
        :ok

      type != expected.type ->
        {:error, "answer type does not match the request"}

      type == "choice" ->
        validate_choice_values(answer, expected.allowed_values)

      type == "score" ->
        validate_score_labels(answer, expected.labels)

      true ->
        :ok
    end
  end

  defp validate_choice_values(answer, allowed_values) do
    choice = field(answer, :choice)
    values = Enum.map(field(answer, :probabilities), &field(&1, :value))

    if choice in allowed_values and MapSet.new(values) == MapSet.new(allowed_values) do
      :ok
    else
      {:error, "choice answer contains a value that was not requested"}
    end
  end

  defp validate_score_labels(answer, labels) do
    returned_labels = Enum.map(field(answer, :probabilities), &field(&1, :label))
    returned_values = Enum.map(field(answer, :probabilities), &field(&1, :value))
    expected_values = Enum.to_list(0..(length(labels) - 1))
    score = field(answer, :score)

    if returned_labels == labels and returned_values == expected_values and score >= 0 and
         score <= length(labels) - 1 do
      :ok
    else
      {:error, "score answer levels do not match the request"}
    end
  end

  defp probability?(value), do: is_number(value) and value >= 0 and value <= 1

  defp string_key_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp field(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp invalid(message), do: {:error, InvalidParameter.exception(parameter: message)}
end
