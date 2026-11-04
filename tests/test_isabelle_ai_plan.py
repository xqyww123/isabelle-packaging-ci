"""scripts/isabelle-ai-plan.py: floors in conda's order, the build number past indexed and
unindexed builds, the check of a built package, and plan end to end against a fake channel and a
fake rattler-build."""
import importlib.util
import json
import os
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "isabelle-ai-plan.py"
spec = importlib.util.spec_from_file_location("isabelle_ai_plan", SCRIPT)
assert spec and spec.loader
plan = importlib.util.module_from_spec(spec)
spec.loader.exec_module(plan)

PLANNED = {"ISABELLE_AI_VERSION": "0.4.0", "ISABELLE_AI_BUILD_NUMBER": "3",
           "ISABELLE_AI_FLOOR_MINILANG": "0.7.0", "ISABELLE_AI_FLOOR_MCP": "0.10.1",
           "ISABELLE_AI_FLOOR_SEMANTIC_DATA": "2026.10.09.0024"}
# As rattler-build writes it: the floors' versions normalised.
BUILT = {"name": "isabelle-ai", "version": "0.4.0", "build": "h4616a5c_3", "build_number": 3, "subdir": "noarch",
         "depends": ["isabelle-minilang >=0.7.0", "isabelle-mcp >=0.10.1", "isabelle-semantic-data >=2026.10.9.24"]}


def repodata(*rows, section="packages.conda"):
    """rows: (name, version, build number)."""
    return {section: {f"{name}-{version}-h4616a5c_{n}.conda": {"name": name, "version": version, "build_number": n}
                      for name, version, n in rows}}


DEPENDENCIES = repodata(("isabelle-minilang", "0.7.0", 0), ("isabelle-mcp", "0.9.0", 0), ("isabelle-mcp", "0.10.1", 0),
                        ("isabelle-mcp", "0.7.1", 2), ("isabelle-semantic-data", "2026.10.09.0024", 0),
                        ("isabelle-semantic-data", "2026.07.26.1711", 0),
                        ("json-spec", "0.13.0rc1", 0))    # unrelated, not dotted numbers: ignored


def test_versions_in_condas_order():
    assert plan.version_key("0.10.0") > plan.version_key("0.9.0")
    assert plan.version_key("2026.10.09.0024") == plan.version_key("2026.10.9.24")
    assert plan.version_key("1.0") == plan.version_key("1.0.0") == plan.version_key("1")
    assert plan.version_key("2026.10.09.0024") > plan.version_key("2026.10.09")
    for refused in ["0.8.0rc1", "1.0.post1", "1!2.0", "", "1..0", "v1.0"]:
        with pytest.raises(plan.Refused, match="not dotted numbers"):
            plan.version_key(refused)


def test_floors_are_the_newest_on_the_channel():
    indexed = {**repodata(("isabelle-minilang", "0.6.0", 0), section="packages"), **DEPENDENCIES}
    assert plan.floors(indexed) == {"isabelle-minilang": "0.7.0", "isabelle-mcp": "0.10.1",
                                    "isabelle-semantic-data": "2026.10.09.0024"}
    old_format = repodata(("isabelle-minilang", "0.8.0", 0), section="packages")
    assert plan.floors({**DEPENDENCIES, **old_format})["isabelle-minilang"] == "0.8.0"


def test_floors_refuse_a_missing_package_or_a_version_out_of_order():
    without = {"packages.conda": {fn: r for fn, r in DEPENDENCIES["packages.conda"].items()
                                  if r["name"] != "isabelle-mcp"}}
    with pytest.raises(plan.Refused, match="lists no isabelle-mcp"):
        plan.floors(without)
    with pytest.raises(plan.Refused, match="0.11.0rc1"):
        plan.floors({"packages": repodata(("isabelle-mcp", "0.11.0rc1", 0))["packages.conda"], **DEPENDENCIES})


def test_the_build_number_passes_indexed_and_unindexed_builds():
    probed = []

    def served(names):
        return lambda fn: probed.append(fn) or fn in names

    assert plan.build_number(DEPENDENCIES, "0.4.0", "h4616a5c", served(set())) == 0
    assert probed == ["isabelle-ai-0.4.0-h4616a5c_0.conda"]
    indexed = {**DEPENDENCIES, "packages": repodata(("isabelle-ai", "0.4.0", 0), ("isabelle-ai", "0.4.0", 2),
                                                    ("isabelle-ai", "0.5.0", 7), ("isabelle-mcp", "0.4.0", 9)
                                                    )["packages.conda"]}
    probed.clear()
    unindexed = {"isabelle-ai-0.4.0-h4616a5c_3.conda", "isabelle-ai-0.4.0-h4616a5c_4.conda",
                 "isabelle-ai-0.4.0-h4616a5c_6.conda"}
    assert plan.build_number(indexed, "0.4.0", "h4616a5c", served(unindexed)) == 5
    assert probed == [f"isabelle-ai-0.4.0-h4616a5c_{n}.conda" for n in (3, 4, 5)]
    # A version's builds count under every spelling of it.
    assert plan.build_number(indexed, "0.4", "h4616a5c", served(set())) == 3


