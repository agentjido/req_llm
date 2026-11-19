defmodule ReqLLM.Evaluation.AnswerValidation do
  @moduledoc false

  alias ReqLLM.Error.Invalid.Parameter

  @protocols ["typesafe_systemone", "openrouter_decisions"]

  def validate_protocol(_model, nil), do: :ok

  def validate_protocol(model, :strict) do
    if get_in(model.execution || %{}, [:evaluate, :wire_protocol]) in @protocols do
      :ok
    else
      {:error,
       Parameter.exception(
         parameter:
           "strict answer validation requires TypeSafe System One or OpenRouter Decisions"
       )}
    end
  end

  def validate(nil, _questions, _answers), do: :ok

  def validate(:strict, questions, answers) when is_map(answers) do
    Enum.reduce_while(questions, :ok, fn {name, question}, :ok ->
      case validate_requested_answer(Map.fetch(answers, to_string(name)), question) do
        :ok ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, "Invalid evaluation answer for #{inspect(name)}. #{reason}"}}
      end
    end)
  end

  def validate(:strict, _questions, _answers),
    do: {:error, "Evaluation answers must be an object"}

  defp validate_requested_answer(:error, _question), do: {:error, "Answer is missing"}

  defp validate_requested_answer({:ok, answer}, question) do
    criteria = question[:criteria] || question["criteria"]

    case question[:type] || question["type"] do
      type when type in [:boolean, "boolean", :noul, "noul"] -> validate_boolean(answer)
      type when type in [:choice, "choice"] -> validate_choice(answer, criteria)
      type when type in [:score, "score"] -> validate_score(answer, criteria)
      _ -> :ok
    end
  end

  defp validate_boolean(%{"type" => "boolean", "probability" => value} = answer) do
    with :ok <- require_valid(probability?(value), "Probability must be in [0, 1]") do
      validate_probabilities(answer)
    end
  end

  defp validate_boolean(_answer), do: {:error, "Expected a boolean answer"}

  defp validate_choice(%{"type" => "choice", "choice" => choice} = answer, criteria) do
    with :ok <-
           require_valid(
             is_binary(choice) and Enum.any?(choice_keys(criteria), &same_key?(&1, choice)),
             "Choice was not in the submitted criteria"
           ) do
      validate_probabilities(answer)
    end
  end

  defp validate_choice(_answer, _criteria), do: {:error, "Expected a Choice answer"}

  defp validate_score(%{"type" => "score", "score" => score} = answer, criteria) do
    with :ok <-
           require_valid(
             is_number(score) and is_list(criteria) and score >= 0 and
               score <= length(criteria) - 1,
             "Score is outside the submitted rubric"
           ) do
      validate_probabilities(answer)
    end
  end

  defp validate_score(_answer, _criteria), do: {:error, "Expected a Score answer"}

  defp choice_keys(%Jason.OrderedObject{values: pairs}), do: Enum.map(pairs, &elem(&1, 0))
  defp choice_keys(criteria) when is_map(criteria), do: Map.keys(criteria)
  defp choice_keys(_criteria), do: []

  defp same_key?(key, value) when is_binary(key) or is_atom(key), do: to_string(key) == value
  defp same_key?(_key, _value), do: false

  defp validate_probabilities(answer) do
    with :ok <-
           require_valid(
             is_nil(answer["confidence"]) or probability?(answer["confidence"]),
             "Confidence must be in [0, 1]"
           ) do
      require_valid(probabilities?(answer["probabilities"]), "Probabilities must be in [0, 1]")
    end
  end

  defp probabilities?(nil), do: true

  defp probabilities?(values) when is_map(values),
    do: Enum.all?(values, fn {_, value} -> probability?(value) end)

  defp probabilities?(_values), do: false

  defp probability?(value), do: is_number(value) and value >= 0 and value <= 1

  defp require_valid(true, _reason), do: :ok
  defp require_valid(false, reason), do: {:error, reason}
end
