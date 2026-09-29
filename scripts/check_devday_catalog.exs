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
