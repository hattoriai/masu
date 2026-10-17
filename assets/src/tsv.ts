// Tab-separated text, as spreadsheets copy and paste it: a value with a
// tab, a line break or a quote is quoted, with its quotes doubled.

export function tsvField(value: string): string {
  return /[\t\n\r"]/.test(value) ? `"${value.replace(/"/g, '""')}"` : value;
}

export function toTSV(rows: string[][]): string {
  return rows.map((row) => row.map(tsvField).join("\t")).join("\n");
}
