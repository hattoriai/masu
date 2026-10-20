defmodule Masu.Export.Xlsx do
  @moduledoc false
  # An XLSX file of an export, with no library: the parts of a workbook
  # of one sheet, zipped as they are written (Masu.Export.Zip), the sheet
  # a block of rows at a time.

  alias Masu.{Column, Export}
  alias Masu.Export.Zip

  @xmlns ~s(xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main")
  @rels "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
  @package "http://schemas.openxmlformats.org/package/2006/relationships"

  # The styles of the cells: 1 a date, 2 a datetime, 3 a time, 4 a label.
  @date 1
  @datetime 2
  @time 3
  @label 4

  # The parts of the workbook, zipped as they are written: `blocks` are
  # the rows, a list at a time.
  @spec stream(Export.t(), Enumerable.t()) :: Enumerable.t()
  def stream(%Export{columns: columns}, blocks) do
    Zip.stream([
      {"[Content_Types].xml", [content_types()]},
      {"_rels/.rels", [root_rels()]},
      {"xl/workbook.xml", [workbook()]},
      {"xl/_rels/workbook.xml.rels", [workbook_rels()]},
      {"xl/styles.xml", [styles()]},
      {"xl/worksheets/sheet1.xml", sheet(columns, blocks)}
    ])
  end

  defp sheet(columns, blocks) do
    head = [
      ~s(<?xml version="1.0" encoding="UTF-8" standalone="yes"?>),
      "<worksheet ",
      @xmlns,
      "><sheetData>",
      row(1, Enum.map(columns, &{:label, &1.label}))
    ]

    rows =
      Stream.transform(blocks, 2, fn block, r ->
        {[block |> Enum.with_index(r) |> Enum.map(&data_row(columns, &1))], r + length(block)}
      end)

    Stream.concat([[head], rows, ["</sheetData></worksheet>"]])
  end

  defp data_row(columns, {data, r}), do: row(r, Enum.map(columns, &{&1, Column.flat(&1, data)}))

  defp row(r, cells) do
    [
      ~s(<row r="#{r}">),
      cells |> Enum.with_index() |> Enum.map(fn {cell, col} -> cell(ref(col, r), cell) end),
      "</row>"
    ]
  end

  defp cell(_ref, {_column, nil}), do: []
  defp cell(ref, {:label, label}), do: text(ref, label, @label)

  defp cell(ref, {_column, value}) when is_boolean(value),
    do: [~s(<c r="#{ref}" t="b"><v>), if(value, do: "1", else: "0"), "</v></c>"]

  defp cell(ref, {_column, value}) when is_integer(value) or is_float(value),
    do: number(ref, to_string(value), nil)

  defp cell(ref, {_column, %{__struct__: Decimal} = value}),
    do: number(ref, Decimal.to_string(value, :normal), nil)

  defp cell(ref, {_column, %Date{} = date}),
    do: number(ref, to_string(Date.diff(date, ~D[1899-12-30])), @date)

  defp cell(ref, {_column, %DateTime{} = datetime}),
    do: cell(ref, {nil, DateTime.to_naive(DateTime.shift_zone!(datetime, "Etc/UTC"))})

  defp cell(ref, {_column, %NaiveDateTime{} = datetime}) do
    days = Date.diff(NaiveDateTime.to_date(datetime), ~D[1899-12-30])
    {seconds, _micro} = datetime |> NaiveDateTime.to_time() |> Time.to_seconds_after_midnight()
    number(ref, Float.to_string(days + seconds / 86_400), @datetime)
  end

  defp cell(ref, {_column, %Time{} = time}) do
    {seconds, _micro} = Time.to_seconds_after_midnight(time)
    number(ref, Float.to_string(seconds / 86_400), @time)
  end

  defp cell(ref, {_column, value}) when is_binary(value), do: text(ref, value, nil)

  defp cell(ref, {_column, value}),
    do: text(ref, value |> Masu.Value.to_wire() |> to_string(), nil)

  defp number(ref, value, nil), do: [~s(<c r="#{ref}"><v>), value, "</v></c>"]
  defp number(ref, value, style), do: [~s(<c r="#{ref}" s="#{style}"><v>), value, "</v></c>"]

  defp text(ref, value, style) do
    s = if style, do: ~s( s="#{style}"), else: ""

    [
      ~s(<c r="#{ref}" t="inlineStr"#{s}><is><t xml:space="preserve">),
      escape(value),
      "</t></is></c>"
    ]
  end

  # XML 1.0 has no place for most control characters.
  defp escape(text) do
    text
    |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F]/u, "")
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  @doc false
  # A cell's reference: A1, Z1, AA1.
  @spec ref(non_neg_integer(), pos_integer()) :: String.t()
  def ref(col, r), do: letters(col) <> Integer.to_string(r)

  defp letters(col) when col < 26, do: <<?A + col>>
  defp letters(col), do: letters(div(col, 26) - 1) <> <<?A + rem(col, 26)>>

  defp content_types do
    ~s(<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n) <>
      ~s(<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">) <>
      ~s(<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>) <>
      ~s(<Default Extension="xml" ContentType="application/xml"/>) <>
      ~s(<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>) <>
      ~s(<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>) <>
      ~s(<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>) <>
      "</Types>"
  end

  defp root_rels do
    ~s(<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<Relationships xmlns="#{@package}">) <>
      ~s(<Relationship Id="rId1" Type="#{@rels}/officeDocument" Target="xl/workbook.xml"/></Relationships>)
  end

  defp workbook do
    ~s(<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<workbook #{@xmlns} xmlns:r="#{@rels}">) <>
      ~s(<sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>)
  end

  defp workbook_rels do
    ~s(<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<Relationships xmlns="#{@package}">) <>
      ~s(<Relationship Id="rId1" Type="#{@rels}/worksheet" Target="worksheets/sheet1.xml"/>) <>
      ~s(<Relationship Id="rId2" Type="#{@rels}/styles" Target="styles.xml"/></Relationships>)
  end

  defp styles do
    xf = fn attrs -> ~s(<xf fontId="0" fillId="0" borderId="0" xfId="0" #{attrs}/>) end

    ~s(<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<styleSheet #{@xmlns}>) <>
      ~s(<numFmts count="3"><numFmt numFmtId="164" formatCode="yyyy-mm-dd"/>) <>
      ~s(<numFmt numFmtId="165" formatCode="yyyy-mm-dd hh:mm:ss"/><numFmt numFmtId="166" formatCode="hh:mm:ss"/></numFmts>) <>
      ~s(<fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts>) <>
      ~s(<fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>) <>
      ~s(<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>) <>
      ~s(<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>) <>
      ~s(<cellXfs count="5">) <>
      xf.(~s(numFmtId="0")) <>
      xf.(~s(numFmtId="164" applyNumberFormat="1")) <>
      xf.(~s(numFmtId="165" applyNumberFormat="1")) <>
      xf.(~s(numFmtId="166" applyNumberFormat="1")) <>
      ~s(<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>) <>
      "</cellXfs>" <>
      ~s(<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>) <>
      "</styleSheet>"
  end
end
