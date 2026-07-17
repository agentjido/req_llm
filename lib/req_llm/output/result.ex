defmodule ReqLLM.Output.Result do
  @moduledoc """
  Describes how a complete `ReqLLM.Output` value was materialized and validated.

  Results keep the retained raw provider value, projected value, validation
  errors, warnings, repair attempts, extraction source, and provider metadata
  separate. They are computed with `ReqLLM.Response.output_result/3` and do not
  change the response or trigger another model call.
  """

  @type source :: :text | :tool_call | :response_object | :missing

  @type repair :: %{
          required(:type) => :json_repair | :legacy_type_coercion | :callback,
          required(:status) => :applied | :failed,
          optional(:reason) => String.t()
        }

  @type validation_error :: %{
          required(:type) => :missing_value | :invalid_type | :schema_validation,
          required(:message) => String.t()
        }

  @type t :: %__MODULE__{
          value: term(),
          raw: term(),
          valid?: boolean(),
          errors: [validation_error()],
          warnings: [String.t()],
          repairs: [repair()],
          source: source(),
          policy: ReqLLM.Output.validation_policy(),
          provider_metadata: map()
        }

  @enforce_keys [
    :value,
    :raw,
    :valid?,
    :errors,
    :warnings,
    :repairs,
    :source,
    :policy,
    :provider_metadata
  ]
  defstruct @enforce_keys
end
