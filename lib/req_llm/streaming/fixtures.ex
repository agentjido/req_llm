defmodule ReqLLM.Streaming.Fixtures do
  @moduledoc false

  @type mode :: :record | :replay
  @type fixture_opt :: nil | String.t() | {atom(), String.t()}

  defmodule HTTPContext do
    @moduledoc """
    Lightweight HTTP context for streaming operations.

    This struct contains the minimal HTTP metadata needed for fixture capture
    and debugging, replacing the heavier Req.Request/Response structs for
    streaming operations.
    """

    @derive Jason.Encoder
    defstruct [
      :url,
      :method,
      :req_headers,
      :status,
      :resp_headers
    ]

    @type t :: %__MODULE__{
            url: String.t(),
            method: :get | :post | :put | :patch | :delete,
            req_headers: map(),
            status: integer() | nil,
            resp_headers: map() | nil
          }

    @doc """
    Creates a new HTTPContext from request parameters.
    """
    @spec new(String.t(), :get | :post | :put | :patch | :delete, map()) :: t()
    def new(url, method, headers) do
      %__MODULE__{
        url: url,
        method: method,
        req_headers: sanitize_headers(headers),
        status: nil,
        resp_headers: nil
      }
    end

    @doc """
    Updates the context with response status and headers.
    """
    @spec update_response(t(), integer(), map()) :: t()
    def update_response(%__MODULE__{} = context, status, headers) do
      %{context | status: status, resp_headers: sanitize_headers(headers)}
    end

    @doc """
    Builds HTTPContext from a Finch.Request struct.

    Extracts URL, method, and headers with proper sanitization.
    """
    @spec from_finch_request(Finch.Request.t()) :: t()
    def from_finch_request(%Finch.Request{} = finch_request) do
      url =
        if (finch_request.scheme == :https and finch_request.port == 443) or
             (finch_request.scheme == :http and finch_request.port == 80) do
          "#{finch_request.scheme}://#{finch_request.host}#{finch_request.path}"
        else
          "#{finch_request.scheme}://#{finch_request.host}:#{finch_request.port}#{finch_request.path}"
        end

      method = String.downcase(finch_request.method) |> String.to_atom()

      new(url, method, Map.new(finch_request.headers))
    end

    defp sanitize_headers(headers) when is_map(headers) do
      sensitive_keys = [
        "authorization",
        "x-api-key",
        "anthropic-api-key",
        "openai-api-key",
        "x-auth-token",
        "api-key",
        "access-token"
      ]

      headers
      |> Map.new(fn {k, v} -> {String.downcase(to_string(k)), v} end)
      |> Enum.reduce(%{}, fn {key, value}, acc ->
        if key in sensitive_keys do
          Map.put(acc, key, "[REDACTED:#{key}]")
        else
          Map.put(acc, key, value)
        end
      end)
    end

    defp sanitize_headers(headers) when is_list(headers) do
      headers
      |> Map.new()
      |> sanitize_headers()
    end

    defp sanitize_headers(headers), do: headers
  end

  @doc """
  Extracts canonical JSON from Finch request body for fixture capture.

  Handles various body formats and returns a JSON-serializable structure.
  """
  @spec canonical_json_from_finch_request(Finch.Request.t()) :: map()
  def canonical_json_from_finch_request(%Finch.Request{body: body}) do
    case body do
      nil ->
        %{}

      binary when is_binary(binary) ->
        case Jason.decode(binary) do
          {:ok, json} -> json
          {:error, _} -> %{raw_body: binary}
        end

      {:stream, _} ->
        %{streaming_body: true}

      other ->
        %{unknown_body: inspect(other)}
    end
  rescue
    _ -> %{}
  end

  @doc """
  Detect current fixture mode from test environment.

  Returns `:record` or `:replay`. Defaults to `:replay` when
  test environment is unavailable.
  """
  @spec mode() :: mode
  def mode do
    if Code.ensure_loaded?(ReqLLM.Test.Env) do
      apply(ReqLLM.Test.Env, :fixtures_mode, [])
    else
      :replay
    end
  rescue
    _ -> :replay
  end

  @doc """
  Normalize fixture option to {provider, name} tuple.

  Handles multiple input formats:
  - `nil` → `nil`
  - `{:provider, "name"}` → `{:provider, "name"}`
  - `"provider_name"` → `{:provider, "provider_name"}`
  """
  @spec normalize(fixture_opt) :: {atom(), String.t()} | nil
  def normalize(nil), do: nil

  def normalize({provider, name}) when is_atom(provider) and is_binary(name), do: {provider, name}

  def normalize(name) when is_binary(name) do
    provider =
      case String.split(name, "_", parts: 2) do
        [possible | _] -> String.to_atom(possible)
        _ -> :unknown
      end

    {provider, name}
  end

  @doc """
  Root directory for all fixtures.
  """
  @spec root() :: String.t()
  def root do
    Path.expand("test/support/fixtures")
  end

  @doc """
  Build fixture file path from {provider, name} tuple.
  """
  @spec path({atom(), String.t()}) :: String.t()
  def path({provider, name}) do
    Path.join([root(), to_string(provider), "#{name}.json"])
  end

  @doc """
  Determine replay fixture path from options.

  Returns `{:fixture, path}` when:
  - Mode is `:replay`
  - `:fixture` option is provided
  - Fixture file exists

  Otherwise returns `:no_fixture`.

  Raises if replay mode and fixture specified but file doesn't exist.
  """
  @spec replay_path(keyword()) :: {:fixture, String.t()} | :no_fixture
  def replay_path(opts) do
    case {mode(), Keyword.get(opts, :fixture)} do
      {:replay, nil} ->
        :no_fixture

      {:replay, fixture} ->
        tuple = normalize(fixture)
        fixture_path = path(tuple)

        if File.exists?(fixture_path) do
          {:fixture, fixture_path}
        else
          raise """
          Fixture not found: #{fixture_path}
          Run the test with REQ_LLM_FIXTURES_MODE=record to capture it.
          """
        end

      _ ->
        :no_fixture
    end
  end

  @doc """
  Determine capture fixture path from options.

  Returns path string when:
  - `:fixture_path` explicitly provided, OR
  - Mode is `:record` and `:fixture` option provided

  Otherwise returns `nil`.
  """
  @spec capture_path(keyword()) :: String.t() | nil
  def capture_path(opts) do
    case Keyword.get(opts, :fixture_path) do
      nil ->
        if mode() == :record do
          with fixture when not is_nil(fixture) <- Keyword.get(opts, :fixture),
               tuple when not is_nil(tuple) <- normalize(fixture) do
            path(tuple)
          end
        end

      explicit_path ->
        Path.expand(explicit_path)
    end
  end
end
