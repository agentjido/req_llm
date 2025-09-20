defmodule ReqLLM.Utils do
  @moduledoc false
  # Internal utility functions shared between ReqLLM modules

  # ---------------------------------------------------------------------------
  # Request processing utilities
  # ---------------------------------------------------------------------------

  @doc """
  Merges req_options into a Req.Request.
  """
  def merge_req_options(request, opts) do
    case Keyword.get(opts, :req_options, []) do
      [] -> request
      nil -> request
      opts when is_map(opts) -> Req.Request.merge_options(request, Map.to_list(opts))
      opts when is_list(opts) -> Req.Request.merge_options(request, opts)
    end
  end


end
