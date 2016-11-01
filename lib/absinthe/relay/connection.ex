defmodule Absinthe.Relay.Connection.Options do
  @moduledoc false

  @typedoc false
  @type t :: %{after: nil | integer, before: nil | integer, first: nil | integer, last: nil | integer}

  defstruct after: nil, before: nil, first: nil, last: nil
end

defmodule Absinthe.Relay.Connection do
  @moduledoc """
  Support for paginated result sets.

  Define connection types that provide a standard mechanism for slicing and
  paginating result sets.

  For information about the connection model, see the Relay Cursor Connections Specification
  at https://facebook.github.io/relay/graphql/connections.htm.

  ## Connection

  Given an object type, eg:

  ```
  object :pet do
    field :name, :string
  end
  ```

  You can create a connection type to paginate them by:

  ```
  connection node_type: :pet
  ```

  This will automatically define two new types: `:pet_connection` and `:pet_edge`.

  We define a field that uses these types to paginate associated records
  by using `connection field`. Here, for instance, we support paginating a
  person's pets:

  ```
  object :person do
    field :first_name, :string
    connection field :pets, node_type: :pet do
      resolve fn
        pagination_args, %{source: person} ->
          connection = Absinthe.Relay.Connection.from_list(
            Enum.map(person.pet_ids, &pet_from_id(&1)),
            pagination_args
          )
          {:ok, connection}
        end
      end
    end
  end
  ```

  The `:pets` field is automatically set to return a `:pet_connection` type,
  and configured to accept the standard pagination arguments `after`, `before`,
  `first`, and `last`. We create the connection by using
  `Absinthe.Relay.Connection.from_list/2`, which takes a list and the pagination
  arguments passed to the resolver.

  Note: `Absinthe.Relay.Connection.from_list/2`, like `connectionFromArray` in
  the JS implementation, expects that the full list of records be materialized
  and provided -- it just discards what it doesn't need. Planned for future
  development is an implementation more like
  `connectionFromArraySlice`, intended for use in cases where you know
  the cardinality of the connection, consider it too large to
  materialize the entire array, and instead wish pass in a slice of
  the total result large enough to cover the range specified in the
  pagination arguments.

  Here's how you might request the names of the first `$petCount` pets a person
  owns:

  ```
  query FindPets($personId: ID!, $petCount: Int!) {
    person(id: $personId) {
      pets(first: $petCount) {
        pageInfo {
          hasPreviousPage
          hasNextPage
        }
        edges {
          node {
            name
          }
        }
      }
    }
  }
  ```

  `edges` here is the list of intermediary edge types (created for you
  automatically) that contain a field, `node`, that is the same `:node_type` you
  passed earlier (`:pet`).

  `pageInfo` is a field that contains information about the current view; the `startCursor`,
  `endCursor`, `hasPreviousPage`, and `hasNextPage` fields.

  ### Customizing Types

  If you'd like to add additional fields to the generated connection and edge
  types, you can do that by providing a block to the `connection` macro, eg,
  here we add a field, `:twice_edges_count` to the connection type, and another,
  `:node_name_backwards`, to the edge type:

  ```
  connection node_type: :pet do
    field :twice_edges_count, :integer do
      resolve fn
        _, %{source: conn} ->
          {:ok, length(conn.edges) * 2}
      end
    end
    edge do
      field :node_name_backwards, :string do
      resolve fn
        _, %{source: edge} ->
          {:ok, edge.node.name |> String.reverse}
        end
      end
    end
  end
  ```

  Just remember that if you use the block form of `connection`, you must call
  the `edge` macro within the block.

  ## Creating Connections

  This module provides two functions that mirror similar Javascript functions,
  `from_list/2,3` and `from_slice/2,3`. We also provide `from_query/2,3` if you
  have Ecto as a dependency for convenience.

  Use `from_list` when you have all items in a list that you're going to
  paginate over.

  Use `from_slice` when you have items for a particular request, and merely need
  a connection produced from these items.

  ## Schema Macros

  For more details on connection-related macros, see
  `Absinthe.Relay.Connection.Notation`.
  """

  alias Absinthe.Relay.Connection.Options

  @cursor_prefix "arrayconnection:"

  @type t :: %{
    edges: [edge],
    page_info: page_info
  }

  @typedoc """
  An opaque pagination cursor

  Internally it has the base64 encoded structure:

  ```
  #{@cursor_prefix}:$offset
  ```
  """
  @type cursor :: binary

  @type edge :: %{
    node: term,
    cursor: cursor
  }

  @typedoc """
  Offset from zero.

  Negative offsets are not supported.
  """
  @type offset :: non_neg_integer
  @type limit :: non_neg_integer

  @type page_info :: %{
    start_cursor: cursor,
    end_cursor: cursor,
    has_previous_page: boolean,
    has_next_page: boolean
  }

  @doc """
  Get a connection object for a list of data.

  A simple function that accepts a list and connection arguments, and returns
  a connection object for use in GraphQL.

  The data given to it should constitute all data that further pagination requests
  may page over. As such, it may be very inefficient if you're pulling data
  from a database which could be used to more directly retrieve just the desired
  data.

  See also `from_query` and `from_slice`.

  ## Example
  ```
  #in a resolver module
  @items ~w(foo bar baz)
  def list(args, _) do
    {:ok, Connection.from_list(@items, args)}
  end
  ```
  """
  @spec from_list(data :: list, args :: Option.t) :: t
  def from_list(data, args, opts \\ []) do
    count = length(data)
    {offset, limit} = case limit(args, opts[:max]) do
      {:forward, limit} ->
        {offset(args) || 0, limit}

      {:backward, limit} ->
        end_offset = offset(args) || count
        start_offset = max(end_offset - limit, 0)
        limit = if start_offset == 0, do: end_offset, else: limit
        {start_offset, limit}
    end

    opts =
      ## Arg checks are unintuitive, but Relay connection spec defines false value if certain args not set
      opts
      |> Keyword.put_new(:has_next_page, args[:first] != nil && count > (offset + limit))
      |> Keyword.put_new(:has_previous_page, args[:last] != nil && offset > 0)

    data
    |> Enum.slice(offset, limit)
    |> from_slice(offset, opts)
  end

  @type from_slice_opts :: [
    has_next_page: boolean,
    has_previous_page: boolean,
  ]

  @type pagination_direction :: :forward | :backward

  @doc """
  Build a connection from slice

  This function assumes you have already retrieved precisely the number of items
  to be returned in this connection request.

  Often this function is used internally by other functions.

  ## Example

  This is basically how our `from_query/2` function works if we didn't need to
  worry about backwards pagination.
  ```
  # In PostResolver module
  alias Absinthe.Relay

  def list(args, %{context: %{current_user: user}}) do
    {:forward, limit} = Connection.limit(args)
    offset = Connection.offset(args)

    conn =
      Post
      |> where(author_id: ^user.id)
      |> limit(^limit)
      |> offset(^offset)
      |> Repo.all
      |> Relay.Connection.from_slice(offset)
    {:ok, conn}
  end
  ```
  """
  @spec from_slice(data :: list, offset :: offset) :: t
  @spec from_slice(data :: list, offset :: offset, opts :: from_slice_opts) :: t
  def from_slice(items, offset, opts \\ []) do
    opts = Map.new(opts)
    {edges, first, last} = build_cursors(items, offset)

    page_info = %{
      start_cursor: first,
      end_cursor: last,
      has_previous_page: Map.get(opts, :has_previous_page, false),
      has_next_page: Map.get(opts, :has_next_page, false),
    }
    %{edges: edges, page_info: page_info}
  end

  @doc """
  Build a connection from an Ecto Query

  This will automatically set a limit and offset value on the ecto query,
  and then run the query with whatever function is passed as the second argument.

  Notes:
  - Your query MUST have an `order_by` value. Offset does not make sense without one.
  - `last: N` must always be acompanied by either a `before:` argument to the query,
  or an explicit `count: ` option to the `from_query` call.
  Otherwise it is impossible to derive the required offset.

  ## Example
  ```
  # In a PostResolver module
  alias Absinthe.Relay

  def list(args, %{context: %{current_user: user}}) do
    conn =
      Post
      |> where(author_id: ^user.id)
      |> Relay.Connection.from_query(&Repo.all/1, args)
    {:ok, conn}
  end
  ```
  """

  @type from_query_opts :: [
    count: non_neg_integer
  ] | from_slice_opts

  if Code.ensure_loaded?(Ecto) do
    @spec from_query(Ecto.Query.t, (Ecto.Query.t -> [term]), Options.t) :: map
    @spec from_query(Ecto.Query.t, (Ecto.Query.t -> [term]), Options.t, from_query_opts) :: map
    def from_query(query, repo_fun, args, opts \\ []) do
      require Ecto.Query

      {offset, limit} = case limit(args, opts[:max]) do
        {:forward, limit} ->
          {offset(args) || 0, limit}

        {:backward, limit} ->
          offset = case {offset(args), opts[:count]} do
            {nil, nil} -> raise "You must supply a count if using `last` without `before`"
            {nil, value} -> max(value - limit, 0)
            {value, _} -> max(value - limit, 0)
          end
          {offset, limit}
      end

      records =
        query
        |> Ecto.Query.limit(^limit)
        |> Ecto.Query.offset(^offset)
        |> repo_fun.()

      opts = [
        has_next_page: args[:first] != nil && !(length(records) < limit),
        has_previous_page: args[:last] != nil && offset > 0,
      ] ++ opts

      from_slice(records, offset, opts)
    end
  else
    def from_query(_, _, _, _, _ \\ []) do
      raise ArgumentError, """
      Ecto not Loaded!

      You cannot use this unless Ecto is also a dependency
      """
    end
  end

  @doc """
  Same as `limit/1` with user provided upper bound.

  Often backend developers want to provide a maximum value above which no more
  records can be retrieved, no matter how many are asked for by the front end.

  This function provides that capability. For use with `from_list` or `from_query`
  use the `:max` option on those functions.
  """
  @spec limit(args :: Options.t, max :: pos_integer | nil) :: pos_integer
  def limit(args, nil), do: limit(args)
  def limit(args, max) do
    {direction, limit} = limit(args)
    {direction, min(max, limit)}
  end

  @doc """
  The direction and desired number of records in the pagination arguments.
  """
  @spec limit(args :: Options.t) :: {pagination_direction, limit}
  def limit(%{first: first}), do: {:forward, first}
  def limit(%{last: last}), do: {:backward, last}
  def limit(_), do: 0

  @doc """
  Returns the offset for a page.

  The limit is required because if using backwards pagination the limit will be
  subtracted from the offset.

  If no offset is specified in the pagination arguments, this will return `nil`.
  """
  @spec offset(args :: Options.t) :: offset | nil
  def offset(%{after: cursor}) do
    cursor_to_offset(cursor) + 1
  end
  def offset(%{before: cursor}) do
    max(cursor_to_offset(cursor), 0)
  end
  def offset(_), do: nil

  defp build_cursors([], _offset), do: {[], nil, nil}
  defp build_cursors([item | items], offset) do
    first = offset_to_cursor(offset)
    first_edge = %{
      node: item,
      cursor: first
    }
    {edges, last} = do_build_cursors(items, offset + 1, [first_edge], first)
    {edges, first, last}
  end

  defp do_build_cursors([], _, edges, last), do: {Enum.reverse(edges), last}
  defp do_build_cursors([item | rest], i, edges, _last) do
    cursor = offset_to_cursor(i)
    edge = %{
      node: item,
      cursor: cursor
    }
    do_build_cursors(rest, i + 1, [edge | edges], cursor)
  end

  @doc """
  Creates the cursor string from an offset.
  """
  @spec offset_to_cursor(integer) :: binary
  def offset_to_cursor(offset) do
    [@cursor_prefix, to_string(offset)]
    |> IO.iodata_to_binary
    |> Base.encode64
  end

  @doc """
  Rederives the offset from the cursor string.
  """
  @spec cursor_to_offset(binary) :: integer | :error
  def cursor_to_offset(cursor) do
    with {:ok, @cursor_prefix <> raw} <- Base.decode64(cursor),
         {parsed, _} <- Integer.parse(raw) do
      parsed
    end
  end

end
