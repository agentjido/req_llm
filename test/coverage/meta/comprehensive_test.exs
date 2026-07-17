defmodule ReqLLM.Coverage.Meta.ComprehensiveTest do
  @moduledoc """
  Comprehensive Meta Model API feature coverage tests.

  Set `MODEL_API_KEY`, select `meta:muse-spark-1.1`, and use fixture record mode
  to exercise the live API and record fixtures. Replay mode uses committed fixtures.
  """

  use ReqLLM.ProviderTest.Comprehensive, provider: :meta
end
