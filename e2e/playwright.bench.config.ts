import { defineConfig, devices } from "@playwright/test";

// The browser's benchmarks (bench/README.md): `mix bench.browser`. One
// worker, so that the runs do not share the machine. Chromium runs every
// benchmark; Firefox and WebKit only the ones tagged @all-browsers (the
// last row of a large grid), as their timings are not comparable without
// the Chrome DevTools Protocol.
const port = Number(process.env.E2E_PORT ?? 4097);
const baseURL = `http://127.0.0.1:${port}`;

export default defineConfig({
  testDir: "./bench",
  testMatch: "**/*.bench.ts",
  workers: 1,
  fullyParallel: false,
  retries: 0,
  timeout: 600_000,
  reporter: "list",
  use: { baseURL, locale: "en-GB", timezoneId: "Europe/Lisbon" },
  projects: [
    { name: "chromium", use: { ...devices["Desktop Chrome"] } },
    { name: "firefox", use: { ...devices["Desktop Firefox"] }, grep: /@all-browsers/ },
    { name: "webkit", use: { ...devices["Desktop Safari"] }, grep: /@all-browsers/ },
  ],
  webServer: {
    command: "mix do masu.build + dev",
    cwd: "..",
    url: `${baseURL}/small`,
    // +MIscs: 4 GB for :persistent_term, where a million rows of the
    // page are 900 MB (the default is 1 GB).
    env: { PORT: String(port), MASU_DEV_WATCH: "false", MIX_ENV: "dev", ELIXIR_ERL_OPTIONS: "+MIscs 4096" },
    reuseExistingServer: false,
    timeout: 180_000,
    stdout: "ignore",
    stderr: "pipe",
  },
});
