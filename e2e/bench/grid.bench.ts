// The browser's benchmarks: a Masu grid of 1,000 to 1,000,000 rows, and
// two baselines of the same rows: a plain LiveView stream table of every
// row, and the infinite scroll of the LiveView docs (see
// bench/README.md). Each test writes its numbers to
// bench/results/browser/, for bench/report.exs.

import { expect, test, type Page } from "@playwright/test";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const out = join(__dirname, "../../bench/results/browser");
const masuSizes = [1_000, 100_000, 500_000, 1_000_000];
const baselines: [Kind, number[]][] = [
  ["stream", [1_000, 10_000, 100_000]],
  ["viewport", [1_000, 100_000, 1_000_000]],
];

type Kind = "masu" | "stream" | "viewport";

const parts = {
  masu: { box: "#bench-grid", row: "#bench .masu-body .masu-row:not(.masu-loading)" },
  stream: { box: "#bench-scroll", row: "#bench-rows tr" },
  viewport: { box: "#bench-scroll", row: "#bench-rows > div" },
};

function save(name: string, result: object): void {
  mkdirSync(out, { recursive: true });
  writeFileSync(join(out, `${name}.json`), JSON.stringify(result, null, 2));
}

/** Opens the page and gives the milliseconds until its first rows show, and the time of the rows' copy on the server. */
async function open(page: Page, kind: Kind, rows: number): Promise<{ firstRowsMs: number; loadMs: number }> {
  // The first request makes the rows on the server, out of the time.
  await page.request.get(`/bench?kind=${kind}&rows=${rows}`, { timeout: 300_000 });
  const start = Date.now();
  await page.goto(`/bench?kind=${kind}&rows=${rows}`);
  await expect(page.locator("[data-phx-main].phx-connected")).toBeVisible({ timeout: 120_000 });
  await expect(page.locator(parts[kind].row).first()).toBeVisible({ timeout: 120_000 });
  const firstRowsMs = Date.now() - start;
  const loadMs = Number(await page.locator("#bench-memory").getAttribute("data-load-ms"));
  return { firstRowsMs, loadMs };
}

/** The memory of the LiveView's process, after a garbage collection. */
async function serverBytes(page: Page): Promise<number> {
  await page.locator("#bench-measure").click();
  const output = page.locator("#bench-memory[data-bytes]");
  await expect(output).toBeAttached();
  return Number(await output.getAttribute("data-bytes"));
}

/** The JS heap after a garbage collection, and the nodes of the document. */
async function browserMemory(page: Page): Promise<{ heapBytes: number; domNodes: number }> {
  const cdp = await page.context().newCDPSession(page);
  await cdp.send("HeapProfiler.collectGarbage");
  const { usedSize } = (await cdp.send("Runtime.getHeapUsage")) as { usedSize: number };
  const domNodes = await page.evaluate(() => document.getElementsByTagName("*").length);
  return { heapBytes: usedSize, domNodes };
}

/** A fast scroll down, 2,000 pixels a frame for 300 frames: the time of each frame, and the long tasks. */
async function scroll(page: Page, box: string) {
  return page.evaluate(async (selector) => {
    const element = document.querySelector(selector) as HTMLElement;
    const longTasks: number[] = [];
    const observer = new PerformanceObserver((list) => longTasks.push(...list.getEntries().map((e) => e.duration)));
    observer.observe({ type: "longtask" });
    const frames: number[] = [];
    await new Promise((resolve) => requestAnimationFrame(resolve));
    let last = performance.now();
    for (let i = 0; i < 300; i++) {
      element.scrollTop += 2000;
      await new Promise((resolve) => requestAnimationFrame(resolve));
      const now = performance.now();
      frames.push(now - last);
      last = now;
    }
    observer.disconnect();
    return { frames, longTasks };
  }, box);
}

/** The ID of the first row on the screen, how far a scroll went; null for a screen of no rows. */
async function firstShownId(page: Page, kind: Kind): Promise<number | null> {
  return page.evaluate(({ box, row }) => {
    const frame = document.querySelector(box)!.getBoundingClientRect();
    for (const el of document.querySelectorAll<HTMLElement>(row)) {
      const rect = el.getBoundingClientRect();
      if (rect.bottom > frame.top + 1 && rect.top < frame.bottom - 1 && el.innerText.trim() !== "") {
        const id = (el.querySelector(".masu-cell, td, span") as HTMLElement | null)?.innerText ?? "";
        const digits = id.replace(/\D/g, "");
        if (digits !== "") return Number(digits);
      }
    }
    return null;
  }, parts[kind]);
}

