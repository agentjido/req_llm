defmodule ReqLLM.Error do
  @moduledoc """
  Error handling system for ReqLLM using Splode.
  """

  use Splode,
    error_classes: [
      invalid: ReqLLM.Error.Invalid,
      api: ReqLLM.Error.API,
      validation: ReqLLM.Error.Validation,
      unknown: ReqLLM.Error.Unknown
    ],
    unknown_error: ReqLLM.Error.Unknown.Unknown

  defmodule Invalid do
    @moduledoc "Error class for invalid input parameters and configurations."
    use Splode.ErrorClass, class: :invalid
  end

  defmodule API do
    @moduledoc "Error class for API-related failures and HTTP errors."
    use Splode.ErrorClass, class: :api
  end

  defmodule Validation do
    @moduledoc "Error class for validation failures and parameter errors."
    use Splode.ErrorClass, class: :validation
  end

  defmodule Unknown do
    @moduledoc "Error class for unexpected or unhandled errors."
    use Splode.ErrorClass, class: :unknown
  end

  defmodule Invalid.Parameter do
    @moduledoc "Error for invalid or missing parameters."
    use Splode.Error, fields: [:parameter], class: :invalid

    @spec message(map()) :: String.t()
    def message(%{parameter: parameter}) do
      "Invalid parameter: #{parameter}"
    end
  end

  defmodule Invalid.Capability do
    @moduledoc "Error for unsupported model capabilities."
    use Splode.Error, fields: [:message, :missing], class: :invalid

    @spec message(map()) :: String.t()
    def message(%{message: msg}) when is_binary(msg), do: msg

    def message(%{missing: missing}) do
      "Unsupported capabilities: #{inspect(missing)}"
    end
  end

  defmodule API.Request do
    @moduledoc "Error for API request failures, HTTP errors, and network issues."
    use Splode.Error,
      fields: [:reason, :status, :response_body, :request_body, :cause],
      class: :api

    @spec message(map()) :: String.t()
    def message(%{reason: reason, status: status}) when not is_nil(status) do
      "API request failed (#{status}): #{reason}"
    end

    def message(%{reason: reason}) do
      "API request failed: #{reason}"
    end
  end

  defmodule API.Response do
    @moduledoc "Error for provider response parsing failures and unexpected response formats."
    use Splode.Error,
      fields: [:reason, :response_body, :status],
      class: :api

    @spec message(map()) :: String.t()
    def message(%{reason: reason, status: status}) when not is_nil(status) do
      "Provider response error (#{status}): #{reason}"
    end

    def message(%{reason: reason}) do
      "Provider response error: #{reason}"
    end
  end

  defmodule Validation.Error do
    @moduledoc "Error for parameter validation failures."
    use Splode.Error,
      fields: [:tag, :reason, :context],
      class: :validation

    @typedoc "Validation error returned by ReqLLM"
    @type t() :: %__MODULE__{
            tag: atom(),
            reason: String.t(),
            context: keyword()
          }

    @spec message(map()) :: String.t()
    def message(%{reason: reason}) do
      reason
    end
  end

  defmodule Unknown.Unknown do
    @moduledoc "Error for unexpected or unhandled errors."
    use Splode.Error, fields: [:error], class: :unknown

    @spec message(map()) :: String.t()
    def message(%{error: error}) do
      "Unknown error: #{inspect(error)}"
    end
  end

  defmodule Invalid.Provider do
    @moduledoc "Error for unknown or unsupported providers."
    use Splode.Error, fields: [:message, :provider], class: :invalid

    @typedoc "Error for unknown provider"
    @type t() :: %__MODULE__{
            message: String.t(),
            provider: atom()
          }

    @spec message(map()) :: String.t()
    def message(%{message: msg}) when is_binary(msg), do: msg

    def message(%{provider: provider}) do
      "Unknown provider: #{provider}"
    end
  end

  defmodule Invalid.Provider.NotImplemented do
    @moduledoc "Error for providers that exist but have no implementation (metadata-only)."
    use Splode.Error, fields: [:provider], class: :invalid

    @typedoc "Error for metadata-only providers"
    @type t() :: %__MODULE__{
            provider: atom()
          }

    @spec message(map()) :: String.t()
    def message(%{provider: provider}) do
      "Provider not implemented (metadata-only): #{provider}"
    end
  end

  defmodule Invalid.NotImplemented do
    @moduledoc "Error for unimplemented functionality."
    use Splode.Error, fields: [:feature], class: :invalid

    @spec message(map()) :: String.t()
    def message(%{feature: feature}) do
      "#{feature} not implemented"
    end
  end

  defmodule Invalid.Schema do
    @moduledoc "Error for invalid schema definitions."
    use Splode.Error, fields: [:reason], class: :invalid

    @spec message(map()) :: String.t()
    def message(%{reason: reason}) do
      "Invalid schema: #{reason}"
    end
  end

  defmodule Invalid.Message do
    @moduledoc "Error for invalid message structures or validation failures."
    use Splode.Error, fields: [:reason, :index], class: :invalid

    @spec message(map()) :: String.t()
    def message(%{reason: reason, index: index}) when is_integer(index) do
      "Message at index #{index}: #{reason}"
    end

    def message(%{reason: reason}) do
      reason
    end
  end

  defmodule Invalid.MessageList do
    @moduledoc "Error for invalid message list structures."
    use Splode.Error, fields: [:reason, :received], class: :invalid

    @spec message(map()) :: String.t()
    def message(%{reason: _reason, received: received}) do
      "Expected a list of messages, got: #{inspect(received)}"
    end

    def message(%{reason: reason}) do
      reason
    end
  end

  defmodule Invalid.Content do
    @moduledoc "Error for invalid message content."
    use Splode.Error, fields: [:reason, :received], class: :invalid

    @spec message(map()) :: String.t()
    def message(%{reason: _reason, received: received}) do
      "Content must be a string or list of ContentPart structs, got: #{inspect(received)}"
    end

    def message(%{reason: reason}) do
      reason
    end
  end

  defmodule Invalid.Role do
    @moduledoc "Error for invalid message roles."
    use Splode.Error, fields: [:role], class: :invalid

    @spec message(map()) :: String.t()
    def message(%{role: role}) do
      "Invalid role: #{inspect(role)}. Must be :user, :assistant, :system, or :tool"
    end
  end

  defmodule API.SchemaValidation do
    @moduledoc "Error for when generated objects don't match the expected schema."
    use Splode.Error,
      fields: [:message, :errors, :json_path, :value],
      class: :api

    @spec message(map()) :: String.t()
    def message(%{message: message}) when is_binary(message) do
      message
    end

    def message(%{errors: errors, json_path: json_path})
        when is_list(errors) and is_binary(json_path) do
      "Schema validation failed at #{json_path}: #{format_errors(errors)}"
    end

    def message(%{errors: errors}) when is_list(errors) do
      "Schema validation failed: #{format_errors(errors)}"
    end

    def message(_) do
      "Schema validation failed"
    end

    defp format_errors(errors) do
      errors
      |> Enum.take(3)
      |> Enum.map_join(", ", &to_string/1)
    end
  end

  defmodule API.JSONDecode do
    @moduledoc "Error for when we can't parse the JSON response."
    use Splode.Error,
      fields: [:message, :partial, :raw_response, :position],
      class: :api

    @spec message(map()) :: String.t()
    def message(%{message: message}) when is_binary(message) do
      "JSON decode error: #{message}"
    end

    def message(%{partial: partial, position: position})
        when is_binary(partial) and is_integer(position) do
      "JSON decode error at position #{position}. Partial: #{String.slice(partial, 0, 50)}..."
    end

    def message(%{partial: partial}) when is_binary(partial) do
      "JSON decode error. Partial: #{String.slice(partial, 0, 50)}..."
    end

    def message(_) do
      "JSON decode error"
    end
  end

  defmodule API.Stream do
    @moduledoc "Error for stream processing failures."
    use Splode.Error,
      fields: [:reason, :cause],
      class: :api

    @spec message(map()) :: String.t()
    def message(%{reason: reason}) do
      reason
    end
  end

  @doc """
  Creates a validation error with the given tag, reason, and context.

  ## Examples

      iex> error = ReqLLM.Error.validation_error(:invalid_model_spec, "Bad model", model: "test")
      iex> error.tag
      :invalid_model_spec
      iex> error.reason
      "Bad model"
      iex> error.context
      [model: "test"]

  """
  @spec validation_error(atom(), String.t(), keyword()) :: ReqLLM.Error.Validation.Error.t()
  def validation_error(tag, reason, context \\ []) do
    ReqLLM.Error.Validation.Error.exception(tag: tag, reason: reason, context: context)
  end
end
