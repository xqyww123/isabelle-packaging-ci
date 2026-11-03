"""scripts/download-counter.py against a fake Cloudflare API and a fake wrangler: minted tokens and
their retries, deploy, sql, check, and which hosts the Worker's route covers."""
import datetime
import importlib.util
import json
import re
import sqlite3
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

import pytest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("download_counter", ROOT / "scripts" / "download-counter.py")
assert spec and spec.loader
dc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dc)

GOD = "fake-god-key"
R2_SECRET = "fake-r2-secret"
ZONE_ID = "fake-zone"
UUID = "fake-database"
SERVICES = ("account", "scripts", "d1", "zone", "routes")

# Logs what it was given, then makes one call with its token, as `wrangler deploy` would; the fake
# API recreates the route with request_limit_fail_open off, as a real deploy does.
FAKE_WRANGLER = f"""#!{sys.executable}
import json, os, sys, urllib.error, urllib.request
files = sorted(os.path.relpath(os.path.join(d, f)) for d, _, fs in os.walk(".") for f in fs)
with open(os.environ["FAKE_WRANGLER_LOG"], "a") as log:
    log.write(json.dumps({{"argv": sys.argv[1:], "cwd": os.getcwd(), "env": sorted(os.environ), "files": files,
                          "index.js": open("index.js").read()}}) + "\\n")
request = urllib.request.Request(os.environ["FAKE_API"] + "/fake-wrangler/deploy", method="POST",
                                 data=json.dumps({{"dry_run": "--dry-run" in sys.argv}}).encode(),
                                 headers={{"Authorization": "Bearer " + os.environ.get("CLOUDFLARE_API_TOKEN", "")}})
try:
    payload = json.load(urllib.request.urlopen(request))
except urllib.error.HTTPError as error:
    payload = json.load(error)
if not payload["success"]:
    sys.exit("Authentication error " + json.dumps(payload["errors"]))
sys.exit(int(os.environ.get("FAKE_WRANGLER_EXIT", "0")))
"""


