#!/usr/bin/env python3
"""The download counter of conda.qiyuan.me (worker/): deploy its Worker, query its database, and
check where workflows download from.

    python3 scripts/download-counter.py check <checkout>...
    (source ~/Current/MLML/secret.sh && python3 scripts/download-counter.py deploy [--dry-run])
    (source ~/Current/MLML/secret.sh && python3 scripts/download-counter.py sql [--write] "<one SQL statement>")

The download counter counts the package files served whole at https://conda.qiyuan.me, the address
users install from. Our own pipelines download from https://conda-ci.qiyuan.me, a second address of
the same bucket that no Worker route covers; `check` prints the workflow lines that download from the
users' address.

check needs no secret. deploy and sql use CLOUDFLARE_GOD_KEY only to mint a token that expires in
minutes and to revoke it; run them only on the owner's order (CHANNEL_OPERATIONS.md). The script never
prints a token. deploy runs $WRANGLER, else `wrangler` on PATH (measured with wrangler 4.151.1, which
needs Node.js 22 or later on PATH).
"""

import argparse
import contextlib
import datetime
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import tomllib
import urllib.error
import urllib.request
from pathlib import Path

ACCOUNT_ID = "532d99283b5aa1e02486ee3fdcb163d5"
API = "https://api.cloudflare.com/client/v4"
REPOSITORY = Path(__file__).resolve().parent.parent
_WORKER = tomllib.loads((REPOSITORY / "worker" / "wrangler.toml").read_text())
SCRIPT = _WORKER["name"]
[_ROUTE] = _WORKER["routes"]
ROUTE, ZONE = _ROUTE["pattern"], _ROUTE["zone_name"]
[_DATABASE] = _WORKER["d1_databases"]
DATABASE = _DATABASE["database_name"]
CI_HOST = "conda-ci.qiyuan.me"

# Permission groups, from this account's permission_groups listing.
D1_READ = "192192df92ee43ac90f2aeeffce67e35"
D1_WRITE = "09b2857d1c31407795e75e3fed8617a1"
ACCOUNT = {f"com.cloudflare.api.account.{ACCOUNT_ID}": "*"}
# The permissions `wrangler deploy` needed on 2026-10-31. The zone permissions go on every zone of the
# account: granted on qiyuan.me alone, wrangler keeps the Worker's old routes.
DEPLOY_POLICIES = [
    {"effect": "allow", "resources": ACCOUNT,
     "permission_groups": [{"id": "e086da7e2179491d91ee5f35b3ca210a"},    # Workers Scripts Write
                           {"id": D1_WRITE},
                           {"id": "05880cd1bdc24d8bae0be2136972816b"},    # Workers Tail Read
                           {"id": "c1fde68c7bcc44588cbb6ddbc16d6480"}]},  # Account Settings Read
    {"effect": "allow",
     "resources": {f"com.cloudflare.api.account.{ACCOUNT_ID}": {"com.cloudflare.api.account.zone.*": "*"}},
     "permission_groups": [{"id": "28f4b596e7d643029c524985477ae49a"},    # Workers Routes Write
                           {"id": "c8fed203ed3043cba015a93ad1616f1f"}]},  # Zone Read
]
RETRY_SECONDS = 3
RETRY_FOR = 60

# check: a workflow line naming the users' address downloads from it, unless it is a comment, a
# `name:` value, or carries EXCUSED.
PUBLIC_URL = re.compile(r"https?://conda\.qiyuan\.me(?![\w.-])")
NAME = re.compile(r"^\s*(?:-\s+)?name\s*:")
EXCUSED = "# the users' address, not a download"
SECRET_NAME = re.compile("TOKEN|KEY|SECRET|PASSWORD", re.IGNORECASE)


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


