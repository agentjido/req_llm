defmodule ReqLLM.Providers.OpenAI.API do
  @moduledoc """
  Behaviour for OpenAI API endpoint drivers.

  Defines the contract for modules that implement OpenAI API-specific request/response handling.
  The OpenAI provider uses this behaviour to support multiple API endpoints with different
  request/response formats.

  ## Implementations

  - `ReqLLM.Providers.OpenAI.ChatAPI` - Chat Completions API (`/v1/chat/completions`)
  - `ReqLLM.Providers.OpenAI.ResponsesAPI` - Responses API (`/v1/responses`)

  ## Callbacks

  - `path/0` - Returns the API endpoint path
  - `encode_body/1` - Transforms request into provider-specific JSON format
  - `decode_response/1` - Parses API responses into ReqLLM structures
  - `decode_stream_event/2` - Decodes server-sent events for streaming
  - `attach_stream/4` - Builds Finch streaming request with proper headers/body
  """

  @callback path() :: String.t()
  @callback encode_body(Req.Request.t()) :: Req.Request.t()
  @callback decode_response({Req.Request.t(), Req.Response.t()}) ::
              {Req.Request.t(), Req.Response.t() | Exception.t()}
  @callback decode_stream_event(map(), LLMDB.Model.t()) :: [ReqLLM.StreamChunk.t()]
  @callback attach_stream(
              LLMDB.Model.t(),
              ReqLLM.Context.t(),
              keyword(),
              atom()
            ) :: {:ok, Finch.Request.t()} | {:error, Exception.t()}
end
