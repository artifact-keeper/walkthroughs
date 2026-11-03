"""Take the walkthrough's UI screenshots headlessly, against the running stack.

Run through screens/run.sh (a Playwright container on the registry network). Logs in as
admin, visits each page below, waits for the network to settle, and saves a PNG per page
under screens/out/. Light theme, 1440 px wide, full page.
"""
import os
import sys

from playwright.sync_api import sync_playwright

BASE = os.environ.get("AK_URL", "https://ak.internal")
USER = os.environ.get("AK_USER", "admin")
PASSWORD = os.environ["AK_PASSWORD"]
OUT = os.environ.get("OUT", "/out")

# (file name, path, what the caption should say)
PAGES = [
    ("u01-repositories", "/repositories", "the repositories list"),
    ("u02-npm-proxy-scans", "/repositories/npm-proxy", "a Remote's detail page with the proxy scan panel"),
    ("u03-security-dashboard", "/security", "the admin security dashboard"),
    ("u04-scans", "/security/scans", "the scan list"),
    ("u05-audit", "/audit", "the audit log"),
]


def main() -> int:
    os.makedirs(OUT, exist_ok=True)
    with sync_playwright() as p:
        browser = p.chromium.launch()
        ctx = browser.new_context(
            ignore_https_errors=True,
            viewport={"width": 1440, "height": 900},
            color_scheme="light",
        )
        page = ctx.new_page()
        page.goto(f"{BASE}/login", wait_until="networkidle")
        page.fill("input[name=username], input[id=username], input[type=text]", USER)
        page.fill("input[name=password], input[id=password], input[type=password]", PASSWORD)
        page.click("button[type=submit]")
        page.wait_for_load_state("networkidle")
        if "/login" in page.url:
            print("login failed:", page.url, file=sys.stderr)
            return 1
        for name, path, _ in PAGES:
            page.goto(f"{BASE}{path}", wait_until="networkidle")
            page.wait_for_timeout(1500)
            page.screenshot(path=os.path.join(OUT, f"{name}.png"), full_page=True)
            print("saved", name, page.url)
        browser.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
