import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { expect, test, type Page } from "@playwright/test";
import { openPage } from "./support";

// Masu in another app's look: its grid, themed with tokens only, against
// Lotus Web's results table (e2e/fixtures/lotus), pixel for pixel.

const fixtures = join(__dirname, "..", "fixtures", "lotus");
const css = readFileSync(join(fixtures, "table.css"), "utf8");
const table = readFileSync(join(fixtures, "table.html"), "utf8");
// Lotus Web's own font, on both pages: with the fonts of the machine, the
// two tables would be drawn in whichever one it has.
const font = readFileSync(join(fixtures, "Inter.woff2")).toString("base64");
const fontFace = `@font-face { font-family: "Inter var"; font-style: normal; font-weight: 100 900; src: url(data:font/woff2;base64,${font}) format("woff2"); }`;

async function withFont(page: Page) {
  await page.addStyleTag({ content: fontFace });
  await page.evaluate(async () => {
    await Promise.all([document.fonts.load('400 14px "Inter var"'), document.fonts.load('600 14px "Inter var"')]);
    await document.fonts.ready;
  });
}

/** The share of pixels that differ by more than a few levels in a channel, except on the lines `skip`. */
async function difference(page: Page, a: Buffer, b: Buffer, skip: number[] = []): Promise<{ ratio: number; diff: string; lines: string[] }> {
  return page.evaluate(
    async ([a, b, skip]) => {
      const load = (data: string) =>
        new Promise<HTMLImageElement>((resolve) => {
          const img = new Image();
          img.onload = () => resolve(img);
          img.src = `data:image/png;base64,${data}`;
        });
      const [ia, ib] = await Promise.all([load(a), load(b)]);
      const width = Math.max(ia.width, ib.width);
      const height = Math.max(ia.height, ib.height);
      const pixels = (img: HTMLImageElement) => {
        const canvas = document.createElement("canvas");
        canvas.width = width;
        canvas.height = height;
        const ctx = canvas.getContext("2d")!;
        ctx.drawImage(img, 0, 0);
        return ctx.getImageData(0, 0, width, height);
      };
      const pa = pixels(ia).data;
      const pb = pixels(ib).data;
      const out = document.createElement("canvas");
      out.width = width;
      out.height = height;
      const octx = out.getContext("2d")!;
      const diff = octx.createImageData(width, height);
      // A pixel matches when a pixel within one of it in the other image is
      // close to it: text drawn with other anti-aliasing (a composited row
      // draws in grayscale) matches; a colour, a line or a place that
      // differs does not.
      const close = (p: Uint8ClampedArray, q: Uint8ClampedArray, x: number, y: number) => {
        const i = (y * width + x) * 4;
        for (let dy = -1; dy <= 1; dy++) {
          for (let dx = -1; dx <= 1; dx++) {
            const nx = x + dx;
            const ny = y + dy;
            if (nx < 0 || ny < 0 || nx >= width || ny >= height) continue;
            const j = (ny * width + nx) * 4;
            const delta = Math.max(Math.abs(p[i] - q[j]), Math.abs(p[i + 1] - q[j + 1]), Math.abs(p[i + 2] - q[j + 2]));
            if (delta <= 48) return true;
          }
        }
        return false;
      };
      let different = 0;
      // The lines that differ over most of their width, to name in a failure.
      const lines: string[] = [];
      const rgb = (p: Uint8ClampedArray, x: number, y: number) => {
        const i = (y * width + x) * 4;
        return `rgb(${p[i]} ${p[i + 1]} ${p[i + 2]})`;
      };
      for (let y = 0; y < height; y++) {
        if (skip.includes(y)) continue;
        const before = different;
        for (let x = 0; x < width; x++) {
          const i = (y * width + x) * 4;
          const off = !close(pa, pb, x, y) || !close(pb, pa, x, y);
          if (off) different += 1;
          diff.data[i] = off ? 255 : pa[i] * 0.2;
          diff.data[i + 1] = off ? 0 : pa[i + 1] * 0.2;
          diff.data[i + 2] = off ? 0 : pa[i + 2] * 0.2;
          diff.data[i + 3] = 255;
        }
        if (different - before > width / 2) {
          const x = Math.floor(width / 2);
          lines.push(`${y} (reference ${rgb(pa, x, y)}, grid ${rgb(pb, x, y)})`);
        }
      }
      octx.putImageData(diff, 0, 0);
      return { ratio: different / (width * height), diff: out.toDataURL(), lines };
    },
    [a.toString("base64"), b.toString("base64"), skip] as const,
  );
}

