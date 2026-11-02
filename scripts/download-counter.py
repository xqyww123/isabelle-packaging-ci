#!/usr/bin/env python3
"""Pause or resume the download counter of conda.qiyuan.me (worker/index.js).

    (source ~/Current/MLML/secret.sh && python3 download-counter.py pause)
    (source ~/Current/MLML/secret.sh && python3 download-counter.py resume)

A pause ends by itself 6 hours after it was last set.

CLOUDFLARE_GOD_KEY only mints and revokes: the script mints a D1 Write token that
expires in 15 minutes, runs its SQL with it through Cloudflare's D1 REST API (no
wrangler), and revokes it. It never prints a token.
"""

import argparse
import datetime
import json
import os
import sys
import time
import urllib.error
import urllib.request

ACCOUNT_ID = "532d99283b5aa1e02486ee3fdcb163d5"
API = "https://api.cloudflare.com/client/v4"
DATABASE = "conda-downloads"  # worker/wrangler.toml
# The "D1 Write" permission group, read from this account's permission_groups listing.
D1_WRITE = "09b2857d1c31407795e75e3fed8617a1"
PAUSE_HOURS = 6

# Each runs as one batch; the last statement reads back what the Worker will see.
SQL = {
    "pause": f"INSERT OR REPLACE INTO pause VALUES (1, unixepoch() + {PAUSE_HOURS} * 3600);"
             " SELECT until FROM pause",
    "resume": "DELETE FROM pause; SELECT until FROM pause",
}


class CloudflareError(Exception):
    def __init__(self, what, errors):
        super().__init__(f"{what} failed: {json.dumps(errors, ensure_ascii=False)}")
        self.codes = {error.get("code") for error in errors or []}


def call(method, path, token, body=None):
    request = urllib.request.Request(
        API + path,
        data=json.dumps(body).encode() if body is not None else None,
        method=method,
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            payload = json.load(response)
    except urllib.error.HTTPError as error:
        payload = json.load(error)
    if not payload.get("success"):
        raise CloudflareError(f"{method} {path}", payload.get("errors"))
    return payload["result"]


def first_call(method, path, token):
    """`call`, retried while Cloudflare still refuses the freshly minted token (code 10000,
    for a few seconds)."""
    for _ in range(9):
        try:
            return call(method, path, token)
        except CloudflareError as error:
            if 10000 not in error.codes:
                raise
            time.sleep(3)
    return call(method, path, token)


def run_sql(token, sql):
    """The rows of the batch's last statement."""
    databases = first_call("GET", f"/accounts/{ACCOUNT_ID}/d1/database?name={DATABASE}", token)
    [database] = [d for d in databases if d["name"] == DATABASE]
    results = call("POST", f"/accounts/{ACCOUNT_ID}/d1/database/{database['uuid']}/query",
                   token, {"sql": sql})
    return results[-1]["results"]


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("action", choices=SQL)
    action = parser.parse_args().action
    god = os.environ.get("CLOUDFLARE_GOD_KEY")
    if not god:
        sys.exit("CLOUDFLARE_GOD_KEY is not set; run under (source ~/Current/MLML/secret.sh && ...)")

    expires = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(minutes=15)
    minted = call("POST", f"/accounts/{ACCOUNT_ID}/tokens", god, {
        "name": f"conda download counter {action} (temporary)",
        "expires_on": expires.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "policies": [{"effect": "allow",
                      "resources": {f"com.cloudflare.api.account.{ACCOUNT_ID}": "*"},
                      "permission_groups": [{"id": D1_WRITE}]}],
    })
    try:
        rows = run_sql(minted["value"], SQL[action])
    finally:
        try:
            call("DELETE", f"/accounts/{ACCOUNT_ID}/tokens/{minted['id']}", god)
        except Exception as error:
            print(f"warning: token {minted['id']} not revoked ({error}); it expires at"
                  f" {expires:%H:%M} UTC", file=sys.stderr)

    if action == "pause":
        if len(rows) != 1:
            sys.exit(f"error: the pause row reads back as {rows}")
        until = datetime.datetime.fromtimestamp(rows[0]["until"], datetime.timezone.utc)
        print(f"counting paused until {until:%Y-%m-%d %H:%M} UTC")
    else:
        if rows:
            sys.exit(f"error: the pause row is still there: {rows}")
        print("counting resumed")


if __name__ == "__main__":
    main()
