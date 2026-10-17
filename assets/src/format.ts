// How a cell shows its value, in the grid's locale: numbers grouped,
// decimals with the digits the server sent, dates and times in the
// locale's words. A value that does not read as its type shows as it is.
// The text that a copy gives is the value itself, not the formatted one,
// so that a spreadsheet reads numbers and dates as numbers and dates.

import type { CellValue, ColumnType } from "./types";

export type Formatter = (value: CellValue) => string;

const ISO_DATE = /^(-?\d{4,})-(\d{2})-(\d{2})$/;
const ISO_TIME = /^(\d{2}):(\d{2})(?::(\d{2})(?:\.(\d+))?)?$/;
const ZONED = /(Z|[+-]\d{2}:?\d{2})$/;

export function formatter(type: ColumnType, locale: string | undefined): Formatter {
  switch (type) {
    case "integer": {
      const nf = new Intl.NumberFormat(locale, { maximumFractionDigits: 0 });
      return (value) => (typeof value === "number" ? nf.format(value) : plain(value));
    }
    case "number": {
      const nf = new Intl.NumberFormat(locale, { maximumFractionDigits: 10 });
      return (value) => (typeof value === "number" ? nf.format(value) : plain(value));
    }
    case "decimal":
      return decimalFormatter(locale);
    case "date": {
      const df = new Intl.DateTimeFormat(locale, { dateStyle: "medium", timeZone: "UTC" });
      return (value) => {
        const m = typeof value === "string" ? ISO_DATE.exec(value) : null;
        if (!m) return plain(value);
        const date = new Date(Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3])));
        date.setUTCFullYear(Number(m[1]));
        return df.format(date);
      };
    }
    case "datetime": {
      const local = new Intl.DateTimeFormat(locale, { dateStyle: "medium", timeStyle: "short" });
      const naive = new Intl.DateTimeFormat(locale, { dateStyle: "medium", timeStyle: "short", timeZone: "UTC" });
      return (value) => {
        if (typeof value !== "string") return plain(value);
        const zoned = ZONED.test(value);
        const date = new Date(zoned ? value : `${value}Z`);
        if (Number.isNaN(date.getTime())) return value;
        return (zoned ? local : naive).format(date);
      };
    }
    case "time": {
      const tf = new Intl.DateTimeFormat(locale, { timeStyle: "short", timeZone: "UTC" });
      return (value) => {
        const m = typeof value === "string" ? ISO_TIME.exec(value) : null;
        if (!m) return plain(value);
        return tf.format(new Date(Date.UTC(1970, 0, 1, Number(m[1]), Number(m[2]), Number(m[3] ?? 0))));
      };
    }
    case "boolean":
      return (value) => (value === true ? "✓" : value === false ? "" : plain(value));
    default:
      return plain;
  }
}

function plain(value: CellValue): string {
  return value === null || value === undefined ? "" : String(value);
}

// A decimal comes as a string, so that no digit is lost; it keeps the
// digits after the point that the server sent ("120.50" stays two).
function decimalFormatter(locale: string | undefined): Formatter {
  const byDigits = new Map<number, Intl.NumberFormat>();
  return (value) => {
    if (typeof value === "number") value = String(value);
    if (typeof value !== "string" || !/^-?\d+(\.\d+)?$/.test(value)) return plain(value);
    const digits = value.includes(".") ? value.length - value.indexOf(".") - 1 : 0;
    let nf = byDigits.get(digits);
    if (!nf) {
      nf = new Intl.NumberFormat(locale, {
        minimumFractionDigits: Math.min(digits, 20),
        maximumFractionDigits: Math.min(digits, 20),
      });
      byDigits.set(digits, nf);
    }
    // A string keeps every digit where the engine formats decimals exactly
    // (Intl.NumberFormat v3); elsewhere it is read as a number.
    return nf.format(value as unknown as number);
  };
}

/** The text of a value for a copy: the value itself. */
export function copyText(value: CellValue): string {
  if (value === true) return "TRUE";
  if (value === false) return "FALSE";
  return plain(value);
}
