defmodule ReqLLM.Coverage.Google.CoreTest do
  @moduledoc """
  Core Google API feature coverage tests using simple fixtures.

  Run with LIVE=true to test against live API and record fixtures.
  Otherwise uses fixtures for fast, reliable testing.
  """

  use ReqLLM.ProviderTest.Core,
    provider: :google,
    model: "google:gemini-1.5-flash"

  # Google-specific tests would go here
  # Currently simplified due to API availability
end
