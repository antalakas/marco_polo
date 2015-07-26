defmodule MarcoPolo do
  @moduledoc """
  Main API for interfacing with OrientDB.

  This module provides functions to connect to a running OrientDB server and to
  perform commands on it.

  A connection to OrientDB can be established using the `start_link/1` function
  and stoppped with `stop/1`.

  ## Connection type

  OrientDB makes a distinction between *server operations* and *database
  operations*. Server operations are operations that are performed at server
  level: examples of these operations are checking if a database exists or
  creating a new database. Database operations have to be performed inside a
  database: examples of such operations are inserting a new record or getting
  the number of records in the database.

  Server and database operations can only be performed by the appropriate
  connection: a connection to the server can perform **only** server operations,
  while a connection to a database can perform **only** database operations. The
  connection type is chosen when the connection is started via `start_link/1`.

  ## Examples

      conn_type = {:db, "GratefulDeadConcerts", :document}
      {:ok, conn} = MarcoPolo.start_link(user: "admin", password: "admin", connection: conn_type)
      MarcoPolo.command(conn, "SELECT FROM OUser")
      #=> {:ok, [...users...]}

  """

  alias MarcoPolo.Connection, as: C
  alias MarcoPolo.RID
  alias MarcoPolo.Document
  alias MarcoPolo.BinaryRecord
  alias MarcoPolo.Protocol

  @default_opts [
    host: "localhost",
    port: 2424,
  ]

  @default_fetch_plan ""

  @request_modes %{
    sync: {:raw, <<0>>},
    no_response: {:raw, <<2>>},
  }

  @type db_type :: :document | :graph
  @type storage_type :: :plocal | :memory

  @type rec :: Document.t | BinaryRecord.t

  @doc """
  Starts the connection with an OrientDB server.

  This function accepts the following options:

    * `:user` - (string) the OrientDB user. This option is **required**.
    * `:password` - (string) the OrientDB password. This option is **required**.
    * `:connection` - specifies the connection type. This option is
      **required**. To learn more about the connection type, refer to the docs
      for the `MarcoPolo` module (there's a "Connection type" section). It can
      be:
      * `:server` - connects to the server to perform server operations
      * `{:db, db_name, db_type}` - connects to a database to perform database
        operations. `db_type` can be either `:document` or `:graph`.
    * `:host` - (string or charlist) the host where the OrientDB server is
      running. Defaults to `"localhost"`.
    * `:port` - (integer) the port where the OrientDB server is running.
      Defaults to `2424`.

  ## Examples

  Connecting to the server:

      iex> {:ok, conn} = MarcoPolo.start_link user: "admin", password: "admin", connection: :server
      iex> is_pid(conn)
      true

  Connecting to a database:

      iex> connection = {:db, "MyDatabase", :document}
      iex> {:ok, conn} = MarcoPolo.start_link user: "admin", password: "admin", connection: connection
      iex> is_pid(conn)
      true

  """
  @spec start_link(Keyword.t) :: GenServer.on_start
  def start_link(opts \\ []) do
    C.start_link(Keyword.merge(@default_opts, opts))
  end

  @doc """
  Closes the connection (asynchronously), doing the required cleanup work.

  It always returns `:ok` as soon as it's called (regardless of the operation
  being successful) since it is asynchronous.

  ## Examples

      iex> MarcoPolo.stop(conn)
      :ok

  """
  @spec stop(pid) :: :ok
  def stop(conn) do
    C.stop(conn)
  end

  @doc """
  Tells if the database called `name` with the given `type` exists.

  This operation can only be performed on connections to the server. To learn
  more about the connection type, look at the "Connection type" section in the
  docs for the `MarcoPolo` module.

  ## Examples

      iex> MarcoPolo.db_exists?(conn, "GratefulDeadConcerts", :plocal)
      {:ok, true}

  """
  @spec db_exists?(pid, String.t, storage_type, Keyword.t) ::
    {:ok, boolean} | {:error, term}
  def db_exists?(conn, name, type, opts \\ []) when type in [:plocal, :memory] do
    C.operation(conn, :db_exist, [name, Atom.to_string(type)], opts)
  end

  @doc """
  Reloads the database to which `conn` is connected.

  This operation can only be performed on connections to a database. To learn
  more about the connection type, look at the "Connection type" section in the
  docs for the `MarcoPolo` module.

  ## Examples

      iex> MarcoPolo.db_reload(conn)
      :ok

  """
  @spec db_reload(pid) :: :ok | {:error, term}
  def db_reload(conn, opts \\ []) do
    case C.operation(conn, :db_reload, [], opts) do
      {:ok, _}            -> :ok
      {:error, _} = error -> error
    end
  end

  @doc """
  Creates a database on the server.

  `name` is used as the database name, `type` as the database type (`:document`
  or `:graph`) and `storage` as the storage type (`:plocal` or `:memory`).

  This operation can only be performed on connections to the server. To learn
  more about the connection type, look at the "Connection type" section in the
  docs for the `MarcoPolo` module.

  ## Examples

      iex> MarcoPolo.create_db(conn, "MyCoolDatabase", :document, :plocal)
      :ok

  """
  @spec create_db(pid, String.t, db_type, storage_type, Keyword.t) ::
    :ok | {:error, term}
  def create_db(conn, name, type, storage, opts \\ [])
      when type in [:document, :graph] and storage in [:plocal, :memory] do
    type    = Atom.to_string(type)
    storage = Atom.to_string(storage)

    case C.operation(conn, :db_create, [name, type, storage], opts) do
      {:ok, nil} -> :ok
      o          -> o
    end
  end

  @doc """
  Drop a database on the server.

  This function drops the database identified by the name `name` and the storage
  type `type` (either `:plocal` or `:memory`).

  This operation can only be performed on connections to the server. To learn
  more about the connection type, look at the "Connection type" section in the
  docs for the `MarcoPolo` module.

  ## Examples

      iex> MarcoPolo.drop_db(conn, "UselessDatabase", :memory)
      :ok

  """
  @spec drop_db(pid, String.t, storage_type, Keyword.t) :: :ok | {:error, term}
  def drop_db(conn, name, storage, opts \\ []) when storage in [:plocal, :memory] do
    case C.operation(conn, :db_drop, [name, Atom.to_string(storage)], opts) do
      {:ok, nil} -> :ok
      o          -> o
    end
  end

  @doc """
  Returns the size of the database to which `conn` is connected.

  This operation can only be performed on connections to a database. To learn
  more about the connection type, look at the "Connection type" section in the
  docs for the `MarcoPolo` module.

  ## Examples

      iex> MarcoPolo.db_size(conn)
      {:ok, 1158891}

  """
  @spec db_size(pid, Keyword.t) :: {:ok, non_neg_integer} | {:error, term}
  def db_size(conn, opts \\ []) do
    C.operation(conn, :db_size, [], opts)
  end

  @doc """
  Returns the number of records in the database to which `conn` is connected.

  This operation can only be performed on connections to a database. To learn
  more about the connection type, look at the "Connection type" section in the
  docs for the `MarcoPolo` module.

  ## Examples

      iex> MarcoPolo.db_countrecords(conn)
      {:ok, 7931}

  """
  @spec db_countrecords(pid, Keyword.t) :: {:ok, non_neg_integer} | {:error, term}
  def db_countrecords(conn, opts \\ []) do
    C.operation(conn, :db_countrecords, [], opts)
  end

  @doc """
  Creates a record in the database to which `conn` is connected.

  `cluster_id` specifies the cluster to create the record in, while `record` is
  the `MarcoPolo.Document` struct representing the record to create.

  The return value in case of success is `{:ok, {rid, version}}` where `rid` is
  the rid of the newly created record and `version` is the version of the newly
  created record.

  This function accepts the following options:

    * `:no_response` - if `true`, send the request to the OrientDB server
      without waiting for a response. This performs a *fire and forget*
      operation, returning `:ok` every time.

  This operation can only be performed on connections to a database. To learn
  more about the connection type, look at the "Connection type" section in the
  docs for the `MarcoPolo` module.

  ## Examples

      iex> record = %MarcoPolo.Document{class: "MyClass", fields: %{"foo" => "bar"}}
      iex> MarcoPolo.create_record(conn, 15, record)
      {:ok, {%MarcoPolo.RID{cluster_id: 15, position: 10}, 1}}

  """
  @spec create_record(pid, non_neg_integer, rec, Keyword.t) ::
    {:ok, {RID.t, non_neg_integer}} | {:error, term}
  def create_record(conn, cluster_id, record, opts \\ []) do
    args = [{:short, cluster_id}, record, record_type(record)]

    if opts[:no_response] do
      C.no_response_operation(conn, :record_create, args ++ [@request_modes.no_response])
    else
      refetching_schema conn, fn ->
        C.operation(conn, :record_create, args ++ [@request_modes.sync], opts)
      end
    end
  end

  defp record_type(%Document{}), do: {:raw, "d"}
  defp record_type(%BinaryRecord{}), do: {:raw, "b"}

  @doc """
  Loads a record from the database to which `conn` is connected.

  The record to load is identified by `rid`. Since multiple records could be returned,
  the return value is `{:ok, list_of_records}`.

  This function accepts a list of options:

    * `:fetch_plan` - the [fetching
      strategy](http://orientdb.com/docs/last/Fetching-Strategies.html) used to
      fetch the record from the database.
    * `:ignore_cache` - if `true`, the cache is ignored, if `false` it's not.
      Defaults to `true`.
    * `:load_tombstones` - if `true`, information about deleted records is
      loaded, if `false` it's not. Defaults to `false`.
    * `:if_version_not_latest` - if `true`, only load the given record if the
      version specified in the `:version` option is not the latest. If this
      option is present, the `:version` option is required. This functionality
      is supported in OrientDB >= 2.1.
    * `:version` - see the `:if_version_not_latest` option.

  This operation can only be performed on connections to a database. To learn
  more about the connection type, look at the "Connection type" section in the
  docs for the `MarcoPolo` module.

  ## Examples

      iex> rid = %MarcoPolo.RID{cluster_id: 10, position: 184}
      iex> {:ok, [record]} = MarcoPolo.load_record(conn, rid)
      iex> record.fields
      %{"foo" => "bar"}

  """
  @spec load_record(pid, RID.t, Keyword.t) :: {:ok, [Document.t]} | {:error, term}
  def load_record(conn, %RID{} = rid, opts \\ []) do
    {op, args} =
      if opts[:if_version_not_latest] do
        args = [{:short, rid.cluster_id},
                {:long, rid.position},
                {:int, Keyword.fetch!(opts, :version)},
                opts[:fetch_plan] || @default_fetch_plan,
                opts[:ignore_cache] || true,
                opts[:load_tombstones] || false]
        {:record_load_if_version_not_latest, args}
      else
        args = [{:short, rid.cluster_id},
                {:long, rid.position},
                opts[:fetch_plan] || @default_fetch_plan,
                opts[:ignore_cache] || true,
                opts[:load_tombstones] || false]
        {:record_load, args}
      end

    refetching_schema conn, fn ->
      C.operation(conn, op, args, opts)
    end
  end

  @doc """
  Updates the given record in the databse to which `conn` is connected.

  The record to update is identified by its `rid`; `version` is the version to
  update. `new_record` is the updated record. `update_content?` can be:

    * `true` - the content of the record has been changed and should be updated
      in the storage.
    * `false` - the record was modified but its own content has not changed:
      related collections (e.g. RidBags) have to be updated, but the record
      version and its contents should not be updated.

  When the update is successful, `{:ok, new_version}` is returned.

  This function accepts the following options:

    * `:no_response` - if `true`, send the request to the OrientDB server
      without waiting for a response. This performs a *fire and forget*
      operation, returning `:ok` every time.

  This operation can only be performed on connections to a database. To learn
  more about the connection type, look at the "Connection type" section in the
  docs for the `MarcoPolo` module.

  ## Examples

      iex> rid = %MarcoPolo.RID{cluster_id: 1, position: 10}
      iex> new_record = %MarcoPolo.Document{class: "MyClass", fields: %{foo: "new value"}}
      iex> MarcoPolo.update_record(conn, rid, 1, new_record, true)
      {:ok, 2}

  """
  @spec update_record(pid, RID.t, non_neg_integer, Document.t, boolean, Keyword.t) ::
    {:ok, non_neg_integer} | {:error, term}
  def update_record(conn, %RID{} = rid, version, new_record, update_content?, opts \\ []) do
    args = [{:short, rid.cluster_id},
            {:long, rid.position},
            update_content?,
            new_record,
            version,
            {:raw, "d"}]

    if opts[:no_response] do
      C.no_response_operation(conn, :record_update, args ++ [@request_modes.no_response])
    else
      refetching_schema conn, fn ->
        C.operation(conn, :record_update, args ++ [@request_modes.sync], opts)
      end
    end
  end

  @doc """
  Deletes a record from the database to which `conn` is connected.

  The record to delete is identified by `rid`; version `version` is
  deleted. Returns `{:ok, deleted?}` where `deleted?` is a boolean that tells if
  the record has been deleted.

  This function accepts the following options:

    * `:no_response` - if `true`, send the request to the OrientDB server
      without waiting for a response. This performs a *fire and forget*
      operation, returning `:ok` every time.

  This operation can only be performed on connections to a database. To learn
  more about the connection type, look at the "Connection type" section in the
  docs for the `MarcoPolo` module.

  ## Examples

      iex> rid = %MarcoPolo.RID{cluster_id: 76, position: 12}
      iex> MarcoPolo.delete_record(conn, rid, 1)
      {:ok, true}

  """
  @spec delete_record(pid, RID.t, non_neg_integer, Keyword.t) ::
    {:ok, boolean} | {:error, term}
  def delete_record(conn, %RID{} = rid, version, opts \\ []) do
    args = [{:short, rid.cluster_id},
            {:long, rid.position},
            {:int, version}]

    if opts[:no_response] do
      C.no_response_operation(conn, :record_delete, args ++ [@request_modes.no_response])
    else
      refetching_schema conn, fn ->
        C.operation(conn, :record_delete, args ++ [@request_modes.sync], opts)
      end
    end
  end

  @doc """
  Execute the given `query` in the database to which `conn` is connected.

  OrientDB makes a distinction between idempotent queries and non-idempotent
  queries (it calls the former *queries* and the latter *commands*). In order to
  provide a clean interface for performing operations on the server, `MarcoPolo`
  provides only a `command/3` function both for idempotent as well as
  non-idempotent operations. Whether an operation is idempotent is inferred by
  the text in `query`. As of now, `SELECT` and `TRAVERSE` operations are
  idempotent while all other operations are non-idempotent.

  The options that this function accepts depend in part on the type of the operation.

  The options shared by both idempotent and non-idempotent operations are the following:

    * `:params` - a map of params with atoms or strings as keys and any
      encodable term as values. These parameters are used by OrientDB to build
      prepared statements as you can see in the examples below. Defaults to `%{}`.

  The additional options for idempotent (e.g., `SELECT`) queries are:

    * `:fetch_plan`: a string specifying the fetch plan. Mandatory for `SELECT`
      queries.

  If the query is successful then the return value is an `{:ok, values}` tuple
  where `values` strictly depends on the performed query. Usually, `values` is a
  list of results. For example, when a `CREATE CLUSTER` command is executed,
  `{:ok, [cluster_id]}` is returned where `cluster_id` is the id of the newly
  created cluster.
  query.

  This operation can only be performed on connections to a database. To learn
  more about the connection type, look at the "Connection type" section in the
  docs for the `MarcoPolo` module.

  ## Examples

  The following is an example of an idempotent command:

      iex> opts = [params: %{name: "jennifer"}, fetch_plan: "*:-1"]
      iex> query = "SELECT FROM User WHERE name = :name AND age > 18"
      iex> {:ok, %MarcoPolo.Document{} = doc} = MarcoPolo.command(conn, query, opts)
      iex> doc.fields["name"]
      "jennifer"
      iex> doc.fields["age"]
      45

  The following is an example of a non-idempotent command:

      iex> query = "INSERT INTO User(name) VALUES ('meg', 'abed')"
      iex> {:ok, [meg, abed]} = MarcoPolo.command(conn, query)
      iex> meg.fields["name"]
      "meg"
      iex> abed.fields["name"]
      "abed"

  """
  @spec command(pid, String.t, Keyword.t) :: {:ok, term} | {:error, term}
  def command(conn, query, opts \\ []) do
    query_type = query_type(query)

    command_class_name =
      case query_type do
        :sql_query   -> "q"
        :sql_command -> "c"
      end

    command_class_name = Protocol.encode_term(command_class_name)

    payload = encode_query_with_type(query_type, query, opts)

    args = [{:raw, "s"}, # synchronous mode
            IO.iodata_length([command_class_name, payload]),
            {:raw, command_class_name},
            {:raw, payload}]

    refetching_schema conn, fn ->
      C.operation(conn, :command, args, opts)
    end
  end

  @doc """
  Executes a script in the given `language` on the database `conn` is connected
  to.

  The text of the script is passed as `text`. `opts` is a list of options.

  **Note**: for this to work, scripting must be enabled in the server
  configuration. You can read more about scripting in the [OrientDB
  docs](http://orientdb.com/docs/last/Javascript-Command.html#Enable_Server_side_scripting).

  This operation can only be performed on connections to a database. To learn
  more about the connection type, look at the "Connection type" section in the
  docs for the `MarcoPolo` module.

  ## Examples

      iex> script = "for (i = 0; i < 3; i++) db.command('INSERT INTO Foo(idx) VALUES (' + i + ')');"
      iex> {:ok, last_record} = MarcoPolo.script(conn, "Javascript", script)
      iex> last_record.fields["idx"]
      2

  """
  @spec script(pid, String.t, String.t, Keyword.t) :: {:ok, term} | {:error, term}
  def script(conn, language, text, opts \\ []) do
    command_class_name = Protocol.encode_term("s")

    payload = [Protocol.encode_term(language),
               encode_query_with_type(:sql_command, text, opts)]

    args = [{:raw, "s"}, # synchronous mode
            IO.iodata_length([command_class_name, payload]),
            {:raw, command_class_name},
            {:raw, payload}]

    refetching_schema conn, fn ->
      C.operation(conn, :command, args, opts)
    end
  end

  defp encode_query_with_type(:sql_query, query, opts) do
    args = [query,
            -1,
            opts[:fetch_plan] || @default_fetch_plan,
            %Document{class: nil, fields: %{"params" => to_params(opts[:params] || %{})}}]

    Protocol.encode_list_of_terms(args)
  end

  defp encode_query_with_type(:sql_command, query, opts) do
    args = [query]

    if params = opts[:params] do
      params = %Document{class: nil, fields: %{"parameters" => to_params(params)}}
      # `true` means "use simple parameters".
      args = args ++ [true, params]
    else
      args = args ++ [false]
    end

    args = args ++ [false]

    Protocol.encode_list_of_terms(args)
  end

  defp refetching_schema(conn, fun) do
    case fun.() do
      {:error, :unknown_property_id} ->
        C.fetch_schema(conn)
        fun.()
      o ->
        o
    end
  end

  defp to_params(params) when is_map(params) do
    params
  end

  defp to_params(params) when is_list(params) do
    params
    |> Stream.with_index
    |> Stream.map(fn({val, i}) -> {i, val} end)
    |> Enum.into(%{})
  end

  defp query_type(query) do
    case query_command(query) do
      cmd when cmd in ["select", "traverse"] ->
        :sql_query
      _ ->
        :sql_command
    end
  end

  defp query_command(query) do
    regex               = ~r/^\s*(?<cmd>\w+)/
    %{"cmd" => command} = Regex.named_captures(regex, query)

    String.downcase(command)
  end
end
