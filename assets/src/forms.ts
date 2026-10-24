// What a form of the app's posts for a cell, as the server reads its params.

export type FormValue = string | null | FormValue[] | { [key: string]: FormValue };

/**
 * What a form editor posts for the cell, `cell[value]`: text, or the
 * params under it (`cell[value][from]`, `cell[value][]`), as the server
 * reads a form's params; null when it posts nothing.
 */
export function formValue(form: HTMLFormElement): FormValue {
  let value: FormValue = null;
  for (const [name, entry] of new FormData(form)) {
    if (typeof entry !== "string" || !name.startsWith("cell[value]")) continue;
    const path = [...name.slice("cell[value]".length).matchAll(/\[([^\]]*)\]/g)].map((m) => m[1]);
    value = setPath(value, path, entry);
  }
  return value;
}

function setPath(into: FormValue, path: string[], entry: string): FormValue {
  if (path.length === 0) return entry;
  const [key, ...rest] = path;
  if (key === "") {
    const list = Array.isArray(into) ? into : [];
    return [...list, setPath(null, rest, entry)];
  }
  const map = into !== null && typeof into === "object" && !Array.isArray(into) ? into : {};
  return { ...map, [key]: setPath(map[key] ?? null, rest, entry) };
}
