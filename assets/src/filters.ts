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
  | "not_nil";

const NUMBER_OPS: Op[] = ["eq", "neq", "gt", "gte", "lt", "lte", "between", "is_nil", "not_nil"];
const TIME_OPS: Op[] = ["eq", "gt", "gte", "lt", "lte", "between", "is_nil", "not_nil"];

/** The operators a column's menu offers, the first the default. */
export function opsFor(type: ColumnType): Op[] {
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
  if (op === "in") return "list";
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

/** The words of an operator, for a column of `type`. */
export function opLabel(op: Op, type: ColumnType, messages: Record<string, string>): string {
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
  const op = filter.op as Op;
  const words = `${column.label} ${opLabel(op, column.type, messages)}`;
  const show = (value: unknown) =>
    value === null ? (messages.empty_value ?? "(empty)") : column.type === "boolean" ? boolText(value, messages) : format(value);

  switch (arity(op)) {
    case 0:
      return words;
    case 2: {
      const [from, to] = filter.value as unknown[];
      return `${words} ${show(from)} ${messages.and ?? "and"} ${show(to)}`;
    }
    case "list":
      return `${words} ${(filter.value as unknown[]).map(show).join(", ")}`;
    default:
      return `${words} ${show(filter.value)}`;
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
