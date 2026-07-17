defmodule ReqLLM.ProviderFileReferenceTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Error.Invalid.ProviderFileReference
  alias ReqLLM.Message.ContentPart

  @moduletag contract: :public_api

  test "accepts matching active references and every legacy unowned reference" do
    owned =
      ContentPart.owned_file_id("file-secret", :openai, expires_at: ~U[2030-01-01 00:00:00Z])

    context = context([ContentPart.file_id("legacy-file"), owned])

    assert :ok =
             ReqLLM.ProviderFileReference.validate_context(context, :openai,
               now: ~U[2029-01-01 00:00:00Z]
             )
  end

  test "returns a redacted typed error for a foreign provider before request work" do
    context = context([ContentPart.owned_file_id("file-secret", :anthropic)])

    assert {:error,
            %ProviderFileReference{
              reason: :provider_mismatch,
              owner: "anthropic",
              provider: "openai"
            } = error} =
             ReqLLM.ProviderFileReference.validate_context(context, :openai)

    refute Exception.message(error) =~ "file-secret"
  end

  test "returns a redacted typed error for a known expired reference" do
    context =
      context([
        ContentPart.owned_file_id("file-secret", :openai,
          status: :processed,
          expires_at: ~U[2028-01-01 00:00:00Z]
        )
      ])

    assert {:error,
            %ProviderFileReference{
              reason: :expired,
              owner: "openai",
              provider: "openai",
              expires_at: "2028-01-01T00:00:00Z",
              status: "processed"
            } = error} =
             ReqLLM.ProviderFileReference.validate_context(context, :openai,
               now: ~U[2029-01-01 00:00:00Z]
             )

    refute Exception.message(error) =~ "file-secret"
  end

  test "generation and streaming reject explicit foreign ownership without I/O" do
    context = context([ContentPart.owned_file_id("file-secret", :anthropic)])

    assert {:error, %ProviderFileReference{reason: :provider_mismatch}} =
             ReqLLM.generate_text("openai:gpt-4o", context)

    assert {:error, %ProviderFileReference{reason: :provider_mismatch}} =
             ReqLLM.stream_text("openai:gpt-4o", context)
  end

  test "telemetry sanitization redacts owned references without changing legacy values" do
    owned =
      ContentPart.owned_file_id("file-secret", :openai,
        provider_metadata: %{
          url: "https://example.com/private",
          credential: "credential-secret"
        }
      )

    sanitized_owned = ReqLLM.ProviderFileReference.sanitize_content_part(owned)
    encoded_owned = Jason.encode!(sanitized_owned)

    assert sanitized_owned.file_id == "[REDACTED]"
    refute encoded_owned =~ "file-secret"
    refute encoded_owned =~ "example.com"
    refute encoded_owned =~ "credential-secret"

    legacy = ContentPart.file_id("file-legacy")
    sanitized_legacy = ReqLLM.ProviderFileReference.sanitize_content_part(legacy)

    assert sanitized_legacy.file_id == "file-legacy"
    assert sanitized_legacy.metadata == %{}
  end

  defp context(parts), do: ReqLLM.Context.new([ReqLLM.Context.user(parts)])
end