class Token:
    """A minted token. Its value goes only to Cloudflare's API and to the processes of `run`."""

    def __init__(self, value):
        self._value = value

    def call(self, method, path, body=None):
        # Cloudflare refuses a fresh token now and then for a few seconds (code 10000), on any call,
        # also after an earlier call with it passed. A refused request did not run: retrying it
        # cannot run a statement twice. Every other error raises at once.
        deadline = time.monotonic() + RETRY_FOR
        while True:
            try:
                return call(method, path, self._value, body)
            except CloudflareError as error:
                if 10000 not in error.codes or time.monotonic() >= deadline:
                    raise
            time.sleep(RETRY_SECONDS)

    def run(self, argv, cwd, timeout):
        """The exit status of `argv`, run with this token and no other secret of ours."""
        env = {name: value for name, value in os.environ.items() if not SECRET_NAME.search(name)}
        env |= {"CLOUDFLARE_API_TOKEN": self._value, "CLOUDFLARE_ACCOUNT_ID": ACCOUNT_ID}
        with subprocess.Popen(argv, cwd=cwd, env=env) as process:
            try:
                return process.wait(timeout)
            except subprocess.TimeoutExpired:
                # wrangler's launcher passes SIGTERM on to the CLI it starts; a SIGKILL would not.
                process.terminate()
                try:
                    process.wait(10)
                except subprocess.TimeoutExpired:
                    process.kill()
                raise


@contextlib.contextmanager
def minted(purpose, policies, minutes):
    """A Token holding `policies`, revoked on exit; it expires by itself after `minutes`."""
    god = os.environ.get("CLOUDFLARE_GOD_KEY")
    if not god:
        sys.exit("CLOUDFLARE_GOD_KEY is not set; run under (source ~/Current/MLML/secret.sh && ...)")
    expires = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(minutes=minutes)
    token = call("POST", f"/accounts/{ACCOUNT_ID}/tokens", god, {
        "name": f"conda download counter {purpose} (temporary)",
        "expires_on": expires.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "policies": policies,
    })
    try:
        minted_token = Token(token["value"])
        status = minted_token.call("GET", f"/accounts/{ACCOUNT_ID}/tokens/verify")["status"]
        if status != "active":
            sys.exit(f"error: the minted token {token['id']} is {status}")
        yield minted_token
    finally:
        try:
            call("DELETE", f"/accounts/{ACCOUNT_ID}/tokens/{token['id']}", god)
        except Exception as error:
            print(f"warning: token {token['id']} not revoked ({error}); it expires at"
                  f" {expires:%H:%M} UTC", file=sys.stderr)


def database_uuid(token):
    databases = token.call("GET", f"/accounts/{ACCOUNT_ID}/d1/database?name={DATABASE}")
    [database] = [d for d in databases if d["name"] == DATABASE]
    return database["uuid"]


def route_matches(pattern, host_and_path):
    """Whether a Worker route `pattern` covers `host_and_path`: as in Cloudflare's routes, `*` stands
    for anything only at the start of the host and at the end of the path."""
    host, _, path = re.sub(r"^https?://", "", pattern).partition("/")
    url_host, _, url_path = host_and_path.partition("/")
    return ((url_host.endswith(host[1:]) if host.startswith("*") else url_host == host)
            and (url_path.startswith(path[:-1]) if path.endswith("*") else url_path == path))


def git(*argv):
    return subprocess.run(["git", "-C", REPOSITORY, *argv], capture_output=True, check=True).stdout