class FakeCloudflare(ThreadingHTTPServer):
    """Tokens, D1 on a sqlite3 file, the zone's Worker routes, and the fake wrangler's call.

    `refuse[endpoint]` lists the error codes the next calls of an endpoint get. Each service in
    `propagating` refuses a new token's first call that needs it (code 10000), as while the token
    propagates; `on_mint` runs at each mint."""

    ENDPOINTS = [  # (method, path, endpoint, services it needs; None: only the god key)
        ("POST", rf"/accounts/{dc.ACCOUNT_ID}/tokens", "mint", None),
        ("DELETE", rf"/accounts/{dc.ACCOUNT_ID}/tokens/(?P<id>[^/]+)", "revoke", None),
        ("GET", rf"/accounts/{dc.ACCOUNT_ID}/tokens/verify", "verify", ()),
        ("GET", rf"/accounts/{dc.ACCOUNT_ID}", "account", ("account",)),
        ("GET", rf"/accounts/{dc.ACCOUNT_ID}/workers/scripts", "scripts", ("scripts",)),
        ("GET", rf"/accounts/{dc.ACCOUNT_ID}/d1/database", "d1-lookup", ("d1",)),
        ("POST", rf"/accounts/{dc.ACCOUNT_ID}/d1/database/{UUID}/query", "d1-query", ("d1",)),
        ("GET", r"/zones", "zones", ("zone",)),
        ("GET", rf"/zones/{ZONE_ID}/workers/routes", "routes", ("routes",)),
        ("PUT", rf"/zones/{ZONE_ID}/workers/routes/(?P<id>[^/]+)", "route-put", ("routes",)),
        ("POST", r"/fake-wrangler/deploy", "wrangler", SERVICES),
    ]

    def __init__(self, database):
        super().__init__(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.server_address[1]}/client/v4"
        self.database = database
        self.tokens = {}    # value -> {"id", "policies", "expires_on", "propagating", "revoked"}
        self.calls = []     # (endpoint, token id), every call that reached an endpoint
        self.refuse = {}
        self.propagating = set()
        self.on_mint = lambda: None
        self.worker_routes = [{"id": "route-1", "pattern": dc.ROUTE, "script": dc.SCRIPT,
                               "request_limit_fail_open": True}]
        self.lock = threading.Lock()

    def count(self, endpoint):
        return sum(1 for e, _ in self.calls if e == endpoint)

    def route(self):
        [route] = [r for r in self.worker_routes if r["pattern"] == dc.ROUTE]
        return route

    def answer(self, method, url, authorization, body):
        path = urlsplit(url).path.removeprefix("/client/v4")
        for m, pattern, endpoint, services in self.ENDPOINTS:
            if m == method and (match := re.fullmatch(pattern, path)):
                break
        else:
            raise AssertionError(f"unexpected {method} {url}")
        bearer = authorization.removeprefix("Bearer ")
        with self.lock:
            if services is None:
                assert bearer == GOD, f"{endpoint} without the god key"
                self.calls.append((endpoint, "god"))
            else:
                token = self.tokens.get(bearer)
                if token is None or token["revoked"]:
                    return [{"code": 1000, "message": "Invalid API Token"}]
                self.calls.append((endpoint, token["id"]))
                if refused := token["propagating"] & set(services):
                    token["propagating"] -= refused
                    return [{"code": 10000, "message": "Authentication error"}]
            if schedule := self.refuse.get(endpoint):
                return [{"code": schedule.pop(0), "message": "injected"}]
            return getattr(self, endpoint.replace("-", "_"))(match, parse_qs(urlsplit(url).query), body)

    def mint(self, match, query, body):
        self.on_mint()
        value = f"fake-minted-value-{len(self.tokens)}"
        self.tokens[value] = {"id": f"token-{len(self.tokens)}", "policies": body["policies"],
                              "expires_on": body["expires_on"], "propagating": set(self.propagating),
                              "revoked": False}
        return {"id": self.tokens[value]["id"], "value": value}

    def revoke(self, match, query, body):
        [token] = [t for t in self.tokens.values() if t["id"] == match["id"]]
        token["revoked"] = True
        return {"id": match["id"]}

    def verify(self, match, query, body):
        return {"status": "active"}

    def account(self, match, query, body):
        return {"id": dc.ACCOUNT_ID}

    def scripts(self, match, query, body):
        return [{"id": dc.SCRIPT}]

    def d1_lookup(self, match, query, body):
        assert query["name"] == [dc.DATABASE]
        return [{"name": dc.DATABASE, "uuid": UUID}, {"name": dc.DATABASE + "-old", "uuid": "other"}]

    def d1_query(self, match, query, body):
        db = sqlite3.connect(self.database, isolation_level=None)
        try:
            cursor = db.execute(body["sql"])
            columns = [c[0] for c in cursor.description or []]
            return [{"results": [dict(zip(columns, row)) for row in cursor.fetchall()], "success": True}]
        except sqlite3.Error as error:
            return [{"code": 7500, "message": str(error)}]
        finally:
            db.close()

    def zones(self, match, query, body):
        return [{"id": ZONE_ID, "name": query["name"][0]}]

    def routes(self, match, query, body):
        return [dict(r) for r in self.worker_routes]

    def route_put(self, match, query, body):
        [route] = [r for r in self.worker_routes if r["id"] == match["id"]]
        route.clear()
        route.update(body, id=match["id"])
        return dict(route)

    def wrangler(self, match, query, body):
        if not body["dry_run"]:
            self.worker_routes = [r for r in self.worker_routes if r["pattern"] != dc.ROUTE] + [
                {"id": f"route-{len(self.calls)}", "pattern": dc.ROUTE, "script": dc.SCRIPT,
                 "request_limit_fail_open": False}]
        return {}



class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def respond(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length)) if length else None
        result = self.server.answer(self.command, self.path, self.headers.get("Authorization", ""), body)
        if isinstance(result, list) and result and "code" in result[0]:
            status, payload = 403, {"success": False, "errors": result, "result": None}
        else:
            status, payload = 200, {"success": True, "errors": [], "result": result}
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    do_GET = do_POST = do_PUT = do_DELETE = respond