function frameStats(frames: number[]) {
  const sorted = [...frames].sort((a, b) => a - b);
  const at = (p: number) => sorted[Math.min(sorted.length - 1, Math.floor((p / 100) * sorted.length))];
  return {
    p50: at(50),
    p95: at(95),
    max: sorted[sorted.length - 1],
    // A frame of more than two frames' time at 60 Hz: one dropped at least.
    over33ms: frames.filter((f) => f > 33.4).length,
    count: frames.length,
  };
}

/**
 * Jumps to a place in the grid (a fraction of its height, as the
 * scrollbar dragged there) and waits until the rows on the screen are
 * the real rows, not placeholders: the milliseconds, and the last row
 * on the screen.
 */
async function jump(page: Page, fraction: number) {
  return page.evaluate(async (fraction) => {
    const box = document.querySelector("#bench-grid") as HTMLElement;
    box.scrollTop = fraction === 1 ? box.scrollHeight : Math.floor(box.scrollHeight * fraction);
    const start = performance.now();
    while (performance.now() - start < 30_000) {
      await new Promise((resolve) => requestAnimationFrame(resolve));
      const frame = box.getBoundingClientRect();
      const shown = [...box.querySelectorAll<HTMLElement>(".masu-body .masu-row")].filter((row) => {
        const rect = row.getBoundingClientRect();
        return rect.bottom > frame.top + 1 && rect.top < frame.bottom - 1;
      });
      if (shown.length > 0 && !shown.some((row) => row.classList.contains("masu-loading"))) {
        const indexes = shown.map((row) => Number(row.getAttribute("aria-rowindex")));
        return {
          ms: performance.now() - start,
          lastRowIndex: Math.max(...indexes),
          scrollHeight: box.scrollHeight,
        };
      }
    }
    return { ms: null, lastRowIndex: null, scrollHeight: box.scrollHeight };
  }, fraction);
}

for (const rows of masuSizes) {
  test(`masu, ${rows} rows`, async ({ page, browserName }) => {
    test.skip(browserName !== "chromium");
    const { firstRowsMs, loadMs } = await open(page, "masu", rows);
    const server = await serverBytes(page);
    const before = await browserMemory(page);
    const scrolled = await scroll(page, parts.masu.box);
    const reachedId = await firstShownId(page, "masu");
    await page.waitForTimeout(1000);
    const reachedIdAfter1s = await firstShownId(page, "masu");
    const middle = await jump(page, 0.5);
    const after = await browserMemory(page);

    save(`chromium-masu-${rows}`, {
      browser: "chromium",
      version: page.context().browser()?.version(),
      kind: "masu",
      rows,
      firstRowsMs,
      loadMs,
      serverBytes: server,
      heapBytes: before.heapBytes,
      heapBytesAfterScroll: after.heapBytes,
      domNodes: before.domNodes,
      domNodesAfterScroll: after.domNodes,
      frames: frameStats(scrolled.frames),
      longTasks: { count: scrolled.longTasks.length, max: Math.max(0, ...scrolled.longTasks) },
      reachedId,
      reachedIdAfter1s,
      jumpToMiddleMs: middle.ms,
    });
  });

  test(`masu, ${rows} rows, the last row`, { tag: "@all-browsers" }, async ({ page, browserName }) => {
    await open(page, "masu", rows);
    const end = await jump(page, 1);

    save(`${browserName}-last-${rows}`, {
      browser: browserName,
      version: page.context().browser()?.version(),
      kind: "masu",
      rows,
      expectedLastRowIndex: rows + 1,
      lastRowIndex: end.lastRowIndex,
      scrollHeight: end.scrollHeight,
      jumpToEndMs: end.ms,
    });
  });
}

for (const [kind, sizes] of baselines) {
  for (const rows of sizes) {
    test(`${kind}, ${rows} rows`, async ({ page, browserName }) => {
      test.skip(browserName !== "chromium");
      const { firstRowsMs, loadMs } = await open(page, kind, rows);
      const server = await serverBytes(page);
      const before = await browserMemory(page);
      const scrolled = await scroll(page, parts[kind].box);
      const reachedId = await firstShownId(page, kind);
      await page.waitForTimeout(1000);
      const reachedIdAfter1s = await firstShownId(page, kind);

      save(`chromium-${kind}-${rows}`, {
        browser: "chromium",
        version: page.context().browser()?.version(),
        kind,
        rows,
        firstRowsMs,
        loadMs,
        serverBytes: server,
        heapBytes: before.heapBytes,
        domNodes: before.domNodes,
        frames: frameStats(scrolled.frames),
        longTasks: { count: scrolled.longTasks.length, max: Math.max(0, ...scrolled.longTasks) },
        reachedId,
      reachedIdAfter1s,
      });
    });
  }
}
