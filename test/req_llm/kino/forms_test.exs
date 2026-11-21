defmodule ReqLLM.Kino.FormsTest do
  use ExUnit.Case, async: false

  import Kino.Test

  alias ReqLLM.Kino, as: Notebook
  alias ReqLLM.Kino.{Comparison, Image, ModelPicker, Prompt}
  alias ReqLLM.Response

  @http_options [req_http_options: [plug: {Req.Test, __MODULE__}]]
  @jpeg <<0xFF, 0xD8, 0xFF, 0xD9>>

  setup_all do
    {:ok, started} = Application.ensure_all_started(:kino)
    if :kino in started, do: on_exit(fn -> Application.stop(:kino) end)
    :ok
  end

  setup :configure_livebook_bridge
  setup :set_req_test_to_shared

  defp set_req_test_to_shared(context), do: Req.Test.set_req_test_to_shared(context)

  test "a prompt sends only on submit and keeps the text response available" do
    owner = self()
    env_key = "LB_OPENAI_API_KEY"
    prior_key = System.get_env(env_key)
    System.put_env(env_key, "fixture-openai-key")

    on_exit(fn ->
      if prior_key, do: System.put_env(env_key, prior_key), else: System.delete_env(env_key)
    end)

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      auth = Plug.Conn.get_req_header(conn, "authorization")
      send(owner, {:request, self(), auth, Jason.decode!(body)})

      receive do
        :complete_fixture -> :ok
      after
        1_000 -> flunk("The test did not release the request.")
      end

      completion(conn, "Fixture answer")
    end)

    form = Prompt.new("openai:gpt-4o-mini", request_options: @http_options)
    {control, ref} = render_form(form)
    assert Notebook.result(form) == :idle

    push(control, :change, %{prompt: "What is Livebook?"})
    refute_receive {:request, _, _, _}, 50
    push(control, :submit, %{prompt: "   "})
    assert_output(%{ref: ^ref, update: {:replace, [%{text: "Enter a prompt."}]}})
    assert eventually(fn -> Notebook.result(form) == {:error, "Enter a prompt."} end)
    refute_received {:request, _, _, _}

    push(control, :submit, %{prompt: "What is Livebook?", system: "Answer in one sentence."})

    assert_receive {:request, worker, ["Bearer fixture-openai-key"],
                    %{
                      "input" => [
                        %{
                          "role" => "system",
                          "content" => [%{"text" => "Answer in one sentence."}]
                        },
                        %{"role" => "user", "content" => [%{"text" => "What is Livebook?"}]}
                      ]
                    }},
                   1000

    assert_output(%{ref: ^ref, update: {:replace, [%{text: text}]}}, 1000)
    assert text == "Request in progress."
    assert Notebook.result(form) == :running
    push(control, :submit, %{prompt: "Duplicate click"})
    refute_receive {:request, _, _, _}, 50
    send(worker, :complete_fixture)
    assert_output(%{ref: ^ref, update: {:replace, [%{text: text}]}}, 1000)
    assert text =~ "Fixture answer"
    assert text =~ "Tokens: 7"
    refute text =~ "fixture-openai-key"
    assert eventually(fn -> match?({:ok, %Response{}}, Notebook.result(form)) end)
    assert {:ok, response} = Notebook.result(form)
    assert Response.text(response) == "Fixture answer"
  end

  test "an image form uses the image endpoint and the returned MIME type" do
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(owner, {conn.request_path, Jason.decode!(body)})
      Req.Test.json(conn, %{"created" => 1, "data" => [%{"b64_json" => Base.encode64(@jpeg)}]})
    end)

    form =
      Image.new("openai:gpt-image-2",
        request_options: [output_format: :jpeg] ++ @http_options
      )

    {control, ref} = render_form(form)
    assert control.attrs.submit == "Generate"
    assert Keyword.has_key?(control.attrs.fields, :aspect_ratio)
    assert Notebook.result(form) == :idle
    push(control, :submit, %{prompt: "A blue cube", aspect_ratio: " 1:1 "})

    assert_receive {"/v1/images/generations",
                    %{
                      "model" => "gpt-image-2",
                      "output_format" => "jpeg",
                      "prompt" => "A blue cube",
                      "size" => "1024x1024"
                    }}

    assert_output(
      %{
        ref: ^ref,
        update: {:replace, [%{type: :grid, outputs: [%{type: :image, mime_type: "image/jpeg"}]}]}
      },
      1000
    )

    assert eventually(fn -> match?({:ok, %Response{}}, Notebook.result(form)) end)
    assert {:ok, response} = Notebook.result(form)
    assert Response.image_data(response) == @jpeg
  end

  test "a comparison preserves order and displays an error beside a successful reply" do
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      %{"model" => model, "input" => input} = Jason.decode!(body)
      send(owner, {model, input})

      case model do
        "gpt-4o-mini" -> completion(conn, "Fixture answer")
        "gpt-4.1-mini" -> Plug.Conn.send_resp(conn, 401, "fixture-private-error-body")
      end
    end)

    form =
      Comparison.new(["openai:gpt-4.1-mini", "openai:gpt-4o-mini"],
        request_options: @http_options
      )

    {control, ref} = render_form(form)
    assert control.attrs.submit == "Run 2 requests"
    push(control, :submit, %{prompt: "Compare this"})

    for model <- ["gpt-4.1-mini", "gpt-4o-mini"] do
      assert_receive {^model, [%{"role" => "user", "content" => [%{"text" => "Compare this"}]}]},
                     1000
    end

    assert_output(
      %{
        ref: ^ref,
        update:
          {:replace, [%{type: :grid, columns: 2, outputs: [%{text: failure}, %{text: success}]}]}
      },
      1000
    )

    assert failure =~ "Request failed"
    refute failure =~ "fixture-private-error-body"
    assert success =~ "Fixture answer"
    assert success =~ "Time:"
    assert success =~ "Tokens: 7"
    assert success =~ "Cost: $"
    assert eventually(fn -> match?({:ok, [_, _]}, Notebook.result(form)) end)

    assert {:ok,
            [
              %{model: %{id: "gpt-4.1-mini"}, elapsed_ms: failed_ms, result: {:error, _}},
              %{
                model: %{id: "gpt-4o-mini"},
                elapsed_ms: successful_ms,
                result: {:ok, %Response{}}
              }
            ]} = Notebook.result(form)

    assert failed_ms >= 0 and successful_ms >= 0
  end

  test "the picker lists image models separately from text models" do
    provider_input = ModelPicker.provider_input(operation: :image)
    assert {:google, "Google"} in provider_input.attrs.options
    refute List.keymember?(provider_input.attrs.options, :lmstudio, 0)

    picker = ModelPicker.new(:openai, operation: :image)
    [model_input, _manual_input] = ModelPicker.view(picker).items
    assert List.keymember?(model_input.attrs.options, "gpt-image-2", 0)
    refute List.keymember?(model_input.attrs.options, "gpt-4o-mini", 0)
  end

  defp render_form(form) do
    view = Notebook.view(form)
    [_, control, frame] = view.items
    Kino.render(view)

    assert eventually(fn ->
             Kino.SubscriptionManager
             |> :sys.get_state()
             |> Map.fetch!(:topic_with_subscribers)
             |> Map.has_key?(control.ref)
           end)

    {control, frame.ref}
  end

  defp push(control, type, data) do
    send(control.destination, {:event, control.ref, %{origin: "test", type: type, data: data}})
  end

  defp completion(conn, text) do
    Req.Test.json(conn, %{
      "id" => "fixture",
      "object" => "response",
      "model" => "gpt-4o-mini",
      "status" => "completed",
      "output_text" => text,
      "usage" => %{"input_tokens" => 5, "output_tokens" => 2, "total_tokens" => 7}
    })
  end

  defp eventually(check, attempts \\ 100)
  defp eventually(check, 0), do: check.()

  defp eventually(check, attempts) do
    if check.() do
      true
    else
      Process.sleep(10)
      eventually(check, attempts - 1)
    end
  end
end
