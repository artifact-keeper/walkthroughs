"""ProGet UI actions the Free edition has no API for (Playwright, headless Chromium).

  ids                 print "<connector name>\t<connector id>" (the id names the local index
                      directory /usr/share/ProGet/LocalStorage/Connectors/C<id>/; the
                      connectors API does not return it)
  delete-index NAME   Connectors > NAME > Local Index > delete (confirm). ProGet's own
                      words: "This should only be done to troubleshooting purposes (e.g. to
                      force an update), as the file will almost immediately be created again."
  index NAME          print the Local Index line ("The local index was last updated 23:20",
                      or the update in progress, e.g. "Updating noarch directory")

Logs in as Admin with PROGET_ADMIN_PASSWORD. Prints no secret.
"""
import os
import re
import sys

from playwright.sync_api import sync_playwright

G = os.environ.get("PROGET_URL", "http://127.0.0.1:30482")


def ids(pg):
    pg.goto(G + "/connectors")
    pg.wait_for_load_state("networkidle")
    out = {}
    for a in pg.query_selector_all("a[href*='/connector/connector?connectorId=']"):
        m = re.search(r"connectorId=(\d+)", a.get_attribute("href"))
        name = a.inner_text().strip()
        if m and name:
            out[name] = m.group(1)
    return out


def index_line(pg, cid):
    pg.goto(G + f"/connector/connector?connectorId={cid}")
    pg.wait_for_load_state("networkidle")
    el = pg.query_selector("h2:has-text('Local Index') ~ .info-box .info-block")
    return " ".join(el.inner_text().split()) if el else "(no local index line)"


with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page()
    pg.goto(G + "/log-in")
    pg.fill("#proget-login-user", "Admin")
    pg.fill("#proget-login-password", os.environ["PROGET_ADMIN_PASSWORD"])
    pg.keyboard.press("Enter")
    pg.wait_for_load_state("networkidle")
    cmd = sys.argv[1]
    m = ids(pg)
    if cmd == "ids":
        for k, v in sorted(m.items()):
            print(f"{k}\t{v}")
    elif cmd in ("delete-index", "index"):
        cid = m[sys.argv[2]]
        if cmd == "delete-index":
            pg.goto(G + f"/connector/connector?connectorId={cid}")
            pg.wait_for_load_state("networkidle")
            pg.on("dialog", lambda d: d.accept())
            link = pg.query_selector("h2:has-text('Local Index') + .controls a:has-text('delete')")
            if link:  # absent while there is no index file or an update is running
                link.click()
                pg.wait_for_load_state("networkidle")
            else:
                print("no delete link (no index file, or an update in progress): ", end="")
        try:
            print(index_line(pg, cid))
        except Exception as e:  # the page can time out while ProGet is busy rebuilding
            print(f"(connector page did not load: {type(e).__name__})")
    else:
        sys.exit("usage: ui.py ids | delete-index NAME | index NAME")
    b.close()
