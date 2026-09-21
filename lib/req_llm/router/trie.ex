defmodule ReqLLM.Router.Trie do
  @moduledoc """
  A small guarded trie for router implementations.

  This module is adapted from the Apache-2.0 licensed
  [Jido Signal Router](https://github.com/agentjido/jido_signal). It keeps only
  immutable path lookup, `*` and `**` wildcards, guards, priority, and
  registration-order precedence. Targets and routed values can be any Elixir
  term.

  Guards run after their path matches and receive the value passed to `route/3`.

      trie =
        ReqLLM.Router.Trie.new!([
          {"chat", &(&1[:complexity] == :high), "openai:gpt-4o", 10},
          {"chat", "openai:gpt-4o-mini"},
          {"**", "anthropic:claude-sonnet-4-5", -100}
        ])

      {:ok, targets} = ReqLLM.Router.Trie.route(trie, "chat", %{complexity: :high})
  """

  defmodule Route do
    @moduledoc "A validated guarded trie route."

    @schema Zoi.struct(__MODULE__, %{
              path: Zoi.string() |> Zoi.required(),
              target: Zoi.any() |> Zoi.required(),
              guard: Zoi.any() |> Zoi.default(nil),
              priority: Zoi.integer() |> Zoi.default(0)
            })

    @type t :: unquote(Zoi.type_spec(@schema))

    @enforce_keys Zoi.Struct.enforce_keys(@schema)
    defstruct Zoi.Struct.struct_fields(@schema)

    @doc "Returns the Zoi schema for a route."
    @spec schema() :: Zoi.schema()
    def schema, do: @schema
  end

  @empty_node %{id: 0, exact: %{}, single: nil, multi: nil, terminals: [], globstar?: false}

  @schema Zoi.struct(__MODULE__, %{
            exact: Zoi.map() |> Zoi.default(%{}),
            wildcard: Zoi.any() |> Zoi.default(@empty_node),
            next_order: Zoi.integer() |> Zoi.default(0),
            next_node_id: Zoi.integer() |> Zoi.default(1)
          })

  @type guard :: (term() -> boolean())
  @type route_spec ::
          {String.t(), term()}
          | {String.t(), term(), integer()}
          | {String.t(), guard(), term()}
          | {String.t(), guard(), term(), integer()}
          | Route.t()
  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for a trie."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Builds an immutable trie from route specifications."
  @spec new([route_spec()]) :: {:ok, t()} | {:error, term()}
  def new(routes) when is_list(routes) do
    with {:ok, routes} <- normalize_routes(routes) do
      {:ok, build(routes)}
    end
  end

  def new(routes), do: {:error, invalid_routes("routes must be a list", routes)}

  @doc "Builds an immutable trie and raises when a route is invalid."
  @spec new!([route_spec()]) :: t()
  def new!(routes) do
    case new(routes) do
      {:ok, trie} -> trie
      {:error, error} -> raise ArgumentError, format_error(error)
    end
  end

  @doc "Returns ordered targets whose paths and guards match."
  @spec route(t(), String.t(), term()) :: {:ok, [term()]} | {:error, term()}
  def route(%__MODULE__{} = trie, path, value) when is_binary(path) do
    matches =
      (Map.get(trie.exact, path, []) ++ wildcard_matches(trie.wildcard, path))
      |> Enum.filter(&guard_matches?(&1.route.guard, value))
      |> Enum.sort_by(&precedence_key/1, :desc)
      |> Enum.map(& &1.route.target)

    case matches do
      [] -> {:error, no_match(path)}
      targets -> {:ok, targets}
    end
  end

  def route(%__MODULE__{}, path, _value),
    do: {:error, invalid_routes("route path must be a string", path)}

  defp normalize_routes(routes) do
    routes
    |> Enum.reduce_while({:ok, []}, fn route_spec, {:ok, acc} ->
      case normalize_route(route_spec) do
        {:ok, route} -> {:cont, {:ok, [route | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> reverse_routes()
  end

  defp reverse_routes({:ok, routes}), do: {:ok, Enum.reverse(routes)}
  defp reverse_routes({:error, _reason} = error), do: error

  defp normalize_route(%Route{} = route), do: validate_route(route)

  defp normalize_route({path, target}) when is_binary(path),
    do: validate_route(%Route{path: path, target: target})

  defp normalize_route({path, target, priority})
       when is_binary(path) and is_integer(priority),
       do: validate_route(%Route{path: path, target: target, priority: priority})

  defp normalize_route({path, guard, target}) when is_binary(path) and is_function(guard, 1),
    do: validate_route(%Route{path: path, guard: guard, target: target})

  defp normalize_route({path, guard, target, priority})
       when is_binary(path) and is_function(guard, 1) and is_integer(priority),
       do: validate_route(%Route{path: path, guard: guard, target: target, priority: priority})

  defp normalize_route(route), do: {:error, invalid_routes("invalid route specification", route)}

  defp validate_route(route) do
    with {:ok, route} <- parse_route(route),
         :ok <- validate_path(route.path),
         :ok <- validate_guard(route.guard),
         :ok <- validate_priority(route.priority) do
      {:ok, route}
    end
  end

  defp parse_route(route) do
    case Zoi.parse(Route.schema(), route) do
      {:ok, route} -> {:ok, route}
      {:error, errors} -> {:error, invalid_routes("invalid route", errors)}
    end
  end

  defp validate_path(path) do
    segments = String.split(path, ".")

    cond do
      path == "" ->
        {:error, invalid_routes("route path cannot be empty", path)}

      String.contains?(path, "..") ->
        {:error, invalid_routes("route path cannot contain consecutive dots", path)}

      consecutive_globstars?(segments) ->
        {:error, invalid_routes("route path cannot contain consecutive ** segments", path)}

      invalid = Enum.find(segments, &(not valid_segment?(&1))) ->
        {:error, invalid_routes("invalid route path segment", invalid)}

      true ->
        :ok
    end
  end

  defp consecutive_globstars?(["**", "**" | _rest]), do: true
  defp consecutive_globstars?([_segment | rest]), do: consecutive_globstars?(rest)
  defp consecutive_globstars?([]), do: false

  defp valid_segment?("*"), do: true
  defp valid_segment?("**"), do: true
  defp valid_segment?(segment), do: String.match?(segment, ~r/^[a-zA-Z0-9_-]+$/)

  defp validate_guard(nil), do: :ok
  defp validate_guard(guard) when is_function(guard, 1), do: :ok

  defp validate_guard(guard),
    do: {:error, invalid_routes("route guard must have arity one", guard)}

  defp validate_priority(priority) when priority in -100..100, do: :ok

  defp validate_priority(priority),
    do: {:error, invalid_routes("route priority must be between -100 and 100", priority)}

  defp build(routes) do
    {entries, next_order} = compile_entries(routes)
    trie = %__MODULE__{next_order: next_order}

    {exact, wildcard, next_node_id} =
      Enum.reduce(entries, {trie.exact, trie.wildcard, trie.next_node_id}, fn entry,
                                                                              {exact, wildcard,
                                                                               node_id} ->
        if entry.class == 2 do
          {Map.update(exact, entry.route.path, [entry], &[entry | &1]), wildcard, node_id}
        else
          {wildcard, node_id} = insert(wildcard, entry.segments, entry, node_id)
          {exact, wildcard, node_id}
        end
      end)

    %{trie | exact: exact, wildcard: wildcard, next_node_id: next_node_id}
  end

  defp compile_entries(routes) do
    Enum.map_reduce(routes, 0, fn route, order ->
      segments = String.split(route.path, ".")

      entry = %{
        route: route,
        segments: segments,
        class: pattern_class(segments),
        complexity: pattern_complexity(segments),
        order: order
      }

      {entry, order + 1}
    end)
  end

  defp insert(node, [], entry, next_node_id),
    do: {%{node | terminals: [entry | node.terminals]}, next_node_id}

  defp insert(node, [segment | rest], entry, next_node_id) do
    {child, next_node_id} = child(node, segment, next_node_id)
    {child, next_node_id} = insert(child, rest, entry, next_node_id)
    {put_child(node, segment, child), next_node_id}
  end

  defp child(node, "*", next_node_id), do: existing_node(node.single, next_node_id, false)
  defp child(node, "**", next_node_id), do: existing_node(node.multi, next_node_id, true)

  defp child(node, segment, next_node_id),
    do: existing_node(Map.get(node.exact, segment), next_node_id, false)

  defp existing_node(nil, next_node_id, globstar?) do
    {%{
       id: next_node_id,
       exact: %{},
       single: nil,
       multi: nil,
       terminals: [],
       globstar?: globstar?
     }, next_node_id + 1}
  end

  defp existing_node(node, next_node_id, _globstar?), do: {node, next_node_id}

  defp put_child(node, "*", child), do: %{node | single: child}
  defp put_child(node, "**", child), do: %{node | multi: child}
  defp put_child(node, segment, child), do: %{node | exact: Map.put(node.exact, segment, child)}

  defp wildcard_matches(node, path) do
    segments = path |> String.split(".") |> List.to_tuple()
    {_visited, matches} = walk(node, segments, tuple_size(segments), 0, %{}, [])
    matches
  end

  defp walk(node, segments, segment_count, position, visited, matches) do
    state = {node.id, position}

    if Map.has_key?(visited, state) do
      {visited, matches}
    else
      visited = Map.put(visited, state, true)
      matches = if position == segment_count, do: node.terminals ++ matches, else: matches

      {visited, matches} =
        walk_segment_children(node, segments, segment_count, position, visited, matches)

      {visited, matches} =
        case node.multi do
          nil -> {visited, matches}
          child -> walk(child, segments, segment_count, position, visited, matches)
        end

      if node.globstar? and position < segment_count do
        walk(node, segments, segment_count, position + 1, visited, matches)
      else
        {visited, matches}
      end
    end
  end

  defp walk_segment_children(node, segments, segment_count, position, visited, matches)
       when position < segment_count do
    segment = elem(segments, position)

    {visited, matches} =
      case Map.get(node.exact, segment) do
        nil -> {visited, matches}
        child -> walk(child, segments, segment_count, position + 1, visited, matches)
      end

    case node.single do
      nil -> {visited, matches}
      child -> walk(child, segments, segment_count, position + 1, visited, matches)
    end
  end

  defp walk_segment_children(_node, _segments, _segment_count, _position, visited, matches),
    do: {visited, matches}

  defp guard_matches?(nil, _value), do: true

  defp guard_matches?(guard, value) do
    guard.(value) == true
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  defp pattern_class(segments) do
    cond do
      "**" in segments -> 0
      "*" in segments -> 1
      true -> 2
    end
  end

  defp pattern_complexity(segments) do
    length = length(segments)
    pattern_complexity(segments, length, 0, length * 2000)
  end

  defp pattern_complexity([], _length, _index, score), do: score

  defp pattern_complexity(["*" | rest], length, index, score),
    do: pattern_complexity(rest, length, index + 1, score - 1000 + index * 100)

  defp pattern_complexity(["**" | rest], length, index, score),
    do: pattern_complexity(rest, length, index + 1, score - 2000 + index * 200)

  defp pattern_complexity([_segment | rest], length, index, score),
    do: pattern_complexity(rest, length, index + 1, score + 3000 * (length - index))

  defp precedence_key(entry),
    do: {entry.complexity, entry.route.priority, -entry.order}

  defp no_match(path) do
    ReqLLM.Error.validation_error(:router_no_match, "no router route matched", path: path)
  end

  defp invalid_routes(reason, value) do
    ReqLLM.Error.validation_error(:invalid_router_routes, reason, value: value)
  end

  defp format_error(error) when is_exception(error), do: Exception.message(error)
  defp format_error(error), do: inspect(error)
end
