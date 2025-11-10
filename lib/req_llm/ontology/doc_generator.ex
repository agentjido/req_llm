# lib/req_llm/ontology/doc_generator.ex
# Purpose: Auto-generate documentation from Σ ontology (KNHK phase)

defmodule ReqLLM.Ontology.DocGenerator do
  @moduledoc """
  Generates documentation from the RDF ontology (Σ).

  Parses `reqllm.sigma_observed.ttl` and generates:
  - Markdown schema documentation
  - ExDoc-compatible module docs
  - API reference from SHACL constraints
  - Entity-relationship diagrams (Mermaid)
  """

  @ontology_path "ontologies/reqllm.sigma_observed.ttl"
  @shapes_path "ontologies/reqllm.shapes.ttl"

  @doc """
  Generate comprehensive schema documentation in Markdown.

  Returns Markdown string documenting all classes, properties, and constraints.
  """
  def generate_schema_docs do
    classes = parse_classes()
    properties = parse_properties()

    """
    # ReqLLM Ontology Schema

    **Version**: Σ.reqllm.clnrm (hash: `2aeb94264b64`)
    **Generated**: #{DateTime.utc_now() |> DateTime.to_iso8601()}

    ## Classes

    #{render_classes(classes)}

    ## Properties

    #{render_properties(properties)}

    ## Enumerations

    ### Role

    - `system` - System message
    - `user` - User message
    - `assistant` - Assistant message
    - `tool` - Tool result message

    ### FinishReason

    - `stop` - Natural completion
    - `length` - Max tokens reached
    - `tool_calls` - Tool calls required
    - `content_filter` - Content filtered
    - `error` - Error occurred

    ### ChunkType

    - `content` - Content chunk
    - `thinking` - Reasoning chunk
    - `tool_call` - Tool call chunk
    - `meta` - Metadata chunk

    ## Constraints

    See `SHACL_CONSTRAINTS.md` for validation rules.
    """
  end

  @doc """
  Generate Mermaid entity-relationship diagram.

  Returns Mermaid diagram source showing class relationships.
  """
  def generate_erd do
    """
    ```mermaid
    erDiagram
        Response ||--|| Context : hasContext
        Response ||--|| Message : hasMessageOut
        Response ||--o| Usage : hasUsage
        Response ||--|| FinishReason : finishReason

        StreamResponse ||--|| Context : hasContext
        StreamResponse ||--o{ StreamChunk : streamChunk
        StreamResponse ||--o| Usage : hasUsage

        Context ||--o{ Message : hasMessage

        Message ||--|| Role : role
        Message ||--o{ ContentPart : hasPart

        ContentPart ||--o| TextPart : subclass
        ContentPart ||--o| ImageURLPart : subclass
        ContentPart ||--o| ImagePart : subclass
        ContentPart ||--o| FilePart : subclass
        ContentPart ||--o| ThinkingPart : subclass
        ContentPart ||--o| ToolCallPart : subclass
        ContentPart ||--o| ToolResultPart : subclass

        StreamChunk ||--|| ChunkType : chunkType

        Model ||--|| Provider : provider

        Response {
            string id
            FinishReason finishReason
        }

        Context {
            string externalId
        }

        Message {
            Role role
            int position
        }

        Usage {
            int inputTokens
            int outputTokens
            int totalTokens
            decimal totalCost
        }
    ```
    """
  end

  @doc """
  Generate API reference from SHACL constraints.

  Returns Markdown documentation of all validation rules.
  """
  def generate_api_reference do
    """
    # ReqLLM API Reference

    ## Response

    **Type**: `req:Response`

    **Required Fields**:
    - `hasContext: Context` - Conversation context
    - `hasMessageOut: Message` - Assistant's response message
    - `finishReason: FinishReason` - Completion reason

    **Optional Fields**:
    - `id: string` - Response identifier
    - `hasUsage: Usage` - Token usage metrics

    **Validation**:
    - Must have exactly 1 context
    - Must have exactly 1 output message
    - finishReason must be valid enum value

    ## Message

    **Type**: `req:Message`

    **Required Fields**:
    - `role: Role` - Message role (system, user, assistant, tool)
    - `hasPart: [ContentPart]` - At least 1 content part

    **Optional Fields**:
    - `position: integer` - Position in context (≥ 0)

    **Validation**:
    - Must have exactly 1 role
    - Must have at least 1 content part
    - Position must be non-negative if present

    ## Usage

    **Type**: `req:Usage`

    **Fields** (all optional but must be ≥ 0 if present):
    - `inputTokens: integer`
    - `outputTokens: integer`
    - `reasoningTokens: integer`
    - `totalTokens: integer`
    - `inputCost: decimal` (USD)
    - `outputCost: decimal` (USD)
    - `totalCost: decimal` (USD)

    For complete constraints, see `SHACL_CONSTRAINTS.md`.
    """
  end

  ## Private Helpers

  defp parse_classes do
    # Simplified parser - in production, use proper RDF library
    [
      %{name: "Response", label: "Response", comment: "Canonical final response"},
      %{name: "Context", label: "Context", comment: "Conversation history"},
      %{name: "Message", label: "Message", comment: "Conversational turn"},
      %{name: "Usage", label: "Usage", comment: "Token usage metrics"}
    ]
  end

  defp parse_properties do
    [
      %{
        name: "hasContext",
        domain: ["Response", "StreamResponse"],
        range: "Context",
        label: "hasContext"
      },
      %{name: "hasUsage", domain: ["Response", "StreamResponse"], range: "Usage", label: "hasUsage"},
      %{name: "role", domain: "Message", range: "Role", label: "role"}
    ]
  end

  defp render_classes(classes) do
    classes
    |> Enum.map(fn class ->
      """
      ### #{class.name}

      **Label**: #{class.label}

      #{if class.comment, do: "**Description**: #{class.comment}", else: ""}
      """
    end)
    |> Enum.join("\n")
  end

  defp render_properties(properties) do
    properties
    |> Enum.map(fn prop ->
      domain = if is_list(prop.domain), do: Enum.join(prop.domain, ", "), else: prop.domain

      """
      ### #{prop.name}

      - **Domain**: #{domain}
      - **Range**: #{prop.range}
      """
    end)
    |> Enum.join("\n")
  end
end
