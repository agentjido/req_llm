defmodule ReqLLM.Providers.AmazonBedrock.AWSAuthAdapter do
  @moduledoc false

  @aws_auth_module :"Elixir.AWSAuth"
  @credentials_module :"Elixir.AWSAuth.Credentials"
  @event_stream_module :"Elixir.AWSAuth.EventStream"
  @req_module :"Elixir.AWSAuth.Req"

  @dependency_error """
  AWS Bedrock IAM, STS, and bidirectional streaming require the ex_aws_auth dependency.
  Please add {:ex_aws_auth, "~> 1.4"} to your mix.exs dependencies.
  """

  def dependency_error, do: @dependency_error

  def ensure_available! do
    ensure_loaded!(@credentials_module)
    ensure_loaded!(@aws_auth_module)
    ensure_loaded!(@event_stream_module)
    ensure_loaded!(@req_module)
    :ok
  end

  def from_map(map) do
    call(@credentials_module, :from_map, [map])
  end

  def from_env do
    call(@credentials_module, :from_env, [])
  end

  def credentials_struct(fields) do
    struct(ensure_loaded!(@credentials_module), fields)
  end

  def credentials?(value) do
    is_map(value) and Map.get(value, :__struct__) == @credentials_module
  end

  def attach_request(request, opts) do
    call(@req_module, :attach, [request, opts])
  end

  def sign_authorization_header(credentials, method, url, service, opts) do
    call(@aws_auth_module, :sign_authorization_header, [credentials, method, url, service, opts])
  end

  def event_stream_sign_message(credentials, service, prior_signature, payload, datetime) do
    call(@event_stream_module, :sign_message, [
      credentials,
      service,
      prior_signature,
      payload,
      datetime
    ])
  end

  def event_stream_encode_string_header(name, value) do
    call(@event_stream_module, :encode_string_header, [name, value])
  end

  def event_stream_encode_message(headers, payload) do
    call(@event_stream_module, :encode_message, [headers, payload])
  end

  defp call(module, function, args) do
    module
    |> ensure_loaded!()
    |> apply(function, args)
  end

  defp ensure_loaded!(module) do
    case Code.ensure_loaded(module) do
      {:module, loaded_module} -> loaded_module
      {:error, _reason} -> raise @dependency_error
    end
  end
end
