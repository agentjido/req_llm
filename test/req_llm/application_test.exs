defmodule ReqLLM.ApplicationTest do
  use ExUnit.Case, async: false

  describe "load_dotenv configuration" do
    test "get_finch_config/0 returns default configuration" do
      config = ReqLLM.Application.get_finch_config()

      assert Keyword.get(config, :name) == ReqLLM.Finch
      assert is_map(Keyword.get(config, :pools))
    end

    test "finch_name/0 returns default name" do
      assert ReqLLM.Application.finch_name() == ReqLLM.Finch
    end

    test "load_dotenv defaults to true" do
      original = Application.get_env(:req_llm, :load_dotenv)

      try do
        Application.delete_env(:req_llm, :load_dotenv)
        assert Application.get_env(:req_llm, :load_dotenv, true) == true
      after
        if original do
          Application.put_env(:req_llm, :load_dotenv, original)
        end
      end
    end

    test "load_dotenv can be set to false" do
      original = Application.get_env(:req_llm, :load_dotenv)

      try do
        Application.put_env(:req_llm, :load_dotenv, false)
        assert Application.get_env(:req_llm, :load_dotenv, true) == false
      after
        if original do
          Application.put_env(:req_llm, :load_dotenv, original)
        else
          Application.delete_env(:req_llm, :load_dotenv)
        end
      end
    end
  end
end
