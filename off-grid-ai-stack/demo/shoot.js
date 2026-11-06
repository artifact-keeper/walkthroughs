// Screenshots of the web UI on the site stack, for the demo and the pages. Run by
// demo/shoot.sh in the Playwright image on the stack's network; logs in as admin with PW.
// Each shot is independent: one that fails is reported and the others are still taken.
const { chromium } = require("playwright");
const AK = "https://ak.internal";
(async () => {
  const b = await chromium.launch();
  const ctx = await b.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1920, height: 1080 }, colorScheme: "light" });
  const p = await ctx.newPage();
  await p.goto(`${AK}/login`, { waitUntil: "load" });
  try { await p.waitForSelector("input[name=username]", { timeout: 60000 }); }
  catch (e) { await p.screenshot({ path: "/out/debug-login.png" }); console.log("login page:", p.url()); throw e; }
  await p.fill("input[name=username]", "admin");
  await p.fill("input[name=password]", process.env.PW);
  await p.keyboard.press("Enter");
  await p.waitForURL((u) => !u.pathname.startsWith("/login"), { timeout: 30000 });
  const settle = async (ms = 3000) => { try { await p.waitForLoadState("networkidle", { timeout: 15000 }); } catch {} await p.waitForTimeout(ms); };
  const go = async (path) => { await p.goto(`${AK}${path}`, { waitUntil: "load" }); await settle(); };
  const snap = async (name) => { await p.screenshot({ path: `/out/${name}.png` }); console.log("shot", name); };
  const click = async (sel) => { const l = p.locator(sel).first(); await l.waitFor({ timeout: 10000 }); await l.click(); await settle(2000); };
  const shots = [
    ["s01-repositories", async () => { await go("/repositories"); }],
    ["s02-hf-models", async () => { await go("/repositories/hf-models"); }],
    ["s03-mcp-gallery", async () => { await go("/mcp-servers"); }],
    ["s04-mcp-server", async () => { await go("/mcp-servers"); await click("text=com.acme/inventory"); }],
    ["s05-mcp-server-tools", async () => { await click("role=tab[name=/tools/i]"); }],
    ["s06-mcp-server-security", async () => { await click("role=tab[name=/security|scan/i]"); }],
    ["s07-security-scans", async () => { await go("/security/scans"); }],
    ["s08-scan-pickle", async () => {
      await go("/security/scans");
      const row = p.locator("tr", { hasText: "acme-lab/backdoored" }).filter({ hasText: "model" }).first();
      await row.getByText("View").click(); await settle();
    }],
    ["s09-audit-upstream-fetched", async () => {
      await go("/audit");
      await p.fill("#audit-filter-action", "UPSTREAM_FETCHED");
      await p.getByRole("button", { name: "Apply Filters", exact: true }).click();
      await settle();
      await p.keyboard.press("Escape");
    }],
    ["s10-plugins", async () => { await go("/repositories/plugins"); }],
    ["s11-plugins-central", async () => { await go("/repositories/plugins-central"); }],
  ];
  for (const [name, fn] of shots) {
    try { await fn(); await snap(name); } catch (e) { console.log("FAILED", name, String(e).split("\n")[0]); }
  }
  await b.close();
})();
