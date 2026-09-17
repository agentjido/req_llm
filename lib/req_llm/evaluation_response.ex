defmodule ReqLLM.EvaluationResponse do
  @moduledoc """
  Result of evaluating one state against named questions.

  `answers` uses string question IDs. Each answer keeps the values returned by
  the provider. A boolean answer uses `"probability"` for the probability of yes.
  `raw` keeps the original provider response.
  """

  @type t :: %__MODULE__{
          model: String.t(),
          answers: %{optional(String.t()) => map()},
          usage: map(),
          raw: map()
        }

  defstruct [:model, :answers, :usage, :raw]
end
