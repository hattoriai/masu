defmodule Masu.ExportTest do
  use ExUnit.Case, async: true

  alias Masu.Column
  alias Masu.Export.{Download, Ticket, Xlsx}

  import Phoenix.ConnTest
  import Plug.Conn, only: [get_resp_header: 2]
  import Phoenix.LiveViewTest
  import Masu.Test

  @endpoint MasuTest.Endpoint

  defp open do
    {:ok, view, _html} = live(build_conn(), "/export")
    view
  end

  test "CSV: the rows of the query, the columns that show, their labels first" do
    view = open()
    filter(view, "people", [{"id", :gte, 4}])

    {name, csv} = export(view, "people", :csv)
    assert name =~ ~r/^people-\d{4}-\d{2}-\d{2}\.csv$/

    assert csv ==
             "ID,Name,Balance,Born,Admin\r\n" <>
               "4,Edsger Dijkstra,0,1930-05-11,false\r\n" <>
               "5,Barbara Liskov,99.99,1939-11-07,false\r\n" <>
               "6,\"'=HYPERLINK(\"\"x\"\")\",,,\r\n"
  end

  test "the link goes through the router's scope, and is good once" do
    view = open()
    url = export_url(view, "people", :csv)
    assert url =~ ~r{^/admin/masu/exports/[^/?]+$}

    conn = get(build_conn(), url)
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["text/csv; charset=utf-8"]
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert conn.resp_body =~ "ID,Name"

    conn = get(build_conn(), url)
    assert conn.status == 410
    assert conn.resp_body =~ "used, or has expired"
  end

  test "a link of no export gives nothing; a ticket goes with its LiveView" do
    assert get(build_conn(), "/admin/masu/exports/nonsense").status == 404

    owner = spawn(fn -> Process.sleep(:infinity) end)
    {:ok, ticket} = Ticket.start(owner, :export)
    ref = Process.monitor(ticket)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^ticket, :normal}
    assert Ticket.take(ticket) == :gone
  end

  test "the file's name in its header has nothing that ends the header" do
    assert Download.disposition("a\"b\r\nX-Evil: 1", "csv") ==
             ~s(attachment; filename="abX-Evil: 1.csv"; filename*=UTF-8''abX-Evil%3A%201.csv)

    assert Download.disposition("Pedidos ação", "xlsx") ==
             ~s(attachment; filename="Pedidos a__o.xlsx"; filename*=UTF-8''Pedidos%20a%C3%A7%C3%A3o.xlsx)

    assert Download.disposition("", "csv") =~ ~s(filename="export.csv")
  end

  test "write/4 writes a file a block at a time, and says how far it got" do
    columns = [Column.new(field: :id, type: :integer), Column.new(field: :name)]
    rows = for id <- 1..1203, do: %{id: id, name: "row #{id}"}

    export = %Masu.Export{
      input: rows,
      opts: [row_id: & &1.id],
      query: %Masu.Query{},
      columns: columns,
      all_columns: columns,
      name: "rows"
    }

    dir = Path.join(System.tmp_dir!(), "masu-export-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    me = self()

    path = Path.join(dir, "rows.csv")
    :ok = Masu.Export.write(export, :csv, path, progress: &send(me, {:progress, &1, &2}))
    assert path |> File.read!() |> String.split("\r\n", trim: true) |> length() == 1204
    for done <- [500, 1000, 1203, 1203], do: assert_received({:progress, ^done, 1203})

    path = Path.join(dir, "rows.xlsx")
    :ok = Masu.Export.write(export, :xlsx, path)

    {:ok, [{_name, sheet}]} =
      :zip.unzip(String.to_charlist(path), [:memory, file_list: [~c"xl/worksheets/sheet1.xml"]])

    assert sheet =~
             ~s(<c r="B1204" t="inlineStr"><is><t xml:space="preserve">row 1203</t></is></c>)

    assert sheet =~ ~r{</row></sheetData></worksheet>$}
  end

  test "XLSX: a workbook of one sheet, with numbers, dates and booleans as such" do
    view = open()
    sort(view, "people", {"id", :asc})
    {name, xlsx} = export(view, "people", :xlsx)
    assert name =~ ~r/\.xlsx$/

    {:ok, files} = :zip.unzip(xlsx, [:memory])
    files = Map.new(files, fn {path, data} -> {to_string(path), data} end)

    assert Map.keys(files) |> Enum.sort() ==
             ~w([Content_Types].xml _rels/.rels xl/_rels/workbook.xml.rels xl/styles.xml xl/workbook.xml xl/worksheets/sheet1.xml)

    sheet = files["xl/worksheets/sheet1.xml"]

    assert sheet =~ ~s(<c r="A1" t="inlineStr" s="4"><is><t xml:space="preserve">ID</t></is></c>)
    assert sheet =~ ~s(<c r="A2"><v>1</v></c>)
    assert sheet =~ ~s(<c r="C2"><v>120.50</v></c>)
    # 1815-12-10 is day -30,973 of Excel's calendar.
    assert sheet =~ ~s(<c r="D2" s="1"><v>#{Date.diff(~D[1815-12-10], ~D[1899-12-30])}</v></c>)
    assert sheet =~ ~s(<c r="E2" t="b"><v>1</v></c>)
    # A cell of text is never a formula in XLSX: the text as it is.
    assert sheet =~
             ~s{<c r="B7" t="inlineStr"><is><t xml:space="preserve">=HYPERLINK("x")</t></is></c>}

    refute sheet =~ "Bad, "
  end

  test "Masu.Live.export/1 gives the LiveView its grid's export, to write anywhere" do
    view = open()
    search(view, "people", "grace")
    html = view |> element("#csv") |> render_click()
    # (The HTML of the page has the lines' \r\n as \n.)
    assert html =~ "ID,Name,Balance,Born,Admin\n3,Grace Hopper,,1906-12-09,true\n"
  end

  test "column letters" do
    assert Xlsx.ref(0, 1) == "A1"
    assert Xlsx.ref(25, 2) == "Z2"
    assert Xlsx.ref(26, 3) == "AA3"
    assert Xlsx.ref(701, 4) == "ZZ4"
    assert Xlsx.ref(702, 5) == "AAA5"
  end
end
