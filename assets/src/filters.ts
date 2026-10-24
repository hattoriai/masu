// The filters of a column's menu: the operators of each type, the input
// they need, and the words of a filter's chip.

import type { ColumnConfig, ColumnType, FilterSpec } from "./types";

export type Op =
  | "eq"
  | "neq"
  | "contains"
  | "not_contains"
  | "starts_with"
  | "ends_with"
  | "gt"
  | "gte"
  | "lt"
  | "lte"
  | "between"
  | "in"
  | "is_nil"
  | "not_nil"
  | "all_of"
  | "none_of";

const NUMBER_OPS: Op[] = ["eq", "neq", "gt", "gte", "lt", "lte", "between", "is_nil", "not_nil"];
const TIME_OPS: Op[] = ["eq", "gt", "gte", "lt", "lte", "between", "is_nil", "not_nil"];
// A column of many values (a path through several related rows): has
// any of, all of, none of, none, some.
const MANY_OPS: Op[] = ["in", "all_of", "none_of", "is_nil", "not_nil"];

/**
 * The operators a column's menu offers, the first the default: those of
 * its type, of the ones its source runs (`allowed`, Masu.Source's
 * `filters/2`) when it says. An enum whose source has no "is one of"
 * filters by one value.
 */
export function opsFor(type: ColumnType, allowed?: string[] | null, many = false): Op[] {
  if (many) return allowed ? MANY_OPS.filter((op) => allowed.includes(op)) : MANY_OPS;
  const ops = typeOps(type);
  if (!allowed) return ops;
  const offered = ops.filter((op) => allowed.includes(op));
  if (type === "enum" && !allowed.includes("in")) {
    return [...(["eq", "neq"] as Op[]).filter((op) => allowed.includes(op)), ...offered];
  }
  return offered;
}

const TEXT_OPS: Op[] = ["contains", "not_contains", "starts_with", "ends_with"];

/**
 * Whether the server filters a column by an operator: one of those its
 * source runs, when it says; else any but those of text, for a column
 * that is not text (as Masu.Filter checks it).
 */
export function allows(column: ColumnConfig, op: Op): boolean {
  if (column.filters) return column.filters.includes(op);
  return column.type === "text" || column.type === "enum" || !TEXT_OPS.includes(op);
}

function typeOps(type: ColumnType): Op[] {
  switch (type) {
    case "text":
      return ["contains", "eq", "neq", "starts_with", "ends_with", "not_contains", "is_nil", "not_nil"];
    case "enum":
      return ["in", "is_nil", "not_nil"];
    case "integer":
    case "number":
    case "decimal":
      return NUMBER_OPS;
    case "date":
    case "datetime":
    case "time":
      return TIME_OPS;
    case "boolean":
      return ["eq", "is_nil"];
  }
}

/** How many values an operator takes: none, one, two (a range) or a list. */
export function arity(op: Op): 0 | 1 | 2 | "list" {
  if (op === "is_nil" || op === "not_nil") return 0;
  if (op === "between") return 2;
  if (op === "in" || op === "all_of" || op === "none_of") return "list";
  return 1;
}

/** The type of the browser's input for a column's value. */
export function inputType(type: ColumnType): string {
  switch (type) {
    case "integer":
    case "number":
    case "decimal":
      return "number";
    case "date":
      return "date";
    case "datetime":
      return "datetime-local";
    case "time":
      return "time";
    default:
      return "text";
  }
}

const ZONED = /(Z|[+-]\d{2}:?\d{2})$/;

/** Whether a datetime has a zone (`Z` or an offset): a `DateTime`'s, not a `NaiveDateTime`'s. */
export function zoned(value: unknown): boolean {
  return typeof value === "string" && ZONED.test(value);
}

/**
 * A filter's value in a browser's input. A datetime-local input has no
 * zone: a datetime with one shows in the browser's time, one without as
 * it is written.
 */
