defmodule ReqLLM.GitHooks.BdWrapper do
  @moduledoc """
  Delegates to the original bd/beads git hooks that were present
  before git_hooks installed its own hook scripts.

  This keeps the bd hooks behavior intact while allowing us to add
  additional tasks (e.g. format checks) in a fully Elixir-idiomatic way.

  The backup suffix `.pre_git_hooks_backup` is documented behavior of the
  `git_hooks` package.
  """

  @backup_suffix ".pre_git_hooks_backup"

  @doc """
  Runs the backed-up bd pre-push hook if it exists.
  Called by git_hooks before the format check.
  """
  def pre_push(_args \\ []) do
    run_backup(".git/hooks/pre-push" <> @backup_suffix)
  end

  @doc """
  Runs the backed-up bd pre-commit hook if it exists.
  Called by git_hooks to preserve bd auto-flush behavior.
  """
  def pre_commit(_args \\ []) do
    run_backup(".git/hooks/pre-commit" <> @backup_suffix)
  end

  defp run_backup(path) do
    cond do
      not File.regular?(path) ->
        :ok

      not executable?(path) ->
        IO.warn("bd/beads hook backup exists but is not executable: #{path}")
        :ok

      true ->
        {_, status} = System.cmd(path, [], into: IO.stream(:stdio, :line))

        if status == 0 do
          :ok
        else
          {:error, {:bd_hook_failed, path, status}}
        end
    end
  end

  defp executable?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end
end