def test_plan_renders_with_the_floors_and_build_0():
    rendered = []
    env = plan.plan(DEPENDENCIES, "0.4.0", lambda e: rendered.append(e) or "hdeadbee",
                    lambda fn: fn == "isabelle-ai-0.4.0-hdeadbee_0.conda")
    floors = {"ISABELLE_AI_FLOOR_MINILANG": "0.7.0", "ISABELLE_AI_FLOOR_MCP": "0.10.1",
              "ISABELLE_AI_FLOOR_SEMANTIC_DATA": "2026.10.09.0024"}
    assert rendered == [{**floors, "ISABELLE_AI_VERSION": "0.4.0", "ISABELLE_AI_BUILD_NUMBER": "0"}]
    assert env == {**floors, "ISABELLE_AI_BUILD_NUMBER": "1", "ISABELLE_AI_FILE": "isabelle-ai-0.4.0-hdeadbee_1.conda"}
    with pytest.raises(plan.Refused, match="not dotted numbers"):
        plan.plan(DEPENDENCIES, "0.4.0rc1", lambda e: "hdeadbee", lambda fn: False)


def test_check_accepts_the_planned_package():
    assert plan.check(BUILT, PLANNED) == []


@pytest.mark.parametrize("change, problem", [
    ({"build_number": 2}, "build_number is 2, not 3"),
    ({"version": "0.3.0"}, "version is '0.3.0', not '0.4.0'"),
    ({"name": "isabelle-aoa"}, "name is 'isabelle-aoa'"),
    ({"subdir": "linux-64"}, "subdir is 'linux-64', not 'noarch'"),
    ({"depends": BUILT["depends"][:2]}, "depends is"),
    ({"depends": [*BUILT["depends"], "isabelle >=2026"]}, "depends is"),
    ({"depends": [*BUILT["depends"], "isabelle"]}, "depends is"),
    ({"depends": [*BUILT["depends"], "isabelle-mcp >=0.10.1"]}, "depends is"),
    ({"depends": ["isabelle-minilang ==0.7.0", *BUILT["depends"][1:]]}, "depends is"),
    ({"depends": ["isabelle-minilang >=0.6.0", *BUILT["depends"][1:]]}, "the floor of isabelle-minilang is 0.6.0, not 0.7.0"),
])
def test_check_refuses_what_the_plan_did_not_say(change, problem):
    [found] = plan.check({**BUILT, **change}, PLANNED)
    assert problem in found


def test_check_needs_the_plan():
    without = {k: v for k, v in PLANNED.items() if k != "ISABELLE_AI_FLOOR_MCP"}
    assert plan.check(BUILT, without) == ["the plan's 'ISABELLE_AI_FLOOR_MCP' is not in the environment"]


class FakeChannel(ThreadingHTTPServer):
    """Serves files {path: bytes} by the path as requested (the channel serves nothing at //noarch/...);
    refuses urllib's default User-Agent as the edge does."""

    def __init__(self, files):
        super().__init__(("127.0.0.1", 0), ChannelHandler)
        self.url = f"http://127.0.0.1:{self.server_address[1]}"
        self.files = files
        self.requests = []    # (method, path)


class ChannelHandler(BaseHTTPRequestHandler):
    def answer(self, body):
        path = self.requestline.split()[1]    # self.path collapses a leading //
        self.server.requests.append((self.command, path))
        if self.headers.get("User-Agent", "").startswith("Python-urllib"):
            self.send_response(403)
            self.end_headers()
            return
        data = self.server.files.get(path)
        self.send_response(404 if data is None else 200)
        self.send_header("Content-Length", str(len(data or b"")))
        self.end_headers()
        if body and data:
            self.wfile.write(data)

    def do_GET(self):
        self.answer(True)

    def do_HEAD(self):
        self.answer(False)

    def log_message(self, *args):
        pass


@pytest.fixture
def channel():
    servers = []

    def start(files):
        server = FakeChannel(files)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        servers.append(server)
        return server

    yield start
    for server in servers:
        server.shutdown()
        server.server_close()


