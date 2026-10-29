defmodule ReqLLM.Runtime do
  @moduledoc false

  alias ReqLLM.Provider.Adapter
  alias ReqLLM.RequestPlan
  alias ReqLLM.TimeoutBudget

  @doc """
  Executes a synchronous Req plan using the existing provider and timeout paths.

  The operation boundary resolves the model and provider, processes options, and
  starts the deadline before building the plan. The adapter prepares the provider's
  Req pipeline unchanged; TimeoutBudget attaches the current transport and runs it.
  Preparation and transport errors pass through without invoking the result policy.

  The result policy is a single function owned by the operation. It receives the
  completed Req response, including non-2xx responses, and retains the operation's
  current normalization and HTTP error handling. It runs outside the request budget,
  as it does at the existing operation boundaries.
  """
  @spec execute(
          RequestPlan.t(),
          term(),
          TimeoutBudget.deadline(),
          (Req.Response.t() -> {:ok, term()} | {:error, term()})
        ) :: {:ok, term()} | {:error, term()}
  def execute(%RequestPlan{transport: :req} = plan, input, deadline, result_policy)
      when is_function(result_policy, 1) do
    with {:ok, request} <- prepare(plan, input) do
      execute_prepared(request, deadline, result_policy)
    end
  end

  @doc """
  Prepares a synchronous Req plan without sending it.

  The operation can inspect or transform the provider's request before execution.
  The existing provider callback receives the plan's model, input, and options
  unchanged, and preparation errors pass through unchanged.
  """
  @spec prepare(RequestPlan.t(), term()) :: {:ok, Req.Request.t()} | {:error, term()}
  def prepare(%RequestPlan{transport: :req} = plan, input) do
    Adapter.prepare_request(
      plan.provider_module,
      plan.operation,
      plan.model,
      input,
      plan.options
    )
  end

  @doc false
  @spec prepare_stream(RequestPlan.t(), term()) ::
          {:ok, Req.Request.t()} | {:error, term()}
  def prepare_stream(%RequestPlan{transport: transport} = plan, input)
      when transport in [:finch, :websocket, :in_process] do
    Adapter.prepare_request(
      plan.provider_module,
      plan.operation,
      plan.model,
      input,
      plan.options
    )
  end

  @doc false
  @spec execute_stream(RequestPlan.t(), ReqLLM.Context.t()) ::
          {:ok, ReqLLM.StreamResponse.t()} | {:error, term()}
  def execute_stream(%RequestPlan{transport: transport} = plan, %ReqLLM.Context{} = context)
      when transport in [:finch, :websocket, :in_process] do
    ReqLLM.Streaming.start_planned_stream(plan, context)
  end

  @doc """
  Sends an already prepared Req request using the supplied deadline.

  The operation owns when its deadline starts and any changes made after provider
  preparation. Every completed response, including non-2xx responses, reaches the
  result policy outside the request budget. Transport errors pass through without
  invoking the policy. A prepared request can be reused for subsequent executions.
  """
  @spec execute_prepared(
          Req.Request.t(),
          TimeoutBudget.deadline(),
          (Req.Response.t() -> {:ok, term()} | {:error, term()})
        ) :: {:ok, term()} | {:error, term()}
  def execute_prepared(%Req.Request{} = request, deadline, result_policy)
      when is_function(result_policy, 1) do
    with {:ok, response} <- TimeoutBudget.request(request, deadline) do
      result_policy.(response)
    end
  end
end
