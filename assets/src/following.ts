import type { Grid } from "./grid";

// Following is Issho's, a room's, kept by the page (Issho's contract, with
// no import of it): the root element's `data-issho-following`, a JSON object
// of room to the key of the one followed, and the `issho:following` event.
export function followingIn(room: string): string | null {
  try {
    const all = JSON.parse(document.documentElement.dataset.isshoFollowing ?? "{}") as Record<string, string>;
    return all[room] ?? null;
  } catch {
    return null;
  }
}

export function followIn(room: string, key: string | null): void {
  if (followingIn(room) === key) return;
  let all: Record<string, string> = {};
  try {
    all = JSON.parse(document.documentElement.dataset.isshoFollowing ?? "{}") as Record<string, string>;
  } catch {
    all = {};
  }
  if (key) all[room] = key;
  else delete all[room];
  if (Object.keys(all).length > 0) document.documentElement.dataset.isshoFollowing = JSON.stringify(all);
  else delete document.documentElement.dataset.isshoFollowing;
  document.dispatchEvent(new CustomEvent("issho:following", { detail: { room, key } }));
}

// The copy of each grid's document the person uses last, when a page has
// it twice: that one says where they are.
export const activeIn = new Map<string, Grid>();
