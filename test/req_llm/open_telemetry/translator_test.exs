defmodule ReqLLM.OpenTelemetry.TranslatorTest do
  use ExUnit.Case, async: true

  alias ReqLLM.OpenTelemetry.Translator

  defmodule FakeAdapter do
    @behaviour ReqLLM.OpenTelemetry.Adapter

    @impl true
    def available?, do: true

    @impl true
    def metrics_available?, do: true

    @impl true
    def start_span(_name, attrs, config) do
      send_to(config, {:start_span, attrs})
      :span_handle
    end

    @impl true
    def set_attributes(span, attrs, config) do
      send_to(config, {:set_attributes, span, attrs})
      :ok
    end

    @impl true
    def add_event(span, name, attrs, config) do
      send_to(config, {:add_event, span, name, attrs})
      :ok
    end

    @impl true
    def set_status(span, kind, message, config) do
      send_to(config, {:set_status, span, kind, message})
      :ok
    end

    @impl true
    def end_span(span, config) do
      send_to(config, {:end_span, span})
      :ok
    end

    @impl true
    def record_histogram(record, config) do
      send_to(config, {:record_histogram, record})
      :ok
    end

    defp send_to(config, message) do
      case Keyword.get(config, :test_pid) do
        nil -> :ok
        pid when is_pid(pid) -> send(pid, message)
      end
    end
  end

  defmodule ChildSpanAdapter do
    @behaviour ReqLLM.OpenTelemetry.Adapter

    @impl true
    def available?, do: true

    @impl true
    def start_span(name, attrs, config) do
      send_to(config, {:start_span, name, attrs})
      :span_handle
    end

    @impl true
    def start_child_span(parent, name, attrs, opts, config) do
      send_to(config, {:start_child_span, parent, name, attrs, opts})
      :child_span_handle
    end

    @impl true
    def set_attributes(span, attrs, config) do
      send_to(config, {:set_attributes, span, attrs})
      :ok
    end

    @impl true
    def add_event(span, name, attrs, config) do
      send_to(config, {:add_event, span, name, attrs})
      :ok
    end

    @impl true
    def set_status(span, kind, message, config) do
      send_to(config, {:set_status, span, kind, message})
      :ok
    end

    @impl true
    def end_span(span, config) do
      send_to(config, {:end_span, span})
      :ok
    end

    @impl true
    def end_span_at(span, end_time, config) do
      send_to(config, {:end_span_at, span, end_time})
      :ok
    end

    defp send_to(config, message) do
      case Keyword.get(config, :test_pid) do
        nil -> :ok
        pid when is_pid(pid) -> send(pid, message)
      end
    end
  end

  # Adapter without optional metrics callbacks (record_histogram /
  # metrics_available?). Exercises the translator's defensive guard so a
  # misconfigured `metrics_enabled?: true` doesn't crash with
  # UndefinedFunctionError.
  defmodule MetricsLessAdapter do
    @behaviour ReqLLM.OpenTelemetry.Adapter

    @impl true
    def available?, do: true

    @impl true
    def start_span(_name, _attrs, _config), do: :span_handle

    @impl true
    def set_attributes(_span, _attrs, config) do
      send_to(config, :set_attributes)
      :ok
    end

    @impl true
    def add_event(_span, _name, _attrs, _config), do: :ok

    @impl true
    def set_status(_span, _kind, _message, _config), do: :ok

    @impl true
    def end_span(_span, config) do
      send_to(config, :end_span)
      :ok
    end

    defp send_to(config, message) do
      case Keyword.get(config, :test_pid) do
        nil -> :ok
        pid when is_pid(pid) -> send(pid, message)
      end
    end
  end

  describe "apply_start/3" do
    test "atomizes string-keyed attributes" do
      stub = %{
        name: "chat gpt-5",
        attributes: %{"gen_ai.request.model" => "gpt-5", "server.port" => 443},
        events: []
      }

      assert :span_handle = Translator.apply_start(stub, FakeAdapter, test_pid: self())

      assert_receive {:start_span, attrs}
      assert attrs[:"gen_ai.request.model"] == "gpt-5"
      assert attrs[:"server.port"] == 443
    end

    test "emits any start-time events in list order" do
      stub = %{
        name: "chat gpt-5",
        attributes: %{},
        events: [
          %{name: "early.event", attributes: %{"foo" => "bar"}}
        ]
      }

      Translator.apply_start(stub, FakeAdapter, test_pid: self())

      assert_receive {:start_span, _}
      assert_receive {:add_event, :span_handle, :"early.event", attrs}
      assert attrs[:foo] == "bar"
    end
  end

  describe "apply_terminal/4" do
    test "sets attributes, emits events, applies :ok status without set_status call, ends span" do
      stub = %{
        attributes: %{"gen_ai.usage.input_tokens" => 10},
        status: :ok,
        events: [],
        metrics: []
      }

      Translator.apply_terminal(:span_handle, stub, FakeAdapter, test_pid: self())

      assert_receive {:set_attributes, :span_handle, attrs}
      assert attrs[:"gen_ai.usage.input_tokens"] == 10

      refute_received {:set_status, _, _, _}
      assert_receive {:end_span, :span_handle}
    end

    test "applies {:error, message} status before end_span" do
      stub = %{
        attributes: %{},
        status: {:error, "HTTP 500"},
        events: [],
        metrics: []
      }

      Translator.apply_terminal(:span_handle, stub, FakeAdapter, test_pid: self())

      assert_receive {:set_attributes, _, _}
      assert_receive {:set_status, :span_handle, :error, "HTTP 500"}
      assert_receive {:end_span, :span_handle}
    end

    test "emits events in their list order before status/end_span" do
      stub = %{
        attributes: %{},
        status: {:error, "boom"},
        events: [
          %{name: "exception", attributes: %{"exception.type" => "Foo"}},
          %{name: "gen_ai.client.inference.operation.details", attributes: %{"x" => 1}}
        ],
        metrics: []
      }

      Translator.apply_terminal(:span_handle, stub, FakeAdapter, test_pid: self())

      # Capture events in order
      assert_receive {:add_event, _, :exception, _}
      assert_receive {:add_event, _, :"gen_ai.client.inference.operation.details", _}
      assert_receive {:set_status, _, :error, "boom"}
      assert_receive {:end_span, _}
    end

    test "emits timed child spans before ending the parent span" do
      stub = %{
        attributes: %{},
        status: :ok,
        events: [],
        metrics: [],
        tool_spans: [
          %{
            name: "execute_tool web_search_call",
            kind: :internal,
            status: :ok,
            start_time: 1_000,
            end_time: 2_000,
            attributes: %{
              "gen_ai.operation.name" => "execute_tool",
              "gen_ai.tool.name" => "web_search_call"
            }
          }
        ]
      }

      Translator.apply_terminal(:parent_span, stub, ChildSpanAdapter, test_pid: self())

      assert_receive {:set_attributes, :parent_span, %{}}

      assert_receive {:start_child_span, :parent_span, "execute_tool web_search_call", attrs,
                      opts}

      assert attrs[:"gen_ai.operation.name"] == "execute_tool"
      assert attrs[:"gen_ai.tool.name"] == "web_search_call"
      assert opts == %{kind: :internal, start_time: 1_000}
      refute_received {:set_status, :child_span_handle, _, _}
      assert_receive {:end_span_at, :child_span_handle, 2_000}
      assert_receive {:end_span, :parent_span}
    end

    test "skips metric recording when metrics_enabled? is false" do
      stub = %{
        attributes: %{},
        status: :ok,
        events: [],
        metrics: [
          %{
            name: "gen_ai.client.operation.duration",
            value: 0.5,
            unit: "s",
            description: "",
            boundaries: [],
            attributes: %{}
          }
        ]
      }

      Translator.apply_terminal(:span_handle, stub, FakeAdapter,
        test_pid: self(),
        metrics_enabled?: false
      )

      assert_receive {:end_span, _}
      refute_received {:record_histogram, _}
    end

    test "records each metric when metrics_enabled? is true" do
      stub = %{
        attributes: %{},
        status: :ok,
        events: [],
        metrics: [
          %{
            name: "gen_ai.client.operation.duration",
            value: 0.5,
            unit: "s",
            description: "",
            boundaries: [],
            attributes: %{}
          },
          %{
            name: "gen_ai.client.token.usage",
            value: 100,
            unit: "{token}",
            description: "",
            boundaries: [],
            attributes: %{"gen_ai.token.type" => "input"}
          }
        ]
      }

      Translator.apply_terminal(:span_handle, stub, FakeAdapter,
        test_pid: self(),
        metrics_enabled?: true
      )

      assert_receive {:record_histogram, %{name: "gen_ai.client.operation.duration"}}
      assert_receive {:record_histogram, %{name: "gen_ai.client.token.usage"}}
    end

    test "skips metrics silently when adapter does not export record_histogram even with metrics_enabled?" do
      stub = %{
        attributes: %{},
        status: :ok,
        events: [],
        metrics: [
          %{
            name: "gen_ai.client.operation.duration",
            value: 0.5,
            unit: "s",
            description: "",
            boundaries: [],
            attributes: %{}
          }
        ]
      }

      # Must not raise UndefinedFunctionError even though metrics_enabled?
      # is true on an adapter that does not implement record_histogram.
      :ok =
        Translator.apply_terminal(:span_handle, stub, MetricsLessAdapter,
          test_pid: self(),
          metrics_enabled?: true
        )

      assert_receive :set_attributes
      assert_receive :end_span
    end
  end
end
