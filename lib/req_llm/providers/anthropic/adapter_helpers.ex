defmodule ReqLLM.Providers.Anthropic.AdapterHelpers do
  @moduledoc """
  Shared helper functions for Anthropic model adapters (Bedrock, Vertex).

  These functions are NOT used by the native Anthropic provider - they are
  specific to adapters that wrap Anthropic's API in other platforms.
  """

  @doc """
  Conditionally add a parameter to a map if the value is not nil.
  """
  def maybe_add_param(body, _key, nil), do: body
  def maybe_add_param(body, key, value), do: Map.put(body, key, value)

  @doc """
  Prepare context and options for :object operations using structured output.

  Creates a synthetic "structured_output" tool and forces tool choice to use it.
  This leverages Claude's tool-calling for structured JSON output.
  """
  def prepare_structured_output_context(context, opts) do
    compiled_schema = Keyword.fetch!(opts, :compiled_schema)

    # Create the structured_output tool
    structured_output_tool =
      ReqLLM.Tool.new!(
        name: "structured_output",
        description: "Generate structured output matching the provided schema",
        parameter_schema: compiled_schema.schema,
        callback: fn _args -> {:ok, "structured output generated"} end
      )

    # Add tool to context
    existing_tools = Map.get(context, :tools, [])
    updated_context = Map.put(context, :tools, [structured_output_tool | existing_tools])

    # Update opts to force tool choice
    updated_opts =
      opts
      |> Keyword.put(:tools, [structured_output_tool | Keyword.get(opts, :tools, [])])
      |> Keyword.put(:tool_choice, %{type: "tool", name: "structured_output"})

    {updated_context, updated_opts}
  end

  @doc """
  Add extended thinking configuration to request body if enabled.

  Extended thinking doesn't work when tool_choice forces a specific tool.
  See: https://docs.claude.com/en/docs/build-with-claude/extended-thinking
  """
  def maybe_add_thinking(body, opts) do
    # Check if additional_model_request_fields has thinking config
    thinking_config =
      get_in(opts, [:provider_options, :additional_model_request_fields, :thinking])

    tool_choice = opts[:tool_choice]

    # Extended thinking doesn't work when tool_choice forces a specific tool
    forced_tool_choice? =
      case tool_choice do
        %{type: "tool", name: _} -> true
        %{"type" => "tool", "name" => _} -> true
        _ -> false
      end

    case thinking_config do
      %{type: "enabled", budget_tokens: budget} when not forced_tool_choice? ->
        Map.put(body, :thinking, %{type: "enabled", budget_tokens: budget})

      _ ->
        body
    end
  end

  @doc """
  Extract structured output from tool calls in response.

  Used for :object operations to get the final structured output.
  """
  def extract_and_set_object(response) do
    extracted_object =
      response
      |> ReqLLM.Response.tool_calls()
      |> ReqLLM.ToolCall.find_args("structured_output")

    %{response | object: extracted_object}
  end
end
