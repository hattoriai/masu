// The Masu hook for a LiveSocket. The hook makes a Grid of its element,
// sends the grid's events to the component that rendered it (phx-target),
// and gives the grid the server's later renders (`updated`).

import { Grid } from "./grid";
import type { BlockReply, Person, Progress, Reply, Transport } from "./types";

interface HookContext {
  el: HTMLElement;
  liveSocket?: { execJS(el: HTMLElement, encodedJS: string, eventType?: string | null): void };
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
      exec(js) {
        hook.liveSocket?.execJS(hook.el, js);
      },
    };
    hook.grid = new Grid(hook.el, transport);
    hook.handleEvent("masu:people", (payload) => {
      if (payload.id === hook.el.id) hook.grid?.setPeople(payload.people as Person[]);
    });
    // A block of rows read in a task (`load={:async}`).
    hook.handleEvent("masu:block", (payload) => {
      if (payload.id === hook.el.id) hook.grid?.receiveBlock(payload.block as BlockReply);
    });
    // A write or an action that went on later (Masu.reply/2, Masu.progress/3).
    hook.handleEvent("masu:reply", (payload) => {
      if (payload.id === hook.el.id) hook.grid?.receiveReply(payload as unknown as Reply);
    });
    hook.handleEvent("masu:progress", (payload) => {
      if (payload.id === hook.el.id) hook.grid?.receiveProgress(payload as unknown as Progress);
    });
  },

  updated(this: MasuHook) {
    this.grid?.update();
  },

  destroyed(this: MasuHook) {
    // A grid of an Issho room that goes while its LiveView stays (an embed
    // deleted from a document): its room lets it go (Issho.Live.release/2).
    const doc = this.el.dataset.isshoDoc;
    if (doc) {
      // A reply of no use: the LiveView may have gone with it (a navigation), and so did its rooms;
      // without one, LiveView rejects a promise no one awaits.
      try {
        this.pushEvent("issho:release", { room: doc.slice(0, doc.indexOf("/")), component: this.el.id }, () => {});
      } catch {
        // The LiveView went with it: so did its rooms.
      }
    }
    this.grid?.destroy();
    this.grid = undefined;
  },
};
