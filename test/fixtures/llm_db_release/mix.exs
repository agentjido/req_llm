defmodule ReqLLM.LLMDBReleaseFixture.MixProject do
  use Mix.Project

  @req_llm_path System.fetch_env!("REQ_LLM_PATH")

  def project do
    [
      app: :req_llm_llm_db_release_fixture,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: true,
      lockfile: Path.join(@req_llm_path, "mix.lock"),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {ReqLLM.LLMDBReleaseFixture.Application, []}
    ]
  end

  defp deps do
    [
      {:req_llm, path: @req_llm_path},
      {:llm_db, path: Path.join(@req_llm_path, "deps/llm_db"), override: true}
    ]
  end
end
