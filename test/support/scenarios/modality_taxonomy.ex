defmodule ReqLLM.Test.Scenarios.ModalityTaxonomy do
  @moduledoc """
  ReqLLM v2 scenario and modality coverage taxonomy.

  This module documents the current proof surface for text and non-text
  behavior without changing fixture behavior. Entries marked as fixture-backed
  have replay coverage today. Entries marked as unit-guarded or macro-available
  are visible gaps to promote into fixture-backed scenarios in later epics.
  """

  @registry_areas [
    %{
      id: :core,
      title: "Core text generation",
      operation: :text,
      modality: :text,
      proof: :scenario_registry,
      status: :fixture_backed,
      scenario_ids: [:basic, :usage, :token_limit],
      model_compat_capability: "core",
      test_files: ["test/coverage/*/comprehensive_test.exs"],
      notes: "Basic non-streaming text, usage accounting, and token limits."
    },
    %{
      id: :conversation,
      title: "Conversation continuation",
      operation: :text,
      modality: :text,
      proof: :scenario_registry,
      status: :fixture_backed,
      scenario_ids: [:context_append],
      model_compat_capability: "conversation",
      test_files: ["test/coverage/*/comprehensive_test.exs"],
      notes: "Context append and follow-up message behavior."
    },
    %{
      id: :streaming,
      title: "Text streaming",
      operation: :text,
      modality: :text,
      proof: :scenario_registry,
      status: :fixture_backed,
      scenario_ids: [:streaming],
      model_compat_capability: "streaming",
      test_files: ["test/coverage/*/comprehensive_test.exs"],
      notes: "Stream materialization into a canonical response."
    },
    %{
      id: :tools,
      title: "Function tools",
      operation: :text,
      modality: :tool,
      proof: :scenario_registry,
      status: :fixture_backed,
      scenario_ids: [:tool_none, :tool_multi, :tool_round_trip],
      model_compat_capability: "tools",
      test_files: ["test/coverage/*/comprehensive_test.exs"],
      notes: "Tool avoidance, tool selection, and tool round-trip execution."
    },
    %{
      id: :objects,
      title: "Structured object output",
      operation: :text,
      modality: :structured_output,
      proof: :scenario_registry,
      status: :fixture_backed,
      scenario_ids: [:object_basic, :object_streaming],
      model_compat_capability: "objects",
      test_files: ["test/coverage/*/comprehensive_test.exs"],
      notes: "Non-streaming and streaming object generation."
    },
    %{
      id: :reasoning,
      title: "Reasoning output",
      operation: :text,
      modality: :reasoning,
      proof: :scenario_registry,
      status: :fixture_backed,
      scenario_ids: [:reasoning],
      model_compat_capability: "reasoning",
      test_files: ["test/coverage/*/comprehensive_test.exs"],
      notes: "Thinking/reasoning parts for non-streaming and streaming responses."
    }
  ]

  @focused_areas [
    %{
      id: :embedding,
      title: "Embeddings",
      operation: :embedding,
      modality: :embedding,
      proof: :provider_test_macro,
      status: :fixture_backed,
      scenario_ids: [:embed_basic, :embed_usage, :embed_batch],
      model_compat_capability: "embedding",
      test_files: [
        "test/coverage/amazon_bedrock/embedding_test.exs",
        "test/coverage/azure/embedding_test.exs",
        "test/coverage/google/embedding_test.exs",
        "test/coverage/google_vertex_gemini/embedding_test.exs",
        "test/coverage/openai/embedding_test.exs",
        "test/coverage/openrouter/embedding_test.exs"
      ],
      notes: "Single input, usage-returning input, and batch vector generation."
    },
    %{
      id: :image,
      title: "Image generation",
      operation: :image,
      modality: :image_output,
      proof: :provider_test_macro,
      status: :fixture_backed,
      scenario_ids: [:image_basic],
      model_compat_capability: "image",
      test_files: [
        "test/coverage/google/image_generation_test.exs",
        "test/coverage/openai/image_generation_test.exs",
        "test/coverage/xai/image_generation_test.exs"
      ],
      notes: "Basic generated image response parts; edit/mask variants remain unit-guarded."
    },
    %{
      id: :transcription,
      title: "Audio transcription",
      operation: :transcription,
      modality: :audio_input,
      proof: :provider_test_macro,
      status: :fixture_backed,
      scenario_ids: [:transcription_basic],
      model_compat_capability: "transcription",
      test_files: [
        "test/coverage/groq/transcription_test.exs",
        "test/coverage/openai/transcription_test.exs"
      ],
      notes: "Binary audio input, media type handling, and transcript result shape."
    },
    %{
      id: :speech,
      title: "Speech generation",
      operation: :speech,
      modality: :audio_output,
      proof: :provider_test_macro,
      status: :fixture_backed,
      scenario_ids: [:speech_basic],
      model_compat_capability: "speech",
      test_files: [
        "test/coverage/elevenlabs/speech_test.exs",
        "test/coverage/openai/speech_test.exs"
      ],
      notes: "Generated audio binary, media type, format, and voice options."
    },
    %{
      id: :rerank,
      title: "Rerank",
      operation: :rerank,
      modality: :ranking,
      proof: :provider_test_macro,
      status: :fixture_backed,
      scenario_ids: [:rerank_basic],
      model_compat_capability: "rerank",
      test_files: ["test/coverage/cohere/rerank_test.exs"],
      notes: "Document relevance scores and top-n response shape."
    },
    %{
      id: :ocr,
      title: "OCR",
      operation: :ocr,
      modality: :document_input,
      proof: :provider_test_macro,
      status: :macro_available,
      scenario_ids: [:ocr_basic],
      model_compat_capability: "ocr",
      test_files: [],
      notes: "The provider macro exists; no focused coverage file is currently registered."
    },
    %{
      id: :grounding,
      title: "Google grounding",
      operation: :text,
      modality: :web_tool,
      proof: :focused_fixture,
      status: :fixture_backed,
      scenario_ids: [:grounding_basic, :grounding_with_context, :grounding_streaming],
      model_compat_capability: "grounding",
      test_files: ["test/coverage/google/grounding_test.exs"],
      notes: "Google Search grounding, grounding metadata, and web-search usage cost."
    },
    %{
      id: :grounding_legacy,
      title: "Google legacy grounding",
      operation: :text,
      modality: :web_tool,
      proof: :focused_fixture,
      status: :fixture_backed,
      scenario_ids: [:grounding_legacy],
      model_compat_capability: "grounding_legacy",
      test_files: ["test/coverage/google/grounding_test.exs"],
      notes: "Gemini 1.5 dynamic retrieval compatibility."
    },
    %{
      id: :multimodal_tool_result,
      title: "Multimodal tool result",
      operation: :text,
      modality: :document_input,
      proof: :focused_fixture,
      status: :fixture_backed,
      scenario_ids: [:multimodal_tool_result],
      model_compat_capability: "multimodal_tool_result",
      test_files: ["test/coverage/google/multimodal_tool_result_test.exs"],
      notes: "Tool result content that combines text with PDF/file parts."
    },
    %{
      id: :web_search,
      title: "Web search tools",
      operation: :text,
      modality: :web_tool,
      proof: :focused_fixture,
      status: :fixture_backed,
      scenario_ids: [:web_search_basic, :web_search_streaming, :x_search_streaming],
      model_compat_capability: "web_search",
      test_files: [
        "test/coverage/anthropic/web_search_test.exs",
        "test/coverage/openai/web_search_test.exs",
        "test/coverage/xai/web_search_test.exs"
      ],
      notes: "Provider-native web search, streaming web search, and xAI x_search usage."
    },
    %{
      id: :web_fetch,
      title: "Web fetch tools",
      operation: :text,
      modality: :web_tool,
      proof: :focused_fixture,
      status: :fixture_backed,
      scenario_ids: [:web_fetch_basic],
      model_compat_capability: "web_fetch",
      test_files: ["test/coverage/anthropic/web_fetch_test.exs"],
      notes: "Anthropic URL fetch and response analysis."
    },
    %{
      id: :streaming_structured_output,
      title: "Focused streaming structured output",
      operation: :text,
      modality: :structured_output,
      proof: :focused_fixture,
      status: :fixture_backed,
      scenario_ids: [
        :object_streaming_json_schema,
        :object_streaming_tool_strict,
        :object_streaming_auto,
        :streaming_error_handling
      ],
      model_compat_capability: "streaming_structured_output",
      test_files: [
        "test/coverage/anthropic/streaming_structured_output_test.exs",
        "test/coverage/azure/streaming_structured_output_test.exs",
        "test/coverage/xai/streaming_structured_output_test.exs"
      ],
      notes: "Provider-specific streaming object strategies and error behavior."
    },
    %{
      id: :vision_input,
      title: "Vision input content",
      operation: :text,
      modality: :vision_input,
      proof: :provider_unit,
      status: :unit_guarded,
      scenario_ids: [],
      model_compat_capability: nil,
      test_files: [
        "test/providers/google_test.exs",
        "test/providers/openai_test.exs",
        "test/providers/xai_test.exs",
        "test/req_llm/message/content_part_test.exs"
      ],
      notes: "Image binary, image URL, and mixed text/image message encoding."
    },
    %{
      id: :file_input,
      title: "File and document input",
      operation: :text,
      modality: :document_input,
      proof: :provider_unit,
      status: :mixed_proof,
      scenario_ids: [],
      model_compat_capability: nil,
      test_files: [
        "test/provider/openai/responses_api_unit_test.exs",
        "test/providers/anthropic_test.exs",
        "test/providers/google_test.exs",
        "test/providers/openrouter_test.exs"
      ],
      notes: "File IDs, inline files, PDFs, provider rejection paths, and OpenRouter file-parser."
    },
    %{
      id: :media_url_content,
      title: "Media URL content parts",
      operation: :text,
      modality: :media_url,
      proof: :provider_unit,
      status: :unit_guarded,
      scenario_ids: [],
      model_compat_capability: nil,
      test_files: [
        "test/providers/google_test.exs",
        "test/req_llm/context_test.exs",
        "test/req_llm/message/content_part_test.exs",
        "test/req_llm/provider/defaults_test.exs"
      ],
      notes: "Image URL and video URL content part normalization and provider handling."
    },
    %{
      id: :audio_output_chat,
      title: "Audio-output chat",
      operation: :text,
      modality: :audio_output,
      proof: :provider_unit,
      status: :unit_guarded,
      scenario_ids: [],
      model_compat_capability: nil,
      test_files: ["test/providers/openai_test.exs"],
      notes: "Chat models that request text plus audio and decode audio transcripts."
    }
  ]

  @focused_routes [
    %{
      provider: :amazon_bedrock,
      operation: :embedding,
      scenario_ids: [:embed_basic, :embed_usage, :embed_batch],
      test_file: "test/coverage/amazon_bedrock/embedding_test.exs"
    },
    %{
      provider: :azure,
      operation: :embedding,
      scenario_ids: [:embed_basic, :embed_usage, :embed_batch],
      test_file: "test/coverage/azure/embedding_test.exs"
    },
    %{
      provider: :google,
      operation: :embedding,
      scenario_ids: [:embed_basic, :embed_usage, :embed_batch],
      test_file: "test/coverage/google/embedding_test.exs"
    },
    %{
      provider: :google_vertex,
      operation: :embedding,
      scenario_ids: [:embed_basic, :embed_usage, :embed_batch],
      test_file: "test/coverage/google_vertex_gemini/embedding_test.exs"
    },
    %{
      provider: :openai,
      operation: :embedding,
      scenario_ids: [:embed_basic, :embed_usage, :embed_batch],
      test_file: "test/coverage/openai/embedding_test.exs"
    },
    %{
      provider: :openrouter,
      operation: :embedding,
      scenario_ids: [:embed_basic, :embed_usage, :embed_batch],
      test_file: "test/coverage/openrouter/embedding_test.exs"
    },
    %{
      provider: :google,
      operation: :image,
      scenario_ids: [:image_basic],
      test_file: "test/coverage/google/image_generation_test.exs"
    },
    %{
      provider: :openai,
      operation: :image,
      scenario_ids: [:image_basic],
      test_file: "test/coverage/openai/image_generation_test.exs"
    },
    %{
      provider: :xai,
      operation: :image,
      scenario_ids: [:image_basic],
      test_file: "test/coverage/xai/image_generation_test.exs"
    },
    %{
      provider: :groq,
      operation: :transcription,
      scenario_ids: [:transcription_basic],
      test_file: "test/coverage/groq/transcription_test.exs"
    },
    %{
      provider: :openai,
      operation: :transcription,
      scenario_ids: [:transcription_basic],
      test_file: "test/coverage/openai/transcription_test.exs"
    },
    %{
      provider: :elevenlabs,
      operation: :speech,
      scenario_ids: [:speech_basic],
      test_file: "test/coverage/elevenlabs/speech_test.exs"
    },
    %{
      provider: :openai,
      operation: :speech,
      scenario_ids: [:speech_basic],
      test_file: "test/coverage/openai/speech_test.exs"
    },
    %{
      provider: :cohere,
      operation: :rerank,
      scenario_ids: [:rerank_basic],
      test_file: "test/coverage/cohere/rerank_test.exs"
    },
    %{
      provider: :google,
      operation: :text,
      scenario_ids: [
        :grounding_basic,
        :grounding_with_context,
        :grounding_streaming,
        :grounding_legacy
      ],
      test_file: "test/coverage/google/grounding_test.exs"
    },
    %{
      provider: :google,
      operation: :text,
      scenario_ids: [:multimodal_tool_result],
      test_file: "test/coverage/google/multimodal_tool_result_test.exs"
    },
    %{
      provider: :anthropic,
      operation: :text,
      scenario_ids: [:web_search_basic],
      test_file: "test/coverage/anthropic/web_search_test.exs"
    },
    %{
      provider: :anthropic,
      operation: :text,
      scenario_ids: [:web_fetch_basic],
      test_file: "test/coverage/anthropic/web_fetch_test.exs"
    },
    %{
      provider: :openai,
      operation: :text,
      scenario_ids: [:web_search_basic, :web_search_streaming],
      test_file: "test/coverage/openai/web_search_test.exs"
    },
    %{
      provider: :xai,
      operation: :text,
      scenario_ids: [:web_search_basic, :web_search_streaming, :x_search_streaming],
      test_file: "test/coverage/xai/web_search_test.exs"
    },
    %{
      provider: :anthropic,
      operation: :text,
      scenario_ids: [
        :object_streaming_json_schema,
        :object_streaming_tool_strict,
        :object_streaming_auto,
        :streaming_error_handling
      ],
      test_file: "test/coverage/anthropic/streaming_structured_output_test.exs"
    },
    %{
      provider: :azure,
      operation: :text,
      scenario_ids: [
        :object_streaming_json_schema,
        :object_streaming_tool_strict,
        :object_streaming_auto,
        :streaming_error_handling
      ],
      test_file: "test/coverage/azure/streaming_structured_output_test.exs"
    },
    %{
      provider: :xai,
      operation: :text,
      scenario_ids: [
        :object_streaming_json_schema,
        :object_streaming_tool_strict,
        :object_streaming_auto,
        :streaming_error_handling
      ],
      test_file: "test/coverage/xai/streaming_structured_output_test.exs"
    }
  ]

  @areas @registry_areas ++ @focused_areas

  @spec all() :: [map()]
  def all, do: @areas

  @spec ids() :: [atom()]
  def ids, do: Enum.map(@areas, & &1.id)

  @spec get(atom()) :: {:ok, map()} | :error
  def get(id) when is_atom(id) do
    case Enum.find(@areas, &(&1.id == id)) do
      nil -> :error
      area -> {:ok, area}
    end
  end

  @spec registry_groups() :: %{atom() => [atom()]}
  def registry_groups do
    @registry_areas
    |> Map.new(fn area -> {area.id, area.scenario_ids} end)
  end

  @spec model_compat_areas() :: [map()]
  def model_compat_areas do
    Enum.filter(@areas, &is_binary(&1.model_compat_capability))
  end

  @spec focused_routes() :: [map()]
  def focused_routes, do: @focused_routes

  @spec concrete_test_files() :: [binary()]
  def concrete_test_files do
    @areas
    |> Enum.flat_map(& &1.test_files)
    |> Enum.reject(&String.contains?(&1, "*"))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @spec fixture_backed_ids() :: [atom()]
  def fixture_backed_ids do
    @areas
    |> Enum.filter(&(&1.status == :fixture_backed))
    |> Enum.map(& &1.id)
  end

  @spec gap_ids() :: [atom()]
  def gap_ids do
    @areas
    |> Enum.reject(&(&1.status == :fixture_backed))
    |> Enum.map(& &1.id)
  end
end