@pytest.fixture
def fake(tmp_path, monkeypatch):
    server = FakeCloudflare(tmp_path / "d1.sqlite3")
    threading.Thread(target=server.serve_forever, daemon=True).start()
    monkeypatch.setattr(dc, "API", server.url)
    monkeypatch.setattr(dc, "RETRY_SECONDS", 0)
    monkeypatch.setenv("CLOUDFLARE_GOD_KEY", GOD)
    monkeypatch.setenv("CONDA_R2_SECRET_ACCESS_KEY", R2_SECRET)
    yield server
    server.shutdown()
    server.server_close()


@pytest.fixture
def cli(fake, capfd, monkeypatch):
    """main() with these arguments: (exit status, stdout, stderr). No secret ever shows in either."""
    def run(*argv):
        monkeypatch.setattr(sys, "argv", ["download-counter.py", *argv])
        status = 0
        try:
            dc.main()
        except SystemExit as exit_:
            if isinstance(exit_.code, str):
                print(exit_.code, file=sys.stderr)
            status = exit_.code if isinstance(exit_.code, int) else 0 if exit_.code is None else 1
        out, err = capfd.readouterr()
        for secret in (GOD, R2_SECRET, *fake.tokens):
            assert secret not in out + err
        return status, out, err
    return run


def git(repository, *argv):
    return subprocess.run(["git", "-C", repository, "-c", "user.name=t", "-c", "user.email=t@t",
                           "-c", "commit.gpgsign=false", *argv], capture_output=True, text=True, check=True).stdout


@pytest.fixture
def repository(tmp_path, fake, monkeypatch):
    """A repository whose HEAD holds this worker/; its working tree adds an ignored file in worker/
    and another agent's uncommitted work outside it."""
    repository = tmp_path / "repository"
    (repository / "worker").mkdir(parents=True)
    for name in ("index.js", "wrangler.toml"):
        (repository / "worker" / name).write_bytes((ROOT / "worker" / name).read_bytes())
    (repository / ".gitignore").write_text("worker/ignored.txt\n")
    git(repository, "init", "-q")
    git(repository, "add", ".")
    git(repository, "commit", "-q", "-m", "worker")
    (repository / "worker" / "ignored.txt").write_text("the working tree's only")
    (repository / "notes.md").write_text("another agent's uncommitted work")
    wrangler = tmp_path / "wrangler"
    wrangler.write_text(FAKE_WRANGLER)
    wrangler.chmod(0o755)
    monkeypatch.setattr(dc, "REPOSITORY", repository)
    monkeypatch.setenv("WRANGLER", str(wrangler))
    monkeypatch.setenv("FAKE_API", fake.url)
    monkeypatch.setenv("FAKE_WRANGLER_LOG", str(tmp_path / "wrangler.log"))
    return repository


def wrangler_runs(tmp_path):
    log = tmp_path / "wrangler.log"
    return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []


def groups(token):
    return [g["id"] for policy in token["policies"] for g in policy["permission_groups"]]


# sql

def test_sql_retries_code_10000_on_every_call(fake, cli):
    fake.refuse = {"verify": [10000], "d1-lookup": [10000], "d1-query": [10000]}
    assert cli("sql", "SELECT 7 AS n, 'x' AS s") == (0, '{"n": 7, "s": "x"}\n', "")
    [token] = fake.tokens.values()
    assert groups(token) == [dc.D1_READ] and token["revoked"]
    assert [fake.count(e) for e in ("verify", "d1-lookup", "d1-query")] == [2, 2, 2]


def test_sql_write_mints_d1_write_and_runs_the_statement(fake, cli):
    assert cli("sql", "--write", "CREATE TABLE t (x)")[0] == 0
    [token] = fake.tokens.values()
    assert groups(token) == [dc.D1_WRITE] and token["revoked"]
    assert sqlite3.connect(fake.database).execute("SELECT name FROM sqlite_master").fetchall() == [("t",)]


def test_a_token_refused_for_good_fails_and_is_revoked(fake, cli, monkeypatch):
    monkeypatch.setattr(dc, "RETRY_FOR", 0.2)
    fake.refuse["d1-query"] = [10000] * 100000
    status, _, err = cli("sql", "SELECT 1")
    assert status == 1 and f"POST /accounts/{dc.ACCOUNT_ID}/d1/database/{UUID}/query failed" in err
    assert all(t["revoked"] for t in fake.tokens.values())


