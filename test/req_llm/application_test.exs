defmodule ReqLLM.ApplicationTest do
  use ExUnit.Case, async: false

  @dotenv_key "REQ_LLM_ISSUE_527_DOTENV_KEY"

  setup do
    original_req_llm_load_dotenv = Application.get_env(:req_llm, :load_dotenv)
    original_llm_db_load_dotenv = Application.get_env(:llm_db, :load_dotenv)

    on_exit(fn ->
      stop_app(:req_llm)
      stop_app(:llm_db)
      restore_app_env(:req_llm, :load_dotenv, original_req_llm_load_dotenv)
      restore_app_env(:llm_db, :load_dotenv, original_llm_db_load_dotenv)
      System.delete_env(@dotenv_key)
      Application.ensure_all_started(:llm_db)
      LLMDB.load(custom: Application.get_env(:llm_db, :custom, %{}))
      Application.ensure_all_started(:req_llm)
    end)

    :ok
  end

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

    test "load_dotenv false prevents llm_db from loading .env during req_llm startup" do
      with_apps_stopped(fn ->
        with_temp_dir(fn ->
          File.write!(".env", "#{@dotenv_key}=from_file\n")
          System.delete_env(@dotenv_key)
          Application.put_env(:req_llm, :load_dotenv, false)
          Application.delete_env(:llm_db, :load_dotenv)

          assert {:ok, _} = Application.ensure_all_started(:req_llm)
          assert System.get_env(@dotenv_key) == nil
        end)
      end)
    end

    test "startup does not overwrite existing env vars from .env files" do
      with_apps_stopped(fn ->
        with_temp_dir(fn ->
          File.write!(".env", "#{@dotenv_key}=from_file\n")
          System.put_env(@dotenv_key, "from_env")
          Application.delete_env(:req_llm, :load_dotenv)
          Application.delete_env(:llm_db, :load_dotenv)

          assert {:ok, _} = Application.ensure_all_started(:req_llm)
          assert System.get_env(@dotenv_key) == "from_env"
        end)
      end)
    end

    test "explicit llm_db load_dotenv config overrides req_llm default" do
      with_apps_stopped(fn ->
        with_temp_dir(fn ->
          File.write!(".env", "#{@dotenv_key}=from_file\n")
          System.delete_env(@dotenv_key)
          Application.put_env(:req_llm, :load_dotenv, false)
          Application.put_env(:llm_db, :load_dotenv, true)

          assert {:ok, _} = Application.ensure_all_started(:req_llm)
          assert System.get_env(@dotenv_key) == "from_file"
        end)
      end)
    end
  end

  defp with_apps_stopped(fun) do
    stop_app(:req_llm)
    stop_app(:llm_db)
    fun.()
  end

  defp with_temp_dir(fun) do
    path = Path.join(System.tmp_dir!(), "req-llm-issue-527-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)

    try do
      File.cd!(path, fun)
    after
      File.rm_rf!(path)
    end
  end

  defp stop_app(app) do
    if Keyword.has_key?(Application.started_applications(), app) do
      Application.stop(app)
    end
  end

  defp restore_app_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_app_env(app, key, value), do: Application.put_env(app, key, value)
end
