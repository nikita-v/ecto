defmodule Ecto.Query.JoinBuilder do
  @moduledoc false

  alias Ecto.Query.BuilderUtil
  alias Ecto.Query.Query
  alias Ecto.Query.QueryExpr
  alias Ecto.Query.JoinExpr

  @doc """
  Escapes a join expression (not including the `on` expression).

  It returns a tuple containing the binds, the on expression (if available)
  and the association expression.

  ## Examples

      iex> escape(quote(do: x in "foo"), [])
      { :x, "foo", nil }

      iex> escape(quote(do: "foo"), [])
      { nil, "foo", nil }

      iex> escape(quote(do: x in Sample), [])
      { :x, { :__aliases__, [alias: false], [:Sample] }, nil }

      iex> escape(quote(do: c in p.comments), [:p])
      { :c, nil, {{:{}, [], [:&, [], [0]]}, :comments} }

  """
  @spec escape(Macro.t, [atom]) :: { [atom], Macro.t | nil, Macro.t | nil }
  def escape({ :in, _, [{ var, _, context }, expr] }, vars)
      when is_atom(var) and is_atom(context) do
    escape(expr, vars) |> set_elem(0, var)
  end

  def escape({ :in, _, [{ var, _, context }, expr] }, vars)
      when is_atom(var) and is_atom(context) do
    escape(expr, vars) |> set_elem(0, var)
  end

  def escape({ :__aliases__, _, _ } = module, _vars) do
    { nil, module, nil }
  end

  def escape(string, _vars) when is_binary(string) do
    { nil, string, nil }
  end

  def escape(dot, vars) do
    case BuilderUtil.escape_dot(dot, vars) do
      { _, _ } = var_field ->
        { [], nil, var_field }
      :error ->
        raise Ecto.QueryError, reason: "malformed `join` query expression"
    end
  end

  @doc """
  Builds a quoted expression.

  The quoted expression should evaluate to a query at runtime.
  If possible, it does all calculations at compile time to avoid
  runtime work.
  """
  @spec build(Macro.t, atom, [Macro.t], Macro.t, Macro.t, Macro.Env.t) :: Macro.t
  def build(query, qual, binding, expr, on, env) do
    binding = BuilderUtil.escape_binding(binding)
    { join_bind, join_expr, join_assoc } = escape(expr, binding)
    is_assoc? = not nil?(join_assoc)

    validate_qual(qual)
    validate_on(on, is_assoc?)
    validate_bind(join_bind, binding)

    # Define the variable that will be used to calculate the number of binds.
    # If the variable is known at compile time, calculate it now.
    query = Macro.expand(query, env)
    { query, getter, setter } = count_binds(query, is_assoc?)

    join_on = escape_on(on, binding ++ List.wrap(join_bind), { join_bind, getter }, env)
    join =
      quote do
        JoinExpr[qual: unquote(qual), source: unquote(join_expr), on: unquote(join_on),
                 file: unquote(env.file), line: unquote(env.line), assoc: unquote(join_assoc)]
      end

    case query do
      Query[joins: joins] ->
        query.joins(joins ++ [join]) |> BuilderUtil.escape_query
      _ ->
        quote do
          Query[joins: joins] = query = Ecto.Queryable.to_query(unquote(query))
          unquote(setter)
          query.joins(joins ++ [unquote(join)])
        end
    end
  end

  defp escape_on(nil, _binding, _join_var, _env), do: nil
  defp escape_on(on, binding, join_var, env) do
    on = BuilderUtil.escape(on, binding, join_var)
    quote do: QueryExpr[expr: unquote(on), line: unquote(env.line), file: unquote(env.file)]
  end

  defp count_binds(query, is_assoc?) do
    case BuilderUtil.unescape_query(query) do
      # We have the query, calculate the count binds.
      Query[] = unescaped ->
        { unescaped, BuilderUtil.count_binds(unescaped), nil }

      # We don't have the query but we won't use binds anyway.
      _  when is_assoc? ->
        { query, nil, nil }

      # We don't have the query, handle it at runtime.
      _ ->
        { query,
          quote(do: var!(count_binds, Ecto.Query)),
          quote(do: var!(count_binds, Ecto.Query) = BuilderUtil.count_binds(query)) }
    end
  end

  @qualifiers [:inner, :left, :right, :full]

  defp validate_qual(qual) when qual in @qualifiers, do: :ok
  defp validate_qual(_qual) do
    raise Ecto.QueryError,
      reason: "invalid join qualifier, accepted qualifiers are: " <>
              Enum.map_join(@qualifiers, ", ", &"`#{inspect &1}`")
  end

  defp validate_on(nil, false) do
    raise Ecto.QueryError,
      reason: "`join` expression requires explicit `on` " <>
              "expression unless association join expression"
  end
  defp validate_on(_on, _is_assoc?), do: :ok

  defp validate_bind(bind, all) do
    if bind && bind in all do
      raise Ecto.QueryError, reason: "variable `#{bind}` is already defined in query"
    end
  end
end