def test_get_names_itself_and_reads_only_404_as_nothing(channel, monkeypatch):
    server = channel({"/noarch/repodata.json": b"{}"})
    assert plan.get(f"{server.url}/noarch/repodata.json") == b"{}"
    assert plan.get(f"{server.url}/noarch/repodata.json", method="HEAD") == b""
    assert plan.get(f"{server.url}/noarch/missing.conda", method="HEAD") is None
    monkeypatch.setattr(plan, "USER_AGENT", "Python-urllib/3")
    with pytest.raises(plan.urllib.error.HTTPError, match="403"):
        plan.get(f"{server.url}/noarch/missing.conda", method="HEAD")
    assert server.requests == [("GET", "/noarch/repodata.json"), ("HEAD", "/noarch/repodata.json"),
                               ("HEAD", "/noarch/missing.conda"), ("HEAD", "/noarch/missing.conda")]


# Renders as rattler-build 0.69.1 does: the build string's hash part, then _<build number>.
FAKE_RATTLER_BUILD = f"""#!{sys.executable}
import json, os, sys
assert sys.argv[1:4] == ["build", "--recipe", {str(plan.RECIPE)!r}] and sys.argv[4:] == ["--render-only"], sys.argv
floors = [os.environ[v] for v in ("ISABELLE_AI_FLOOR_MINILANG", "ISABELLE_AI_FLOOR_MCP", "ISABELLE_AI_FLOOR_SEMANTIC_DATA")]
if os.environ.get("FAKE_RENDER_FAILS"):
    sys.exit("Template rendering failed")
print(json.dumps([{{"recipe": {{"build": {{"string": "h4616a5c_" + os.environ["ISABELLE_AI_BUILD_NUMBER"]}}}}}}]))
"""


def run_plan(tmp_path, url, **env):
    fake = tmp_path / "rattler-build"
    fake.write_text(FAKE_RATTLER_BUILD)
    fake.chmod(0o755)
    return subprocess.run([sys.executable, str(SCRIPT), "plan", "--rattler-build", str(fake), "--channel", url + "/"],
                          env={"PATH": os.environ["PATH"], **env}, capture_output=True, text=True)


def test_plan_end_to_end(tmp_path, channel):
    indexed = {**DEPENDENCIES, "packages": repodata(("isabelle-ai", "0.4.0", 0))["packages.conda"]}
    server = channel({"/noarch/repodata.json": json.dumps(indexed).encode(),
                      "/noarch/isabelle-ai-0.4.0-h4616a5c_1.conda": b"uploaded, never indexed"})
    run = run_plan(tmp_path, server.url, ISABELLE_AI_VERSION="0.4.0")
    assert (run.returncode, run.stderr) == (0, "")
    assert run.stdout == ("ISABELLE_AI_FLOOR_MINILANG=0.7.0\nISABELLE_AI_FLOOR_MCP=0.10.1\n"
                          "ISABELLE_AI_FLOOR_SEMANTIC_DATA=2026.10.09.0024\n"
                          "ISABELLE_AI_BUILD_NUMBER=2\nISABELLE_AI_FILE=isabelle-ai-0.4.0-h4616a5c_2.conda\n")
    assert server.requests == [("GET", "/noarch/repodata.json"),
                               ("HEAD", "/noarch/isabelle-ai-0.4.0-h4616a5c_1.conda"),
                               ("HEAD", "/noarch/isabelle-ai-0.4.0-h4616a5c_2.conda")]


@pytest.mark.parametrize("env, error", [
    ({}, "error: ISABELLE_AI_VERSION is not set"),
    ({"ISABELLE_AI_VERSION": "0.4.0", "FAKE_RENDER_FAILS": "1"}, "error: rattler-build cannot render"),
])
def test_plan_prints_nothing_when_it_fails(tmp_path, channel, env, error):
    server = channel({"/noarch/repodata.json": json.dumps(DEPENDENCIES).encode()})
    run = run_plan(tmp_path, server.url, **env)
    assert run.returncode == 1 and run.stdout == "" and run.stderr.startswith(error)


def test_check_end_to_end(tmp_path):
    index = tmp_path / "index.json"
    index.write_text(json.dumps(BUILT))
    run = subprocess.run([sys.executable, str(SCRIPT), "check", str(index)], capture_output=True, text=True,
                         env={"PATH": os.environ["PATH"], **PLANNED})
    assert (run.returncode, run.stdout) == (0, "")
    index.write_text(json.dumps({**BUILT, "build_number": 2}))
    run = subprocess.run([sys.executable, str(SCRIPT), "check", str(index)], capture_output=True, text=True,
                         env={"PATH": os.environ["PATH"], **PLANNED})
    assert (run.returncode, run.stdout) == (1, "::error::build_number is 2, not 3\n")
