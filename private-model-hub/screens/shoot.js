// Screenshots of the web UI for the docs: the repository list, the hosted model repository,
// the staging repository with its held and rejected files, and the Hugging Face packages.
// Run by screens/shoot.sh inside the Playwright image on ak-hf-net; logs in as admin with PW.
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
  for (const [path, name] of JSON.parse(process.env.PAGES)) { await go(path); await shot(p, name); }
  await b.close();
})();
