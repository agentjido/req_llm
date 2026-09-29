defmodule ReqLLM.Evaluation.Codec do
  @moduledoc false

  alias ReqLLM.Response

  @spec normalize_questions(map()) :: map()
  def normalize_questions(questions) do
    Map.new(questions, fn {id, question} ->
      {to_string(id), normalize_question(question)}
    end)
  end

  @spec decode_response(map(), atom()) :: {:ok, Response.t()} | :error
  def decode_response(
        %{"model" => model, "answers" => answers, "usage" => usage} = body,
        provider
      )
      when is_binary(model) and is_map(answers) and is_map(usage) do
    id = Map.get(body, "id") || "eval-#{System.unique_integer([:positive])}"

    {:ok,
     %Response{
       id: id,
       model: model,
       context: ReqLLM.Context.new(),
       object: normalize_answers(answers),
       usage: ReqLLM.Usage.normalize(usage),
       provider_meta: %{operation: :evaluate, provider: provider, raw_response: body}
     }}
  end

  def decode_response(_, _), do: :error

  defp normalize_question(question) do
    case question[:type] || question["type"] do
      type when type in [:boolean, "boolean"] ->
        question
        |> Map.drop([:type, "type"])
        |> Map.put("type", "noul")

      _ ->
        question
    end
  end

  defp normalize_answers(answers) do
    Map.new(answers, fn {id, answer} ->
      case answer do
        %{"type" => "noul", "noul" => probability} ->
          {to_string(id),
           answer
           |> Map.drop(["noul"])
           |> Map.put("type", "boolean")
           |> Map.put("probability", probability)}

        _ ->
          {to_string(id), answer}
      end
    end)
  end
end
