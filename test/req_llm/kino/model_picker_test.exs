defmodule ReqLLM.Kino.ModelPickerTest do
  use ExUnit.Case, async: false

  alias ReqLLM.Kino.ModelPicker
  alias ReqLLM.Kino.ModelPicker.Source

  @base_url "http://127.0.0.1:4444/v1"
  @env_vars ~w(LB_LMSTUDIO_API_KEY LMSTUDIO_API_KEY LB_ANTHROPIC_API_KEY LB_OPENAI_API_KEY)

  setup do
    defaults = Req.default_options()
    Req.default_options(Keyword.put(defaults, :plug, {Req.Test, __MODULE__}))

    env = Map.take(System.get_env(), @env_vars)
    Enum.each(@env_vars, &System.delete_env/1)

    lmstudio_key = Application.fetch_env(:req_llm, :lmstudio_api_key)
    Application.delete_env(:req_llm, :lmstudio_api_key)

    on_exit(fn ->
      Req.default_options(defaults)
      Enum.each(@env_vars, &System.delete_env/1)
      System.put_env(env)

      case lmstudio_key do
        {:ok, key} -> Application.put_env(:req_llm, :lmstudio_api_key, key)
        :error -> Application.delete_env(:req_llm, :lmstudio_api_key)
      end
    end)
  end

  test "discovers model IDs from LM Studio and keeps its endpoint in the selected model" do
    System.put_env("LB_LMSTUDIO_API_KEY", "fixture-lmstudio-key")
    System.put_env("LMSTUDIO_API_KEY", "fixture-env-key")
    base_url = Source.base_url!(:lmstudio, base_url: @base_url <> "/")

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/v1/models"
      assert conn.port == 4444
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer fixture-lmstudio-key"]

      Req.Test.json(conn, %{
        "data" => [
          %{"id" => "org/chat:Q4"},
          %{"id" => "another-model"},
          %{"id" => "org/chat:Q4"},
          %{"id" => ""},
          %{"id" => 123},
          %{}
        ]
      })
    end)

    assert {:ok, [{"another-model", _}, {"org/chat:Q4", _}]} =
             Source.choices(:lmstudio, base_url)

    assert {:ok,
            %LLMDB.Model{provider: :lmstudio, id: "org/chat:Q4", base_url: @base_url} = model} =
             Source.model(:lmstudio, "org/chat:Q4", base_url)

    refute inspect(model) =~ "fixture-lmstudio-key"
    assert ModelPicker.request_options(model) == [api_key: "fixture-lmstudio-key"]
  end

  test "handles LM Studio failures and keeps the manual ID available" do
    for {reply, message} <- [
          {&Req.Test.json(&1, %{"data" => []}), "no models"},
          {&Req.Test.json(&1, %{"unexpected" => true}), "invalid model list"},
          {&Plug.Conn.send_resp(&1, 401, "fixture-secret-response"), "LMSTUDIO_API_KEY"},
          {&Req.Test.transport_error(&1, :econnrefused), "Could not get"}
        ] do
      Req.Test.stub(__MODULE__, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == []
        reply.(conn)
      end)

      assert {:error, notice} = Source.choices(:lmstudio, @base_url)
      assert notice =~ message
      refute notice =~ "fixture-secret-response"
    end

    assert {:ok, %LLMDB.Model{id: "manual/model:Q8", base_url: @base_url}} =
             Source.model(:lmstudio, "manual/model:Q8", @base_url)
  end

  test "requires a model and rejects an LM Studio URL with credentials" do
    assert {:error, "Select a model or enter a model ID."} = Source.model(:openai, nil, nil)

    assert_raise ArgumentError, ~r/ends in \/v1/, fn ->
      Source.base_url!(:lmstudio, base_url: "http://user:fixture-password@127.0.0.1:4444/v1")
    end
  end

  test "lists cloud text models from the catalog and accepts IDs outside the catalog" do
    Req.Test.stub(__MODULE__, fn _conn -> flunk("Cloud model selection must use the catalog") end)

    for provider <- [:anthropic, :openai] do
      assert {:ok, [{id, _label} | _] = choices} = Source.choices(provider, nil)
      refute List.keymember?(choices, "text-embedding-3-small", 0)
      refute List.keymember?(choices, "gpt-realtime-2.1", 0)

      assert {:ok, %LLMDB.Model{provider: ^provider, id: ^id}} = Source.model(provider, id, nil)

      assert {:ok, %LLMDB.Model{provider: ^provider, id: "my-text-deployment"}} =
               Source.model(provider, "my-text-deployment", nil)
    end

    assert {:error, "Choose a model that supports text generation."} =
             Source.model(:openai, "text-embedding-3-small", nil)
  end

  test "uses the Livebook secret for the selected provider only" do
    assert {:ok, model} = Source.model(:anthropic, "my-deployment", nil)
    System.put_env("LB_OPENAI_API_KEY", "fixture-openai-key")
    System.put_env("LB_ANTHROPIC_API_KEY", "")
    assert ModelPicker.request_options(model) == []

    System.put_env("LB_ANTHROPIC_API_KEY", "fixture-anthropic-key")
    assert ModelPicker.request_options(model) == [api_key: "fixture-anthropic-key"]
    refute inspect(model) =~ "fixture-anthropic-key"
  end

  test "selects catalog and manual image models and rejects a text model" do
    assert {:ok, %LLMDB.Model{id: "gpt-image-2"}} =
             Source.model(:openai, "gpt-image-2", nil, :image)

    assert {:ok, %LLMDB.Model{id: "my-custom-image-model"}} =
             Source.model(:xai, "my-custom-image-model", nil, :image)

    assert {:error, "Choose a model that supports image generation."} =
             Source.model(:openai, "gpt-4o-mini", nil, :image)
  end
end
