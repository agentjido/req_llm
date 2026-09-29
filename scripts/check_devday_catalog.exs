[path] = System.argv()
{:ok, _} = LLMDB.load(snapshot_source: {:file, path})
model = ReqLLM.model!("openai:gpt-6.1-sol")

{:ok, request} =
  ReqLLM.Providers.OpenAI.prepare_request(:chat, model, "Check",
    api_key: "test-key",
    reasoning_effort: :low
  )

body = request |> ReqLLM.Providers.OpenAI.encode_body() |> Map.fetch!(:body) |> Jason.decode!()
true = request.url.path == "/responses"
true = body["model"] == "gpt-6.1-sol"
true = model.cost.cache_read == 0.1
IO.puts("Updated catalog model routes to Responses with the verified cache rate")

for variant <- ["flare", "sunburst"], suffix <- ["", "-2026-09-08"], quality <- [:xhigh, :max] do
  image_model = ReqLLM.model!("openai:gpt-image-2.5-#{variant}#{suffix}")

  {:ok, image_request} =
    ReqLLM.Providers.OpenAI.prepare_request(:image, image_model, "A lighthouse",
      api_key: "test-key",
      quality: quality
    )

  true = image_request.url.path == "/images/generations"

  usage =
    ReqLLM.Usage.Normalize.normalize(%{
      input_tokens: 2_000_000,
      output_tokens: 2_000_000,
      total_tokens: 4_000_000,
      input_tokens_details: %{text_tokens: 1_000_000, image_tokens: 1_000_000},
      output_tokens_details: %{text_tokens: 0, image_tokens: 2_000_000}
    })

  {:ok, cost} = ReqLLM.Billing.calculate(usage, image_model)
  true = cost.total == 73.0
end

IO.puts("Image 2.5 alias and dated records prepare Images requests and price modality tokens")
