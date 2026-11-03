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

# (file name, path, tab to click or None, full page?)
PAGES = [
    ("u01-repositories", "/repositories", None, True),
    ("u02-npm-proxy-security", "/repositories/npm-proxy", "Security", True),
    ("u03-npm-proxy-settings", "/repositories/npm-proxy", "Settings", True),
    ("u04-security-dashboard", "/security", None, True),
    ("u05-audit", "/audit", None, False),
    ("u06-scan-results", "/security/scans", None, True),
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
        try:
            page.wait_for_url(lambda u: "/login" not in u, timeout=20000)
        except Exception:
            print("login failed:", page.url, page.inner_text("body")[:300], file=sys.stderr)
            return 1
        page.wait_for_load_state("load")
        for name, path, tab, full in PAGES:
            # The UI polls, so "networkidle" never comes; load, then give the data calls 3 s.
            page.goto(f"{BASE}{path}", wait_until="load")
            page.wait_for_timeout(3000)
            if tab:
                page.get_by_role("tab", name=tab).first.click()
                page.wait_for_timeout(3000)
            page.screenshot(path=os.path.join(OUT, f"{name}.png"), full_page=full)
            print("saved", name, page.url)
        browser.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
