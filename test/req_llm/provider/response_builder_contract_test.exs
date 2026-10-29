defmodule ReqLLM.Provider.ResponseBuilderContractTest do
  use ExUnit.Case, async: true

  @contracts [
    {ReqLLM.Providers.OpenAI.ResponsesAPI.ResponseBuilder, "OpenAI Responses",
     {:catalog, "openai:gpt-4o"}, :openai, "openai-responses-v1"},
    {ReqLLM.Provider.Defaults.ResponseBuilder, "Amazon Bedrock",
     {:catalog, "amazon-bedrock:anthropic.claude-3-haiku-20240307-v1:0"}, :anthropic,
     "anthropic-thinking-v1"},
    {ReqLLM.Provider.Defaults.ResponseBuilder, "Azure", {:catalog, "azure:gpt-4o"}, :azure,
     "azure-thinking-v1"},
    {ReqLLM.Providers.Anthropic.ResponseBuilder, "Anthropic",
     {:catalog, "anthropic:claude-sonnet-4-20250514"}, :anthropic, "anthropic-thinking-v1"},
    {ReqLLM.Providers.Google.ResponseBuilder, "Google Vertex Gemini",
     {:inline, :google_vertex, "gemini-2.5-pro"}, :google, "google-gemini-v1"}
  ]

  for {builder, label, model_spec, reasoning_provider, reasoning_format} <- @contracts do
    @builder builder
    @model_spec model_spec
    @reasoning_provider reasoning_provider
    @reasoning_format reasoning_format

    test "#{label} follows common reasoning detail rules" do
      model = contract_model(@model_spec)
      context = ReqLLM.Context.new()
      metadata = %{finish_reason: :stop}

      assert {:ok, plain_response} =
               @builder.build_response(
                 [ReqLLM.StreamChunk.text("A plain response")],
                 metadata,
                 context: context,
                 model: model
               )

      assert plain_response.message.reasoning_details == nil

      thinking_metadata = %{
        signature: "contract-signature",
        encrypted?: true,
        provider: @reasoning_provider,
        format: @reasoning_format,
        provider_data: %{"type" => "thinking"}
      }

      chunks = [
        ReqLLM.StreamChunk.thinking("Contract reasoning", thinking_metadata),
        ReqLLM.StreamChunk.text("A reasoned response")
      ]

      assert {:ok, reasoned_response} =
               @builder.build_response(chunks, metadata, context: context, model: model)

      assert [detail] = reasoned_response.message.reasoning_details
      assert detail.text == "Contract reasoning"
      assert detail.signature == "contract-signature"
      assert detail.encrypted? == true
      assert detail.provider == @reasoning_provider
      assert detail.format == @reasoning_format
    end
  end

  defp contract_model({:catalog, model_spec}), do: ReqLLM.model!(model_spec)

  defp contract_model({:inline, provider, id}) do
    %LLMDB.Model{id: id, model: id, provider: provider, capabilities: %{chat: true}}
  end
end
