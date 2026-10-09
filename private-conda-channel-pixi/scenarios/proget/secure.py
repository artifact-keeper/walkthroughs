"""Lock down a fresh ProGet Free through its web UI (Playwright, headless Chromium).

ProGet Free is "limited to UI-based security configuration": the users API answers
"ProGet Free Edition does not support this API". Out of the box the Anonymous user
holds the Administer task on all feeds ("intended for demonstration purposes only",
says the Tasks page), and the built-in user is Admin / Admin (Inedo docs, "Default
Admin Credentials"). This script does the two clicks a person would do:

  1. Log in (/log-in) as Admin, with PROGET_ADMIN_PASSWORD if it is already set,
     otherwise with the first-run password "Admin".
  2. Administration > Security > Built-In Users & Groups > Admin: type the new
     password (PROGET_ADMIN_PASSWORD) in "Password", click Save.
  3. Administration > Security > Tasks / Permissions: click "Remove Anonymous Access"
     (removes Anonymous from Administer; Anonymous keeps "View & Download Packages",
     the same read-only anonymous access the Nexus fragment allows).

Idempotent: steps 2 and 3 are skipped when already done. Prints no secret.
Usage: PROGET_URL=http://127.0.0.1:30482 PROGET_ADMIN_PASSWORD=... python secure.py
"""
import os
import sys

from playwright.sync_api import sync_playwright

G = os.environ.get("PROGET_URL", "http://127.0.0.1:30482")
NEW = os.environ["PROGET_ADMIN_PASSWORD"]


def login(pg, password):
    pg.goto(G + "/log-in")
    pg.fill("#proget-login-user", "Admin")
    pg.fill("#proget-login-password", password)
    pg.keyboard.press("Enter")
    pg.wait_for_load_state("networkidle")
    return "/log-in" not in pg.url and "Anonymous User" not in pg.inner_text("body")


with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page()
    if login(pg, NEW):
        print("secure.py: logged in as Admin with PROGET_ADMIN_PASSWORD (already changed)")
    elif login(pg, "Admin"):
        print("secure.py: logged in as Admin with the first-run password; changing it")
        pg.goto(G + "/administration/security/users/user?userName=Admin")
        pg.fill("#txtPassword", NEW)
        pg.click("a.button:has-text('Save')")
        pg.wait_for_load_state("networkidle")
        pg.context.clear_cookies()
        if not login(pg, NEW):
            sys.exit("secure.py: the new admin password does not log in")
        print("secure.py: admin password changed and verified")
    else:
        sys.exit("secure.py: cannot log in as Admin (neither PROGET_ADMIN_PASSWORD nor the first-run password)")
    pg.goto(G + "/administration/security/tasks")
    pg.wait_for_load_state("networkidle")
    btn = pg.query_selector("a.button:has-text('Remove Anonymous Access')")
    if btn:
        btn.click()
        pg.wait_for_load_state("networkidle")
        pg.goto(G + "/administration/security/tasks")
        pg.wait_for_load_state("networkidle")
        print("secure.py: Anonymous removed from Administer")
    else:
        print("secure.py: Anonymous already has no Administer")
    warn = "has been granted Administer access" in pg.inner_text("body")
    print("secure.py: Tasks page warning 'Anonymous ... Administer access': " + ("still shown" if warn else "gone"))
    if warn:
        sys.exit(1)
    b.close()
