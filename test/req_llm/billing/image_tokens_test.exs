defmodule ReqLLM.ImageTokenBillingTest do
  use ExUnit.Case, async: true

  alias ReqLLM.{Billing, Context, Usage}
  alias ReqLLM.Providers.OpenAI.ImagesAPI

  test "buffered Images preserves modality details through normalization and billing" do
    req =
      Req.new(url: "/images/generations")
      |> Req.Request.register_options([:model, :output_format, :context])
      |> Req.Request.merge_options(
        model: "gpt-image-2.5-flare",
        output_format: :png,
        context: Context.new([])
      )

    body = %{
      "created" => 1,
      "data" => [%{"b64_json" => Base.encode64("image")}],
      "usage" => wire_usage()
    }

    {_, decoded} = ImagesAPI.decode_response({req, Req.Response.new(status: 200, body: body)})
    usage = Usage.Normalize.normalize(decoded.body.usage)
    assert usage["input_tokens_details"] == wire_usage()["input_tokens_details"]
    assert usage["output_tokens_details"] == wire_usage()["output_tokens_details"]
    assert {:ok, cost} = Billing.calculate(usage, model())
    assert cost.input_cost == 13.0
    assert cost.output_cost == 60.0
    assert cost.total == 73.0
    assert cost.images == 0.0
    priced = Usage.Cost.apply(usage, model())
    assert priced.pricing == %{status: :priced, currency: "USD", total: 73.0}
  end

  test "streamed Images completion keeps the same modality counts and price" do
    event = %{
      data: %{
        "type" => "image_generation.completed",
        "b64_json" => Base.encode64("image"),
        "usage" => wire_usage()
      }
    }

    chunks = ImagesAPI.decode_stream_event(event, model())
    usage = Enum.find_value(chunks, & &1.metadata[:usage]) |> Usage.Normalize.normalize()
    assert {:ok, cost} = Billing.calculate(usage, model())
    assert cost.total == 73.0
  end

  test "image-only models use aggregate output when optional output details are absent" do
    usage = wire_usage() |> Map.delete("output_tokens_details") |> Usage.Normalize.normalize()
    assert {:ok, %{total: 73.0}} = Billing.calculate(usage, model())
  end

  test "missing, inconsistent, or invalid modality usage remains unknown" do
    for usage <- [
          Map.delete(wire_usage(), "input_tokens_details"),
          Map.delete(wire_usage(), "input_tokens"),
          Map.delete(wire_usage(), "output_tokens"),
          Map.put(wire_usage(), "total_tokens", 1),
          Map.put(wire_usage(), "input_tokens_details", %{"text_tokens" => 1, "image_tokens" => 1}),
          Map.put(wire_usage(), "input_tokens_details", %{
            "text_tokens" => -1,
            "image_tokens" => 2_000_001
          }),
          Map.put(wire_usage(), "output_tokens_details", "invalid"),
          Map.put(wire_usage(), "output_tokens_details", %{
            "text_tokens" => 1,
            "image_tokens" => 1_999_999
          }),
          Map.put(wire_usage(), "input_tokens_details", %{
            "text_tokens" => 1_000_000,
            "image_tokens" => 1_000_000,
            "cached_tokens" => 100
          })
        ] do
      usage = Usage.Normalize.normalize(usage)
      assert {:ok, nil} = Billing.calculate(usage, model())
      assert Usage.Cost.apply(usage, model()).pricing == %{status: :unknown}
    end
  end

  test "partial rates and mixed aggregate rates cannot yield a partial or duplicate bill" do
    model = model()
    usage = Usage.Normalize.normalize(wire_usage())

    partial = %{
      model
      | pricing: %{
          model.pricing
          | components: Enum.reject(model.pricing.components, &(&1.meter == "image_input_tokens"))
        }
    }

    assert {:ok, nil} = Billing.calculate(usage, partial)
    extra = %{id: "token.input", kind: "token", meter: "input_tokens", per: 1_000_000, rate: 5.0}
    mixed = %{model | pricing: %{model.pricing | components: [extra | model.pricing.components]}}
    assert {:ok, nil} = Billing.calculate(usage, mixed)
  end

  defp wire_usage do
    %{
      "input_tokens" => 2_000_000,
      "output_tokens" => 2_000_000,
      "total_tokens" => 4_000_000,
      "input_tokens_details" => %{"text_tokens" => 1_000_000, "image_tokens" => 1_000_000},
      "output_tokens_details" => %{"text_tokens" => 0, "image_tokens" => 2_000_000}
    }
  end

  defp model do
    rates = [
      {"text_input_tokens", 5.0},
      {"image_input_tokens", 8.0},
      {"text_cache_read_tokens", 1.25},
      {"image_cache_read_tokens", 2.0},
      {"image_output_tokens", 30.0}
    ]

    %LLMDB.Model{
      provider: :openai,
      id: "gpt-image-2.5-flare",
      modalities: %{input: [:text, :image], output: [:image]},
      pricing: %{
        currency: "USD",
        components:
          Enum.map(rates, fn {meter, rate} ->
            %{id: "token.#{meter}", kind: "token", meter: meter, per: 1_000_000, rate: rate}
          end)
      }
    }
  end
end
