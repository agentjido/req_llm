defmodule ReqLLM.Coverage.MoonshotAI.ComprehensiveTest do
  @moduledoc """
  Comprehensive Kimi K3 coverage for Moonshot AI.

  Set `MOONSHOT_API_KEY` and use fixture record mode to exercise the live API.
  Replay mode uses committed fixtures after they have been recorded.
  """

  use ReqLLM.ProviderTest.Comprehensive, provider: :moonshotai
end
