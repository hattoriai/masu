if Code.ensure_loaded?(Ecto.Query) do
  defmodule Masu.Views.Ecto do
    @moduledoc """
    Views in a table of your database (see `Masu.Views`).

        defmodule MyApp.GridViews do
          use Masu.Views.Ecto, repo: MyApp.Repo
        end

        <.data_grid id="orders" ... views={MyApp.GridViews} user={@user}>

    `mix masu.gen.views` writes the migration of the table,
    `masu_views`. Options of `use`: `repo` (required), and `table`, for a
    table of another name.

    A person's last view and their named views are rows of the table: a
    row of `grid` (the grid's `views_key`), `owner` (the user's id),
    `name` (nil for the last view), `shared` and `params` (a map).
    """

    defmodule Record do
      @moduledoc false
      use Ecto.Schema

      schema "masu_views" do
        field(:grid, :string)
        field(:owner, :string)
        field(:name, :string)
        field(:shared, :boolean, default: false)
        field(:params, :map)
        timestamps(type: :utc_datetime)
      end
    end

    import Ecto.Query

    @doc false
    defmacro __using__(opts) do
      repo = Keyword.fetch!(opts, :repo)
      table = Keyword.get(opts, :table, "masu_views")
      store = __MODULE__

      quote do
        @behaviour Masu.Views

        @impl true
        def last(grid, user), do: unquote(store).last(unquote(repo), unquote(table), grid, user)

        @impl true
        def put_last(grid, user, params),
          do: unquote(store).put_last(unquote(repo), unquote(table), grid, user, params)

        @impl true
        def list(grid, user), do: unquote(store).list(unquote(repo), unquote(table), grid, user)

        @impl true
        def save(grid, user, name, params, shared),
          do: unquote(store).save(unquote(repo), unquote(table), grid, user, name, params, shared)

        @impl true
        def delete(grid, user, id),
          do: unquote(store).delete(unquote(repo), unquote(table), grid, user, id)
      end
    end

    @doc false
    def last(repo, table, grid, user) do
      owner = Masu.Views.owner(user)

      from(v in {table, Record},
        where: v.grid == ^grid and v.owner == ^owner and is_nil(v.name),
        select: v.params,
        limit: 1
      )
      |> repo.one()
    end

    @doc false
    def put_last(repo, table, grid, user, params) do
      owner = Masu.Views.owner(user)

      query =
        from(v in {table, Record},
          where: v.grid == ^grid and v.owner == ^owner and is_nil(v.name)
        )

      case repo.one(limit(query, 1)) do
        nil ->
          insert!(repo, table, %{
            grid: grid,
            owner: owner,
            name: nil,
            shared: false,
            params: params
          })

        record ->
          record |> Ecto.Changeset.change(params: params) |> repo.update!()
      end

      :ok
    end

    @doc false
    def list(repo, table, grid, user) do
      owner = Masu.Views.owner(user)

      from(v in {table, Record},
        where: v.grid == ^grid and not is_nil(v.name) and (v.owner == ^owner or v.shared == true),
        order_by: [asc: v.name]
      )
      |> repo.all()
      |> Enum.map(&saved(&1, owner))
    end

    @doc false
    def save(repo, table, grid, user, name, params, shared) do
      owner = Masu.Views.owner(user)

      existing =
        from(v in {table, Record},
          where: v.grid == ^grid and v.owner == ^owner and v.name == ^name,
          limit: 1
        )
        |> repo.one()

      record =
        case existing do
          nil ->
            insert!(repo, table, %{
              grid: grid,
              owner: owner,
              name: name,
              shared: shared,
              params: params
            })

          record ->
            record |> Ecto.Changeset.change(params: params, shared: shared) |> repo.update!()
        end

      {:ok, saved(record, owner)}
    end

    @doc false
    def delete(repo, table, grid, user, id) do
      owner = Masu.Views.owner(user)

      case Integer.parse(to_string(id)) do
        {id, ""} ->
          from(v in {table, Record}, where: v.id == ^id and v.grid == ^grid and v.owner == ^owner)
          |> repo.delete_all()

        _other ->
          :ok
      end

      :ok
    end

    defp insert!(repo, table, fields) do
      %Record{}
      |> Ecto.put_meta(source: table)
      |> Ecto.Changeset.change(fields)
      |> repo.insert!()
    end

    defp saved(%Record{} = record, owner) do
      %{
        id: Integer.to_string(record.id),
        name: record.name,
        shared: record.shared,
        mine: record.owner == owner,
        params: record.params
      }
    end
  end
end
