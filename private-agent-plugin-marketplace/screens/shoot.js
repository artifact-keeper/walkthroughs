// Screenshots of the web UI for the docs: the agent-plugins repository's packages, and its
// Setup tab (Claude Code, and Cursor / Codex / VS Code). Run by screens/shoot.sh inside the
// Playwright image on ak-agents-net; logs in as admin with PW from the environment.
const { chromium } = require("playwright");
const shot = async (p, name) => { await p.waitForTimeout(1500); await p.screenshot({ path: `/out/${name}.png` }); };
const scrollTo = async (p, locator, above) => {
  const box = await locator.boundingBox();
  await p.evaluate(([y]) => window.scrollTo(0, y), [box.y + (await p.evaluate(() => window.scrollY)) - above]);
};
(async () => {
  const b = await chromium.launch();
  const p = await b.newPage({ ignoreHTTPSErrors: true, viewport: { width: 1440, height: 1000 } });
  await p.goto("https://ak.internal/login", { waitUntil: "load" });
  await p.fill("input[name=username]", "admin");
  await p.fill("input[name=password]", process.env.PW);
  await p.keyboard.press("Enter");
  await p.waitForURL((u) => !u.pathname.startsWith("/login"), { timeout: 30000 });
  await p.goto("https://ak.internal/repositories/agent-plugins", { waitUntil: "load" });
  await p.waitForTimeout(5000);
  const tabs = p.locator("[role=tablist]").first();
  await scrollTo(p, tabs, 220);
  await shot(p, "u01-agent-plugins-packages");
  await p.getByRole("tab", { name: "Setup" }).click();
  await p.waitForTimeout(2000);
  const claude = p.getByRole("tab", { name: "Claude Code" });
  await scrollTo(p, claude, 60);
  await shot(p, "u02-setup-claude-code");
  await p.getByRole("tab", { name: "Cursor / Codex / VS Code" }).click();
  await scrollTo(p, claude, 60);
  await shot(p, "u03-setup-cursor-codex-vscode");
  await b.close();
})();