def test_any_other_error_is_never_retried(fake, cli):
    fake.refuse["d1-query"] = [7500]
    status, _, err = cli("sql", "--write", "CREATE TABLE t (x)")
    assert status == 1 and "7500" in err and fake.count("d1-query") == 1
    assert all(t["revoked"] for t in fake.tokens.values())
    assert sqlite3.connect(fake.database).execute("SELECT name FROM sqlite_master").fetchall() == []


@pytest.fixture
def local_time_not_utc():
    """Local time 8 hours ahead of UTC, as on the owner's machine, also where it is UTC (GitHub's runners)."""
    with pytest.MonkeyPatch.context() as local:
        local.setenv("TZ", "Asia/Singapore")
        time.tzset()
        yield
    time.tzset()


def test_a_failed_revoke_warns_with_the_token_id_and_its_expiry(fake, cli, local_time_not_utc):
    fake.refuse["revoke"] = [1000]
    status, out, err = cli("sql", "SELECT 1 AS n")
    [token] = fake.tokens.values()
    expires = datetime.datetime.strptime(token["expires_on"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.UTC)
    assert (status, out) == (0, '{"n": 1}\n') and not token["revoked"]
    warning = rf"warning: token {token['id']} not revoked \(.*\); it expires at {expires:%H:%M} UTC\n"
    assert re.fullmatch(warning, err), err
    left = expires - datetime.datetime.now(datetime.UTC)
    assert datetime.timedelta(minutes=14) < left <= datetime.timedelta(minutes=15)


def test_no_god_key_mints_nothing(fake, cli, monkeypatch):
    monkeypatch.delenv("CLOUDFLARE_GOD_KEY")
    status, _, err = cli("sql", "SELECT 1")
    assert status == 1 and "CLOUDFLARE_GOD_KEY is not set" in err and fake.calls == []


@pytest.mark.parametrize("command", ["pause", "resume"])
def test_pause_and_resume_are_gone(fake, cli, command):
    status, _, err = cli(command)
    assert status == 2 and "invalid choice" in err and fake.calls == []


# deploy

def test_deploy_runs_wrangler_on_head_with_only_the_minted_token(fake, cli, repository, tmp_path):
    status, out, _ = cli("deploy")
    sha = git(repository, "rev-parse", "HEAD")[:12]
    assert status == 0, out
    assert out.endswith(f"deployed worker/ of {sha}; route {dc.ROUTE} fails open; no route covers {dc.CI_HOST}\n")
    [run] = wrangler_runs(tmp_path)
    assert run["argv"] == ["deploy"]
    assert not Path(run["cwd"]).is_relative_to(repository)
    assert run["files"] == ["index.js", "wrangler.toml"]
    assert run["index.js"] == git(repository, "show", "HEAD:worker/index.js")
    assert {"CLOUDFLARE_API_TOKEN", "CLOUDFLARE_ACCOUNT_ID", "PATH"} <= set(run["env"])
    assert not {"CLOUDFLARE_GOD_KEY", "CONDA_R2_SECRET_ACCESS_KEY"} & set(run["env"])
    [(value, token)] = fake.tokens.items()
    assert token["policies"] == dc.DEPLOY_POLICIES and token["revoked"]
    assert [t for e, t in fake.calls if e == "wrangler"] == [token["id"]]
    route = fake.route()
    assert route == {"id": route["id"], "pattern": dc.ROUTE, "script": dc.SCRIPT, "request_limit_fail_open": True}
    assert fake.count("route-put") == 1


def test_deploy_deploys_and_names_the_commit_it_read_before_minting(fake, cli, repository, tmp_path):
    first = git(repository, "rev-parse", "HEAD").strip()

    def commit():  # another session commits to worker/ while the token is minted
        (repository / "worker" / "index.js").write_text("// committed during the mint\n")
        git(repository, "commit", "-q", "-am", "during the mint")

    fake.on_mint = commit
    status, out, _ = cli("deploy")
    assert status == 0 and f"deployed worker/ of {first[:12]};" in out
    [run] = wrangler_runs(tmp_path)
    assert run["index.js"] == git(repository, "show", f"{first}:worker/index.js")


def test_a_put_that_changes_nothing_fails_the_deploy(fake, cli, repository, monkeypatch):
    monkeypatch.setattr(fake, "route_put", lambda match, query, body: {})
    status, _, err = cli("deploy")
    assert status == 1 and f"the route {dc.ROUTE} does not fail open after the PUT" in err


def test_a_missing_wrangler_is_reported_before_minting(fake, cli, repository, monkeypatch, tmp_path):
    monkeypatch.setenv("WRANGLER", str(tmp_path / "no-such-wrangler"))
    status, _, err = cli("deploy")
    assert status == 1 and "wrangler not found" in err and fake.calls == []


def test_a_failed_wrangler_still_gets_the_route_back_to_fail_open(fake, cli, repository, monkeypatch):
    monkeypatch.setenv("FAKE_WRANGLER_EXIT", "1")
    status, _, err = cli("deploy")
    assert status == 1 and "wrangler exited with 1" in err
    assert fake.count("route-put") == 1 and fake.route()["request_limit_fail_open"] is True
    assert all(t["revoked"] for t in fake.tokens.values())


def test_the_reads_before_wrangler_use_up_a_new_tokens_refusals(fake, cli, repository, tmp_path):
    fake.propagating = set(SERVICES)
    status, out, err = cli("deploy")
    assert status == 0, err
    assert len(wrangler_runs(tmp_path)) == 1 and fake.route()["request_limit_fail_open"] is True


def test_uncommitted_changes_in_worker_are_refused_before_minting(fake, cli, repository, tmp_path):
    (repository / "worker" / "index.js").write_text("// edited\n")
    status, _, err = cli("deploy")
    assert status == 1 and "commit first" in err
    assert fake.calls == [] and wrangler_runs(tmp_path) == []


def test_a_dry_run_reports_the_route_and_changes_nothing(fake, cli, repository, tmp_path):
    fake.route()["request_limit_fail_open"] = False
    status, out, _ = cli("deploy", "--dry-run")
    assert status == 0 and "route fails open: False; no route covers conda-ci.qiyuan.me" in out
    assert [run["argv"] for run in wrangler_runs(tmp_path)] == [["deploy", "--dry-run"]]
    assert fake.count("route-put") == 0


def test_a_route_covering_the_ci_address_fails_the_deploy(fake, cli, repository):
    fake.worker_routes.append({"id": "route-x", "pattern": "*.qiyuan.me/*", "script": "other",
                               "request_limit_fail_open": False})
    status, _, err = cli("deploy")
    assert status == 1 and "*.qiyuan.me/*" in err
    assert fake.route()["request_limit_fail_open"] is True


def test_route_calls_refused_with_10000_are_retried(fake, cli, repository):
    fake.refuse = {"routes": [10000, 10000], "route-put": [10000]}
    assert cli("deploy")[0] == 0
    assert fake.count("route-put") == 2 and fake.route()["request_limit_fail_open"] is True


def test_a_vanished_route_is_reported(fake, cli, repository):
    fake.worker_routes.clear()
    status, _, err = cli("deploy", "--dry-run")  # a deploy would recreate it
    assert status == 1 and f"the route {dc.ROUTE} is gone" in err
    assert all(t["revoked"] for t in fake.tokens.values())


# check

def test_check_flags_only_lines_that_download_from_the_users_address(tmp_path, cli):
    workflows = tmp_path / ".github" / "workflows"
    workflows.mkdir(parents=True)
    (workflows / "w.yml").write_text("\n".join([
        "# https://conda.qiyuan.me in a comment",
        "      - name: Install from https://conda.qiyuan.me",
        "  name: smoke https://conda.qiyuan.me",
        "  CHANNEL: https://conda-ci.qiyuan.me",
        "  PUBLIC: https://conda.qiyuan.me  # the users' address, not a download",
        "  https://conda.qiyuan.me.example.org/x",
        "        run: conda install -c https://conda.qiyuan.me x",
        "        description: from https://conda.qiyuan.me",
        "        curl -fsSL 'http://conda.qiyuan.me/noarch/repodata.json'",
        '        url="https://conda.qiyuan.me/$sub/$fn"',
        "        run: conda install -c https://conda.qiyuan.me x  # pinned",
    ]) + "\n")
    action = tmp_path / ".github" / "actions" / "x"
    action.mkdir(parents=True)
    (action / "action.yml").write_text("runs:\n  steps:\n    - run: micromamba install -c https://conda.qiyuan.me x\n")
    (tmp_path / ".github" / "ISSUE_TEMPLATE").mkdir()
    (tmp_path / ".github" / "ISSUE_TEMPLATE" / "bug.md").write_text("conda install -c https://conda.qiyuan.me x\n")
    status, out, _ = cli("check", str(tmp_path))
    github = tmp_path / ".github"
    assert status == 1
    assert out.splitlines() == [
        f"{github}/actions/x/action.yml:3: - run: micromamba install -c https://conda.qiyuan.me x",
        f"{github}/workflows/w.yml:7: run: conda install -c https://conda.qiyuan.me x",
        f"{github}/workflows/w.yml:8: description: from https://conda.qiyuan.me",
        f"{github}/workflows/w.yml:9: curl -fsSL 'http://conda.qiyuan.me/noarch/repodata.json'",
        f'{github}/workflows/w.yml:10: url="https://conda.qiyuan.me/$sub/$fn"',
        f"{github}/workflows/w.yml:11: run: conda install -c https://conda.qiyuan.me x  # pinned",
    ]


def test_check_of_a_clean_checkout_is_silent(tmp_path, cli):
    (tmp_path / ".github" / "workflows").mkdir(parents=True)
    (tmp_path / ".github" / "workflows" / "w.yml").write_text("  CHANNEL: https://conda-ci.qiyuan.me\n")
    assert cli("check", str(tmp_path)) == (0, "", "")


@pytest.mark.parametrize("where", ["typo", "subdirectory", "parent"])
def test_check_refuses_a_directory_without_workflows(tmp_path, cli, where):
    checkout = tmp_path / "checkout"
    (checkout / ".github" / "workflows").mkdir(parents=True)
    (checkout / "scripts").mkdir()
    path = {"typo": tmp_path / "checkuot", "subdirectory": checkout / "scripts", "parent": tmp_path}[where]
    status, out, err = cli("check", str(path))
    assert (status, out) == (1, "") and "has no .github/workflows" in err


def test_this_repositorys_workflows_download_from_the_ci_address(cli):
    assert cli("check", str(ROOT)) == (0, "", "")


# the Worker's route

def test_the_route_covers_the_users_address_and_not_the_ci_address():
    assert dc.route_matches(dc.ROUTE, "conda.qiyuan.me/noarch/x-1-0.conda")
    assert not dc.route_matches(dc.ROUTE, f"{dc.CI_HOST}/noarch/x-1-0.conda")


@pytest.mark.parametrize("pattern, host_and_path, matches", [
    ("*.qiyuan.me/*", "conda-ci.qiyuan.me/noarch/repodata.json", True),
    ("*conda.qiyuan.me/*", "conda-ci.qiyuan.me/noarch/repodata.json", False),
    ("conda.qiyuan.me/*", "conda-ci.qiyuan.me/noarch/repodata.json", False),
    ("*qiyuan.me/*", "conda-ci.qiyuan.me/noarch/repodata.json", True),
    ("https://conda-ci.qiyuan.me/*", "conda-ci.qiyuan.me/noarch/repodata.json", True),
    ("conda-ci.qiyuan.me/noarch/*", "conda-ci.qiyuan.me/noarch/repodata.json", True),
    ("conda-ci.qiyuan.me/linux-64/*", "conda-ci.qiyuan.me/noarch/repodata.json", False),
    ("conda-ci.qiyuan.me/noarch/repodata.json", "conda-ci.qiyuan.me/noarch/repodata.json", True),
    ("aoa.qiyuan.me/usage_counter*", "conda-ci.qiyuan.me/noarch/repodata.json", False),
])
def test_route_matches_like_cloudflare(pattern, host_and_path, matches):
    assert dc.route_matches(pattern, host_and_path) is matches
