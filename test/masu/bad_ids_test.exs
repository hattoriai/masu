defmodule Masu.BadIdsTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Masu.Test

  alias Masu.Source

  @endpoint MasuTest.Endpoint

  # Ids that no row of an integer key has: a text, a NUL, a long text,
  # and what is not an id at all.
  @bad ["abc", "1\u0000", String.duplicate("9", 1_001), %{"id" => 1}, nil]

  # An event with its reply, as the browser sends it.
  defp event(view, name, payload) do
    render(view)
    view |> element("#orders") |> render_hook(name, payload)
    %{proxy: {ref, _topic, _pid}} = view

    receive do
      {^ref, {:reply, reply}} -> reply
    after
      1000 -> flunk("no reply to #{name}")
    end
  end

  describe "an id from the browser that no row can have" do
    test "is a row not found, in each event that takes one" do
      {:ok, view, _html} = live(build_conn(), "/bad_ids")

      for id <- @bad do
        edit = %{"id" => id, "key" => "customer", "value" => "Eve"}

        assert %{"errors" => [[^id, "customer", _message]]} =
                 event(view, "masu:edit", %{"edits" => [edit]})

        assert %{"errors" => [[^id, _message]]} = event(view, "masu:delete", %{"ids" => [id]})
        assert %{"index" => nil} = event(view, "masu:locate", %{"id" => id})
        assert %{"entries" => []} = event(view, "masu:history", %{"id" => id})

        assert %{"error" => "editor"} =
                 event(view, "masu:cell_editor", %{"id" => id, "key" => "status"})

        assert %{"error" => "row"} =
                 event(view, "masu:action", %{"kind" => "row", "action" => 0, "id" => id})

        assert %{} = event(view, "masu:detail", %{"id" => id})
        assert %{"count" => 0} = event(view, "masu:select", %{"ids" => [id], "on" => true})
      end

      # The grid is as it was, and a row's own id still works.
      assert ids(view, "orders") == [1, 2, 3, 4, 5, 6]
      assert %{"index" => 1} = event(view, "masu:locate", %{"id" => 2})
      assert %{"count" => 1} = event(view, "masu:select", %{"ids" => ["2"], "on" => true})
    end
  end

  describe "an Ecto source's ids" do
    defmodule Thing do
      @moduledoc false
      use Ecto.Schema

      @primary_key {:id, :binary_id, autogenerate: true}
      schema "things" do
      end
    end

    # An adapter that dumps a :binary_id as a UUID, as PostgreSQL's does.
    defmodule UUIDAdapter do
      @moduledoc false
      def dumpers(:binary_id, type), do: [type, Ecto.UUID]
      def dumpers(_primitive, type), do: [type]
    end

    defmodule UUIDRepo do
      @moduledoc false
      def __adapter__, do: UUIDAdapter
    end

    test "are of the primary key's type, as the repo's adapter dumps it" do
      source = %Source{module: Source.Ecto, state: Source.Ecto.init(Thing, repo: UUIDRepo)}

      assert Source.id?(source, Ecto.UUID.generate())
      refute Source.id?(source, "abc")
      refute Source.id?(source, "a\u0000")
      refute Source.id?(source, 12)
    end

    test "of an integer key: a number, or its text" do
      source = %Source{
        module: Source.Ecto,
        state: Source.Ecto.init(MasuTest.Order, repo: MasuTest.Repo)
      }

      assert Source.id?(source, 3)
      assert Source.id?(source, "3")
      refute Source.id?(source, "abc")
      refute Source.id?(source, 1.5)
    end
  end
end
