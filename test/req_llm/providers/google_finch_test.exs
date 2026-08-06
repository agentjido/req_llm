defmodule ReqLLM.Providers.GoogleFinchTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Providers.Google

  describe "attach/3 Finch pool routing" do
    test "routes the request to the configured Finch pool" do
      request = Google.attach(Req.new(), "google:gemini-2.5-flash", api_key: "test")

      assert request.options[:finch] == [name: ReqLLM.Application.finch_name()]
    end

    test "keeps a Finch pool already set on the request" do
      request =
        Req.new()
        |> Req.Request.merge_options(finch: MyApp.CustomFinch)
        |> Google.attach("google:gemini-2.5-flash", api_key: "test")

      assert request.options[:finch] == [name: MyApp.CustomFinch]
    end
  end
end