for (const mode of ["light", "dark"] as const) {
  test(`a grid themed with tokens looks like Lotus Web's table (${mode})`, async ({ browser }, info) => {
    const skip: number[] = [];
    const lotus = await browser.newPage({ viewport: { width: 800, height: 600 } });
    await lotus.setContent(
      `<!doctype html><html lang="en" data-lotus-theme="lotus" class="${mode === "dark" ? "dark" : ""}"><head><style>${css}</style></head><body style="margin:0">${table}</body></html>`,
    );
    await withFont(lotus);
    await lotus.mouse.move(799, 599);
    const reference = lotus.locator("#lotus");
    const referenceBox = (await reference.boundingBox())!;
    const a = await reference.screenshot();

    const page = await browser.newPage({ viewport: { width: 800, height: 600 } });
    await openPage(page, "/look");
    if (mode === "dark") await page.evaluate(() => document.documentElement.classList.add("dark"));
    await withFont(page);
    await page.mouse.move(799, 599);
    const grid = page.locator("#look .masu-grid");
    // The grid at the page's corner, on whole pixels as the reference is
    // (a grid at half a pixel is drawn half a pixel off).
    await grid.evaluate((el) => Object.assign(el.style, { position: "fixed", top: "0", left: "0", width: "660px" }));
    const gridBox = (await grid.boundingBox())!;
    expect([gridBox.width, gridBox.height]).toEqual([referenceBox.width, referenceBox.height]);
    const b = await grid.screenshot();

    const { ratio, diff, lines } = await difference(page, a, b, skip);
    await info.attach(`lotus-${mode}.png`, { body: a, contentType: "image/png" });
    await info.attach(`masu-${mode}.png`, { body: b, contentType: "image/png" });
    await info.attach(`diff-${mode}.png`, { body: Buffer.from(diff.split(",")[1], "base64"), contentType: "image/png" });
    writeFileSync(info.outputPath(`lotus-${mode}.png`), a);
    writeFileSync(info.outputPath(`masu-${mode}.png`), b);
    writeFileSync(info.outputPath(`diff-${mode}.png`), Buffer.from(diff.split(",")[1], "base64"));
    console.log(`${mode}: ${(ratio * 100).toFixed(3)}% of pixels differ`);
    expect(ratio, `lines that differ: ${lines.join(", ")}`).toBeLessThan(0.002);

    // A cell under the pointer: Lotus's hover, on the cell.
    await lotus.mouse.move(referenceBox.x + 200, referenceBox.y + 48 + 52 + 26);
    await page.mouse.move(gridBox.x + 200, gridBox.y + 48 + 52 + 26);
    // Lotus's colours change in 150ms.
    await lotus.waitForTimeout(400);
    const hovered = await difference(page, await reference.screenshot(), await grid.screenshot(), skip);
    writeFileSync(info.outputPath(`diff-hover-${mode}.png`), Buffer.from(hovered.diff.split(",")[1], "base64"));
    console.log(`${mode}, hovered: ${(hovered.ratio * 100).toFixed(3)}% of pixels differ`);
    expect(hovered.ratio, `lines that differ: ${hovered.lines.join(", ")}`).toBeLessThan(0.002);
  });
}
