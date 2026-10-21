defmodule MasuTest.Company do
  @moduledoc "A company, which customers belong to."
  use Ecto.Schema

  schema "companies" do
    field(:name, :string)
    field(:country, :string)
    field(:size, Ecto.Enum, values: [:small, :large])
  end
end

defmodule MasuTest.Customer do
  @moduledoc "A customer, of a company or of none."
  use Ecto.Schema

  schema "customers" do
    field(:name, :string)
    belongs_to(:company, MasuTest.Company)
  end
end

defmodule MasuTest.Tag do
  @moduledoc "A tag of sales."
  use Ecto.Schema

  schema "tags" do
    field(:name, :string)
  end
end

defmodule MasuTest.Line do
  @moduledoc "A line of a sale."
  use Ecto.Schema

  schema "sale_lines" do
    field(:product, :string)
    belongs_to(:sale, MasuTest.Sale)
  end
end

defmodule MasuTest.Sale do
  @moduledoc "A sale, of a customer or of none, with tags and lines: columns of related rows."
  use Ecto.Schema

  schema "sales" do
    field(:number, :string)
    field(:amount, :integer)
    belongs_to(:customer, MasuTest.Customer)
    has_many(:lines, MasuTest.Line)
    many_to_many(:tags, MasuTest.Tag, join_through: "sale_tags")
  end
end

defmodule MasuTest.Sales do
  @moduledoc """
  The rows of sales, customers, companies, tags and lines, in a repo
  whose tables `MasuTest.Tables` made.
  """

  alias MasuTest.{Company, Customer, Line, Sale, Tag}

  def setup!(repo) do
    for {id, name, country, size} <- [
          {1, "Acme", "PT", :large},
          {2, "Globex", "US", :small},
          {3, "Initech", nil, :small}
        ],
        do: repo.insert!(%Company{id: id, name: name, country: country, size: size})

    for {id, name, company} <- [
          {1, "Ana", 1},
          {2, "Bea", 2},
          {3, "Cid", nil},
          {4, "Dora", 3},
          {5, "Eve", 1}
        ],
        do: repo.insert!(%Customer{id: id, name: name, company_id: company})

    for {id, amount, customer} <- [
          {1, 30, 2},
          {2, 10, 1},
          {3, 50, nil},
          {4, 20, 4},
          {5, 40, 1},
          {6, 60, 3},
          {7, nil, 5}
        ],
        do: repo.insert!(%Sale{id: id, number: "S-#{id}", amount: amount, customer_id: customer})

    for {id, name} <- [{1, "urgent"}, {2, "gift"}, {3, "bulk"}],
        do: repo.insert!(%Tag{id: id, name: name})

    for {sale, tag} <- [{1, 1}, {1, 2}, {2, 2}, {4, 1}, {4, 3}, {5, 1}, {5, 2}, {5, 3}],
        do: repo.insert_all("sale_tags", [%{sale_id: sale, tag_id: tag}])

    for {id, sale, product} <- [{1, 1, "pen"}, {2, 1, "ink"}, {3, 2, "pen"}, {4, 5, "pad"}],
        do: repo.insert!(%Line{id: id, sale_id: sale, product: product})

    :ok
  end
end
