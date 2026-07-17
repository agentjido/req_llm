defmodule ReqLLM.Telemetry.RequestSourceTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Telemetry.RequestSource

  test "redacts Google Cloud project identifiers from server paths" do
    request =
      Req.new(
        url:
          "https://us-central1-aiplatform.googleapis.com/v1/projects/private-project/locations/us-central1/publishers/mistralai/models/mistral-ocr-2505:rawPredict"
      )

    assert RequestSource.server(request) == %{
             address: "us-central1-aiplatform.googleapis.com",
             port: 443,
             path:
               "/v1/projects/{project_id}/locations/us-central1/publishers/mistralai/models/mistral-ocr-2505:rawPredict"
           }
  end

  test "preserves static provider paths" do
    request = Req.new(url: "https://api.openai.com/v1/chat/completions")

    assert RequestSource.server(request) == %{
             address: "api.openai.com",
             port: 443,
             path: "/v1/chat/completions"
           }
  end
end