def deploy(dry_run):
    if dirty := git("status", "--porcelain", "--", "worker/").decode():
        sys.exit(f"error: worker/ has uncommitted changes:\n{dirty}"
                 "deploy deploys worker/ as committed at HEAD; commit first")
    if not (wrangler := shutil.which(os.environ.get("WRANGLER", "wrangler"))):
        sys.exit("error: wrangler not found; name it with $WRANGLER")
    # What is deployed and what is printed are this one commit, read before the key is used.
    sha = git("rev-parse", "HEAD").decode().strip()
    archive = git("archive", sha, "worker")
    problems = []
    with tempfile.TemporaryDirectory() as temp, minted("deploy", DEPLOY_POLICIES, 30) as token:
        tarfile.open(fileobj=io.BytesIO(archive)).extractall(temp, filter="data")
        # One read for each permission except Workers Tail Read, through Token.call's retry of code 10000,
        # so that each service has accepted the token once before wrangler (which does not retry code 10000)
        # first uses it.
        token.call("GET", f"/accounts/{ACCOUNT_ID}")
        token.call("GET", f"/accounts/{ACCOUNT_ID}/workers/scripts")
        database_uuid(token)
        [zone] = token.call("GET", f"/zones?name={ZONE}")
        routes = f"/zones/{zone['id']}/workers/routes"
        token.call("GET", routes)
        try:
            if status := token.run([wrangler, "deploy", *(["--dry-run"] if dry_run else [])],
                                   Path(temp) / "worker", timeout=600):
                problems.append(f"wrangler exited with {status}")
        except subprocess.TimeoutExpired:
            problems.append("wrangler did not finish in 10 minutes")
        finally:
            # `wrangler deploy` recreates the route with request_limit_fail_open off, and a failed one may
            # have done so before failing: restore it whatever wrangler's exit status.
            fail_open = route_fails_open(token, routes, restore=not dry_run)
        if not fail_open and not dry_run:
            problems.append(f"the route {ROUTE} does not fail open after the PUT")
        if covering := [r["pattern"] for r in token.call("GET", routes)
                        if route_matches(r["pattern"], f"{CI_HOST}/noarch/repodata.json")]:
            problems.append(f"the route(s) {', '.join(covering)} cover {CI_HOST}; tell the owner")
    if problems:
        sys.exit("error: " + "; ".join(problems))
    if dry_run:
        print(f"dry run: wrangler built worker/ of {sha:.12}; route fails open: {fail_open};"
              f" no route covers {CI_HOST}")
    else:
        print(f"deployed worker/ of {sha:.12}; route {ROUTE} fails open; no route covers {CI_HOST}")


def route_fails_open(token, routes, restore):
    """Whether ROUTE fails open, after PUTting it back to fail open if `restore`."""
    def route():
        found = [r for r in token.call("GET", routes) if r["pattern"] == ROUTE]
        if not found:
            sys.exit(f"error: the route {ROUTE} is gone; tell the owner")
        return found[0]

    current = route()
    if restore and current.get("request_limit_fail_open") is not True:
        token.call("PUT", f"{routes}/{current['id']}",
                   {"pattern": ROUTE, "script": SCRIPT, "request_limit_fail_open": True})
        current = route()
    return current.get("request_limit_fail_open") is True


def sql(statement, write):
    policies = [{"effect": "allow", "resources": ACCOUNT,
                 "permission_groups": [{"id": D1_WRITE if write else D1_READ}]}]
    with minted("sql --write" if write else "sql", policies, 15) as token:
        results = token.call("POST", f"/accounts/{ACCOUNT_ID}/d1/database/{database_uuid(token)}/query",
                             {"sql": statement})
    for row in results[-1]["results"]:
        print(json.dumps(row, ensure_ascii=False))


def check(checkouts):
    """1 if a workflow or action of a checkout downloads from the users' address, after printing
    each such line; else 0, silently."""
    found = False
    for checkout in map(Path, checkouts):
        if not (checkout / ".github" / "workflows").is_dir():
            sys.exit(f"error: {checkout} has no .github/workflows; name the top directory of a repository"
                     " that has workflows")
        for path in sorted(p for d in ("workflows", "actions") for p in (checkout / ".github" / d).rglob("*")):
            if not path.is_file():
                continue
            for number, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
                text = line.strip()
                if (PUBLIC_URL.search(line) and not text.startswith("#") and not NAME.match(line)
                        and EXCUSED not in line):
                    print(f"{path}:{number}: {text}")
                    found = True
    return 1 if found else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("deploy", help="deploy worker/ as committed at HEAD").add_argument(
        "--dry-run", action="store_true", help="let wrangler build, not deploy")
    query = commands.add_parser("sql", help="run one SQL statement on the download counter's database")
    query.add_argument("--write", action="store_true", help="with a D1 Write token (default: D1 Read)")
    query.add_argument("statement")
    commands.add_parser("check", help="find workflow lines that download from https://conda.qiyuan.me"
                        ).add_argument("checkouts", nargs="+", metavar="checkout",
                                       help="a repository's top directory; its .github/workflows/ and"
                                            " .github/actions/ are read")
    args = parser.parse_args()
    try:
        if args.command == "deploy":
            deploy(args.dry_run)
        elif args.command == "sql":
            sql(args.statement, args.write)
        else:
            sys.exit(check(args.checkouts))
    except CloudflareError as error:
        sys.exit(f"error: {error}")


if __name__ == "__main__":
    main()