export function inputValue(value: string, type: string): string {
  if (type !== "datetime-local") return value;
  if (!zoned(value)) return value.slice(0, 19);
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`;
}

/**
 * A browser's input as a filter's value. A datetime-local input gives the
 * browser's local time: for a column of datetimes with a zone, it goes to
 * the server with the browser's offset (in UTC); for one of datetimes
 * without (`zoned` false), as it is written, as the cells show them.
 */
export function filterValue(value: string, type: string, zoned = true): string {
  if (type !== "datetime-local" || value === "") return value;
  if (!zoned) return value.length === 16 ? `${value}:00` : value;
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? value : date.toISOString();
}

/**
 * The filter that a menu's inputs make, or `null` when they make none (an
 * empty value, or an empty list).
 */
export function makeFilter(column: ColumnConfig, op: Op, values: string[]): FilterSpec | null {
  const filled = values.map((value) => value.trim());
  switch (arity(op)) {
    case 0:
      return { key: column.key, op };
    case 1:
      if (filled[0] === undefined || filled[0] === "") return null;
      return { key: column.key, op, value: column.type === "boolean" ? filled[0] === "true" : filled[0] };
    case 2:
      if (!filled[0] || !filled[1]) return null;
      return { key: column.key, op, value: [filled[0], filled[1]] };
    case "list":
      return values.length === 0 ? null : { key: column.key, op, value: values };
  }
}

/** The words of an operator, for a column of `type` (of many values: "has any of"). */
export function opLabel(op: Op, type: ColumnType, messages: Record<string, string>, many = false): string {
  if (many) return messages[`op_${op}_many`] ?? messages[`op_${op}`] ?? op;
  const timely = type === "date" || type === "datetime" || type === "time";
  if (timely && (op === "gt" || op === "gte" || op === "lt" || op === "lte")) {
    return messages[`op_${op}_time`] ?? op;
  }
  return messages[`op_${op}`] ?? op;
}

/**
 * The words of a filter's chip: "City contains lon", "Status is one of
 * paid, late", "Age between 20 and 36", "City is empty". `format` gives a
 * value's text as the column shows it.
 */
export function describe(
  filter: FilterSpec,
  column: ColumnConfig,
  format: (value: unknown) => string,
  messages: Record<string, string>,
): string {
  const { label, op, value } = describeParts(filter, column, format, messages);
  return value === null ? `${label} ${op}` : `${label} ${op} ${value}`;
}

/** A filter in words, in its three parts: the column's label, the operator, and the value (null when the operator takes none). */
export function describeParts(
  filter: FilterSpec,
  column: ColumnConfig,
  format: (value: unknown) => string,
  messages: Record<string, string>,
): { label: string; op: string; value: string | null } {
  const op = filter.op as Op;
  const parts = { label: column.label, op: opLabel(op, column.type, messages, column.many) };
  const show = (value: unknown) =>
    value === null ? (messages.empty_value ?? "(empty)") : column.type === "boolean" ? boolText(value, messages) : format(value);

  switch (arity(op)) {
    case 0:
      return { ...parts, value: null };
    case 2: {
      const [from, to] = filter.value as unknown[];
      return { ...parts, value: `${show(from)} ${messages.and ?? "and"} ${show(to)}` };
    }
    case "list":
      return { ...parts, value: (filter.value as unknown[]).map(show).join(", ") };
    default:
      return { ...parts, value: show(filter.value) };
  }
}

function boolText(value: unknown, messages: Record<string, string>): string {
  return value === true || value === "true" ? (messages.yes ?? "Yes") : (messages.no ?? "No");
}

/** The filters of a query with the filter of `key` replaced (or taken away). */
export function replaceFilter(filters: FilterSpec[], key: string, filter: FilterSpec | null): FilterSpec[] {
  const others = filters.filter((f) => f.key !== key);
  return filter ? [...others, filter] : others;
}
