defmodule ReqLLM.Step.Fixture do
  @moduledoc """
  Req step that attaches test fixture functionality when running in test environments.

  This step:
  * Conditionally attaches fixture steps based on the `:fixture` option
  * Only activates when the Fixture module is available (test environment)
  * Normalizes fixture tuples to `{provider, name}` format
  * No-ops gracefully when fixtures aren't available

  ## Usage

      request
      |> ReqLLM.Step.Fixture.attach(model, opts)

  ## Options

  * `:fixture` - Can be:
    * `nil` - No fixture attached (default)
    * `"fixture_name"` - Uses model's provider with given name
    * `{:provider, "fixture_name"}` - Explicit provider and name tuple
  """

  @doc """
  Attaches the Fixture step to a Req request if fixture option is present.

  ## Parameters

  - `req` - The Req.Request struct
  - `model` - ReqLLM.Model struct for provider detection
  - `opts` - Options keyword list containing potential `:fixture` option

  ## Examples

      request
      |> ReqLLM.Step.Fixture.maybe_attach(model, fixture: "test_response")

      request
      |> ReqLLM.Step.Fixture.maybe_attach(model, fixture: {:openai, "chat_completion"})
  """
  @spec maybe_attach(Req.Request.t(), LLMDB.Model.t(), keyword()) :: Req.Request.t()
  def maybe_attach(%Req.Request{} = request, model, opts) do
    case normalize_fixture_tuple(model, opts[:fixture]) do
      {:ok, {provider, name}} ->
        attach_fixture_step(request, provider, name)

      :error ->
        request
    end
  end

  @spec normalize_fixture_tuple(LLMDB.Model.t(), any()) :: {:ok, {atom(), String.t()}} | :error
  defp normalize_fixture_tuple(_, nil), do: :error

  defp normalize_fixture_tuple(_, {provider, name}) when is_atom(provider) and is_binary(name) do
    {:ok, {provider, name}}
  end

  defp normalize_fixture_tuple(model, name) when is_binary(name) do
    {:ok, {model.provider, name}}
  end

  defp normalize_fixture_tuple(_, _), do: :error

  @compile {:nowarn_unused_function, attach_fixture_step: 3}
  @spec attach_fixture_step(Req.Request.t(), atom(), String.t()) :: Req.Request.t()
  defp attach_fixture_step(request, provider, name) do
    case Code.ensure_loaded(ReqLLM.Step.Fixture.Backend) do
      {:module, ReqLLM.Step.Fixture.Backend} ->
        # Backend.step/2 only exists in test environment
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        step_fn = apply(ReqLLM.Step.Fixture.Backend, :step, [provider, name])
        Req.Request.append_request_steps(request, llm_fixture: step_fn)

      {:error, _} ->
        # No-op if Backend not available
        request
    end
  end
end
