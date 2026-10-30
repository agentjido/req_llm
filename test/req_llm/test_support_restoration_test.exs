defmodule ReqLLM.TestSupport.RestorationTest do
  use ExUnit.Case, async: false

  alias ReqLLM.Providers
  alias ReqLLM.Test.Env
  alias ReqLLM.Test.ProviderRegistration
  alias ReqLLM.TestSupport.ApplicationConfig

  defmodule OriginalProvider do
    use ReqLLM.Provider,
      id: :registration_helper_registered,
      default_base_url: "https://original.example"
  end

  defmodule RegisteredTemporaryProvider do
    use ReqLLM.Provider,
      id: :registration_helper_registered,
      default_base_url: "https://temporary.example"
  end

  defmodule AbsentTemporaryProvider do
    use ReqLLM.Provider,
      id: :registration_helper_absent,
      default_base_url: "https://temporary.example"
  end

  setup do
    providers = :persistent_term.get(:req_llm_providers)

    env =
      Map.new(
        [
          "REQ_LLM_RESTORATION_PRESENT",
          "REQ_LLM_RESTORATION_EMPTY",
          "REQ_LLM_RESTORATION_ABSENT"
        ],
        &{&1, System.get_env(&1)}
      )

    config =
      Map.new(
        [
          :restoration_present,
          :restoration_nil,
          :restoration_false,
          :restoration_absent
        ],
        &{&1, Application.fetch_env(:req_llm, &1)}
      )

    on_exit(fn ->
      :persistent_term.put(:req_llm_providers, providers)

      Enum.each(env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      Enum.each(config, fn
        {key, {:ok, value}} -> Application.put_env(:req_llm, key, value)
        {key, :error} -> Application.delete_env(:req_llm, key)
      end)
    end)

    :ok
  end

  test "provider registration restores present and absent entries" do
    Providers.register!(OriginalProvider)
    Providers.unregister(:registration_helper_absent)

    on_exit(fn ->
      assert Providers.get(:registration_helper_registered) == {:ok, OriginalProvider}
      assert match?({:error, _}, Providers.get(:registration_helper_absent))
    end)

    assert :ok = ProviderRegistration.register_provider(RegisteredTemporaryProvider)
    assert :ok = ProviderRegistration.register_provider(AbsentTemporaryProvider)
    assert Providers.get(:registration_helper_registered) == {:ok, RegisteredTemporaryProvider}
    assert Providers.get(:registration_helper_absent) == {:ok, AbsentTemporaryProvider}
  end

  test "environment isolation restores present, empty, and absent values" do
    System.put_env("REQ_LLM_RESTORATION_PRESENT", " original key\nwith whitespace ")
    System.put_env("REQ_LLM_RESTORATION_EMPTY", "")
    System.delete_env("REQ_LLM_RESTORATION_ABSENT")

    on_exit(fn ->
      assert System.get_env("REQ_LLM_RESTORATION_PRESENT") ==
               " original key\nwith whitespace "

      assert System.get_env("REQ_LLM_RESTORATION_EMPTY") == ""
      assert System.get_env("REQ_LLM_RESTORATION_ABSENT") == nil
    end)

    keys = [
      "REQ_LLM_RESTORATION_PRESENT",
      "REQ_LLM_RESTORATION_EMPTY",
      "REQ_LLM_RESTORATION_ABSENT"
    ]

    assert :ok = Env.isolate!(keys)
    assert Enum.all?(keys, &(System.get_env(&1) == nil))
    Enum.each(keys, &System.put_env(&1, "temporary"))
  end

  test "application configuration restores all prior value states" do
    Application.put_env(:req_llm, :restoration_present, :original)
    Application.put_env(:req_llm, :restoration_nil, nil)
    Application.put_env(:req_llm, :restoration_false, false)
    Application.delete_env(:req_llm, :restoration_absent)

    on_exit(fn ->
      assert Application.fetch_env(:req_llm, :restoration_present) == {:ok, :original}
      assert Application.fetch_env(:req_llm, :restoration_nil) == {:ok, nil}
      assert Application.fetch_env(:req_llm, :restoration_false) == {:ok, false}
      assert Application.fetch_env(:req_llm, :restoration_absent) == :error
    end)

    assert :ok =
             ApplicationConfig.put_env(
               restoration_present: :temporary,
               restoration_nil: :temporary,
               restoration_false: :temporary,
               restoration_absent: :temporary
             )

    assert :ok = ApplicationConfig.put_env(restoration_present: :second)
    assert Application.fetch_env(:req_llm, :restoration_present) == {:ok, :second}
  end
end
