// Copy: the range as tab-separated values (and HTML), with rows the
// browser lacks asked of the server.

import { htmlText } from "../dom";
import { copyText } from "../format";
import { MAX_COPY_ROWS } from "../limits";
import { toTSV } from "../tsv";
import type { Rect } from "../geometry";
import type { CellValue } from "../types";
import type { Grid } from "../grid";

export class Clipboard {
  constructor(private readonly grid: Grid) {}

  /** Copies a range, with its columns' labels first when `headers`. */
  copyRange(range: Rect, headers: boolean): void {
    const last = Math.min(range.bottom, range.top + MAX_COPY_ROWS - 1);
    this.grid.load(range.top, last, () => {
      const text = this.copyText(range.top, last, range, headers);
      const done = navigator.clipboard?.writeText(text);
      if (!done) {
        this.grid.announce(this.grid.message("copy_failed", {}));
        return;
      }
      done.then(
        () => this.grid.announceCopy(last - range.top + 1),
        () => this.grid.announce(this.grid.message("copy_failed", {})),
      );
    });
  }

  onCopy(event: ClipboardEvent): void {
    if (document.activeElement !== this.grid.gridEl) return;
    const selection = this.grid.selection();
    if (!selection) return;
    const last = Math.min(selection.bottom, selection.top + MAX_COPY_ROWS - 1);

    if (this.grid.cache.missing(selection.top, last, this.grid.total).length === 0 && event.clipboardData) {
      event.preventDefault();
      event.clipboardData.setData("text/plain", this.copyText(selection.top, last, selection));
      this.grid.announceCopy(last - selection.top + 1);
      return;
    }

    // Rows that the browser does not have yet: ask for them, then write
    // the clipboard when they come.
    event.preventDefault();
    this.grid.announce(this.grid.message("loading", {}));
    this.grid.load(selection.top, last, () => {
      const text = this.copyText(selection.top, last, selection);
      navigator.clipboard?.writeText(text).then(
        () => this.grid.announceCopy(last - selection.top + 1),
        () => this.grid.announce(this.grid.message("copy_failed", {})),
      );
    });
  }

  private copyText(first: number, last: number, selection: Rect, headers?: boolean): string {
    const lines: string[][] = [];
    if (headers ?? (selection.top === 0 && last === this.grid.total - 1 && this.grid.total > 1)) {
      lines.push(this.grid.columns.slice(selection.left, selection.right + 1).map((column) => column.label));
    }
    for (let index = first; index <= last; index++) {
      const row = this.grid.cache.get(index);
      const line: string[] = [];
      for (let col = selection.left; col <= selection.right; col++) {
        const value = row ? (row[col + 1] as CellValue) : null;
        line.push(this.grid.columns[col].html ? htmlText(Array.isArray(value) ? (value[0] as CellValue) : value) : copyText(value));
      }
      lines.push(line);
    }
    return toTSV(lines);
  }
}
