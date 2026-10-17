// The Masu hook for a LiveSocket. The hook makes a Grid of its element,
// sends the grid's events to the component that rendered it (phx-target),
// and gives the grid the server's later renders (`updated`).

import { Grid } from "./grid";
import type { Person, Transport } from "./types";

interface HookContext {
  el: HTMLElement;
  handleEvent(event: string, callback: (payload: Record<string, unknown>) => void): void;
  pushEvent(event: string, payload: object, onReply?: (reply: Record<string, unknown>, ref: number) => void): void;
  pushEventTo(
    target: string | HTMLElement,
    event: string,
    payload: object,
    onReply?: (reply: Record<string, unknown>, ref: number) => void,
  ): void;
}

interface MasuHook extends HookContext {
  grid?: Grid;
}

export const Masu = {
  mounted(this: MasuHook) {
    const hook = this;
    const transport: Transport = {
      push(event, payload, onReply) {
        const reply = onReply ? (response: Record<string, unknown>) => onReply(response) : undefined;
        const target = hook.el.getAttribute("phx-target");
        if (target) hook.pushEventTo(hook.el, event, payload, reply);
        else hook.pushEvent(event, payload, reply);
      },
    };
    hook.grid = new Grid(hook.el, transport);
    hook.handleEvent("masu:people", (payload) => {
      if (payload.id === hook.el.id) hook.grid?.setPeople(payload.people as Person[]);
    });
  },

  updated(this: MasuHook) {
    this.grid?.update();
  },

  destroyed(this: MasuHook) {
    this.grid?.destroy();
    this.grid = undefined;
  },
};
