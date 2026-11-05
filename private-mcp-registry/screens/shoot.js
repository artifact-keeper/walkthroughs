// Screenshots of the MCP Registry UI for the docs: the gallery, a server's Install tab, the
// approval queue of the Remote, a held version's Security tab and the Tools tab. Run by
// screens/shoot.sh inside the Playwright image on ak-mcp-net; logs in as admin with PW.
const { chromium } = require("playwright");
const shot = async (p, name) => { await p.waitForTimeout(2500); await p.screenshot({ path: `/out/${name}.png` }); console.log(name); };
(async () => {
  const b = await chromium.launch();
  const p = await b.newPage({ ignoreHTTPSErrors: true, viewport: { width: 1440, height: 1000 } });
  await p.goto("https://ak.internal/login", { waitUntil: "load" });
  await p.fill("input[name=username]", "admin");
  await p.fill("input[name=password]", process.env.PW);
  await p.keyboard.press("Enter");
  await p.waitForURL((u) => !u.pathname.startsWith("/login"), { timeout: 30000 });
  const go = async (path) => { await p.goto(`https://ak.internal${path}`, { waitUntil: "load" }); await p.waitForTimeout(3000); };
  await go("/mcp-servers");
  await shot(p, "u01-mcp-gallery");
  await go(`/packages/${process.env.TICKETS}?version=1.0.0&tab=install`);
  await shot(p, "u02-server-install");
  await go("/curation?repo=mcp-upstream");
  await shot(p, "u03-approval-queue");
  await go(`/packages/${process.env.TICKETS}?version=1.0.2&tab=security`);
  await shot(p, "u04-held-version-security");
  await go(`/packages/${process.env.TICKETS}?version=1.0.0&tab=tools`);
  await shot(p, "u05-tools-diff");
  await b.close();
})();
