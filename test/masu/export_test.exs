defmodule Masu.ExportTest do
  use ExUnit.Case, async: true

  alias Masu.Export.Xlsx

  import Phoenix.ConnTest
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

  test "the progress goes to the browser" do
    view = open()
    export(view, "people", :csv)
    assert_push_event(view, "masu:export", %{"id" => "people", "done" => 6, "total" => 6})
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
