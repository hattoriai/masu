// The toolbar's buttons, and their icons, drawn for Masu.

export function toolbarButton(label: string, className: string, icon: string): HTMLButtonElement {
  const button = document.createElement("button");
  button.type = "button";
  button.className = `masu-toolbar-button ${className}`;
  button.setAttribute("aria-haspopup", "dialog");
  button.setAttribute("aria-expanded", "false");
  button.innerHTML = icon;
  const text = document.createElement("span");
  text.className = "masu-toolbar-text";
  text.textContent = label;
  button.appendChild(text);
  return button;
}

// Three columns, and a stack of sheets, drawn for Masu.
export const COLUMNS_ICON =
  '<svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true" focusable="false"><rect x="2" y="2.5" width="12" height="11" rx="1.5" fill="none" stroke="currentColor" stroke-width="1.4"/><path d="M6 2.5v11M10 2.5v11" stroke="currentColor" stroke-width="1.4"/></svg>';

export const VIEWS_ICON =
  '<svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true" focusable="false"><path d="M2.5 5.5 8 2.5l5.5 3L8 8.5z M2.5 8.5 8 11.5l5.5-3 M2.5 11 8 14l5.5-3" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linejoin="round"/></svg>';

// A tray with an arrow down, drawn for Masu.
export const EXPORT_ICON =
  '<svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true" focusable="false"><path d="M8 2.5v7M5 6.5l3 3 3-3M2.5 10.5v2a1 1 0 0 0 1 1h9a1 1 0 0 0 1-1v-2" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/></svg>';
