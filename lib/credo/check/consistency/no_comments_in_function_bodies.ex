defmodule Credo.Check.Consistency.NoCommentsInFunctionBodies do
  @moduledoc """
  A Credo check that ensures no comments appear inside function/def bodies.

  This check enforces the project convention that function bodies should be
  self-explanatory through clear naming and structure, with no inline comments.
  """

  use Credo.Check, category: :consistency, exit_status: 2

  @doc false
  def run(source_file, params \\ []) do
    issue_meta = IssueMeta.for(source_file, params)

    source_file
    |> SourceFile.source()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> find_comments_in_functions(issue_meta)
  end

  defp find_comments_in_functions(lines_with_numbers, issue_meta) do
    lines_with_numbers
    |> detect_function_ranges()
    |> find_comments_in_ranges(lines_with_numbers, issue_meta)
  end

  defp detect_function_ranges(lines_with_numbers) do
    lines_with_numbers
    |> Enum.reduce({[], nil}, fn {line, line_no}, {ranges, current_function} ->
      cond do
        String.match?(line, ~r/^\s*(def|defp)\s/) ->
          {ranges, {line_no, nil}}

        String.match?(line, ~r/^\s*end\s*$/) and current_function ->
          {start_line, _} = current_function
          {[{start_line, line_no} | ranges], nil}

        true ->
          {ranges, current_function}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp find_comments_in_ranges(function_ranges, lines_with_numbers, issue_meta) do
    lines_with_numbers
    |> Enum.filter(fn {line, line_no} ->
      String.contains?(line, "#") and
        not String.match?(line, ~r/^\s*@/) and
        not String.match?(line, ~r/^\s*defmodule/) and
        not String.contains?(line, "credo:") and
        is_in_function?(line_no, function_ranges)
    end)
    |> Enum.map(fn {line, line_no} ->
      comment_text =
        line
        |> String.split("#", parts: 2)
        |> List.last()
        |> String.trim()

      format_issue(
        issue_meta,
        message: message_for(comment_text),
        line_no: line_no
      )
    end)
  end

  defp is_in_function?(line_no, function_ranges) do
    Enum.any?(function_ranges, fn {start_line, end_line} ->
      line_no > start_line and line_no < end_line
    end)
  end

  defp message_for(comment_text) do
    "Inline comment found: `# #{comment_text}`. " <>
      "Per project conventions, function bodies should be self-explanatory without comments."
  end
end
