# tutorial/agents/18_embedding_retrieval.exs
#
# Chapter 19: Embedding-Based Retrieval (RAG)
# Goal: Implement RAG by precomputing embeddings and searching them via a tool.
#
# Run with:
#   mix run tutorial/agents/18_embedding_retrieval.exs

# Ensure dotenvy loads .env file if present
_ = Dotenvy.source(".env")
Logger.configure(level: :warning)

defmodule KnowledgeBase do
  @docs [
    %{
      id: 1,
      text:
        "ReqLLM is an Elixir client library for calling various LLM APIs including Anthropic Claude and OpenAI."
    },
    %{
      id: 2,
      text:
        "Tools in ReqLLM allow the language model to call Elixir functions during conversation."
    },
    %{
      id: 3,
      text:
        "Streaming in ReqLLM enables token-by-token response delivery for better user experience."
    },
    %{
      id: 4,
      text:
        "The Context module manages conversation history including user messages, assistant responses, and tool results."
    },
    %{id: 5, text: "GenServer patterns in OTP make ReqLLM agents stateful and resilient."}
  ]

  def precompute_embeddings(model) do
    IO.puts("   [RAG] Precomputing embeddings for knowledge base...")

    docs_with_embeddings =
      Enum.map(@docs, fn doc ->
        {:ok, embedding} = ReqLLM.embed(model, doc.text)
        Map.put(doc, :embedding, embedding)
      end)

    IO.puts("   [RAG] Ready with #{length(docs_with_embeddings)} documents\n")
    docs_with_embeddings
  end

  def cosine_similarity(v1, v2) do
    dot_product =
      Enum.zip(v1, v2)
      |> Enum.map(fn {a, b} -> a * b end)
      |> Enum.sum()

    mag1 = Enum.map(v1, &(&1 * &1)) |> Enum.sum() |> :math.sqrt()
    mag2 = Enum.map(v2, &(&1 * &1)) |> Enum.sum() |> :math.sqrt()

    dot_product / (mag1 * mag2)
  end
end

defmodule SimpleAgent.WithRAG do
  use GenServer

  import ReqLLM.Context

  alias ReqLLM.{Context, Tool, ToolCall}

  defstruct [:model, :context, :tools, :knowledge_docs]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def ask(pid, text), do: GenServer.call(pid, {:ask, text}, 60_000)

  @impl true
  def init(opts) do
    embedding_model = Keyword.get(opts, :embedding_model, "openai:text-embedding-3-small")
    model = Keyword.fetch!(opts, :model)

    # Precompute embeddings
    knowledge_docs = KnowledgeBase.precompute_embeddings(embedding_model)

    # Create knowledge tool
    knowledge_tool = create_knowledge_tool(embedding_model, knowledge_docs)

    system_prompt = """
    You are a helpful assistant with access to an internal knowledge base.
    Use the 'knowledge' tool when questions are about ReqLLM, tools, streaming, or Elixir agents.
    """

    context = Context.new([system(system_prompt)])

    {:ok,
     %__MODULE__{
       model: model,
       context: context,
       tools: [knowledge_tool],
       knowledge_docs: knowledge_docs
     }}
  end

  defp create_knowledge_tool(model, docs) do
    ReqLLM.Tool.new!(
      name: "knowledge",
      description: "Search the internal knowledge base for relevant information",
      parameter_schema: [
        query: [type: :string, required: true, doc: "Search query"]
      ],
      callback: fn args ->
        query = args[:query] || args["query"]
        IO.puts("   [RAG] Searching for: #{query}")

        {:ok, query_embedding} = ReqLLM.embed(model, query)

        # Find most similar document
        {best_doc, similarity} =
          docs
          |> Enum.map(fn doc ->
            sim = KnowledgeBase.cosine_similarity(query_embedding, doc.embedding)
            {doc, sim}
          end)
          |> Enum.max_by(fn {_doc, sim} -> sim end)

        IO.puts(
          "   [RAG] Best match (similarity: #{Float.round(similarity, 3)}): Doc ##{best_doc.id}"
        )

        {:ok, best_doc.text}
      end
    )
  end

  @impl true
  def handle_call({:ask, user_text}, _from, state) do
    ctx = Context.append(state.context, user(user_text))

    # Simple tool loop (synchronous)
    {:ok, response} = ReqLLM.generate_text(state.model, ctx.messages, tools: state.tools)
    calls = ReqLLM.Response.tool_calls(response)

    ctx2 = Context.append(ctx, response.message)

    ctx3 =
      if calls == [] do
        ctx2
      else
        Enum.reduce(calls, ctx2, fn call, acc_ctx ->
          # Only one tool
          tool = List.first(state.tools)
          args = ToolCall.args_map(call)

          case ReqLLM.Tool.execute(tool, args) do
            {:ok, result} ->
              Context.append(acc_ctx, Context.tool_result(call.id, result))

            {:error, reason} ->
              Context.append(acc_ctx, Context.tool_result(call.id, "Error: #{inspect(reason)}"))
          end
        end)
      end

    {:ok, final_response} = ReqLLM.generate_text(state.model, ctx3.messages, tools: [])
    text = ReqLLM.Response.text(final_response)

    new_ctx = Context.append(ctx3, final_response.message)

    {:reply, {:ok, text}, %{state | context: new_ctx}}
  end
end

# --- MAIN ---
model = System.get_env("REQ_LLM_MODEL", "anthropic:claude-haiku-4.5")
IO.puts("=== Chapter 19: RAG with Embeddings ===\n")

{:ok, pid} = SimpleAgent.WithRAG.start_link(model: model)

IO.puts(">> What are tools in ReqLLM?")
{:ok, ans1} = SimpleAgent.WithRAG.ask(pid, "What are tools in ReqLLM?")
IO.puts("assistant> #{ans1}")

IO.puts("\n>> How does streaming work?")
{:ok, ans2} = SimpleAgent.WithRAG.ask(pid, "How does streaming work?")
IO.puts("assistant> #{ans2}")
