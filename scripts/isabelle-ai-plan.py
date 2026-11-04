#!/usr/bin/env python3
"""isabelle-ai's floors and build number, from the channel's index (release-isabelle-ai.yml).

    ISABELLE_AI_VERSION=<version> python3 scripts/isabelle-ai-plan.py plan [--rattler-build <path>] [--channel <url>]
    python3 scripts/isabelle-ai-plan.py check <the built package's info/index.json>

plan prints lines for $GITHUB_ENV: each floor of the recipe (the newest version of that package that
the channel's noarch/repodata.json lists), the build number and the package's file name. The build
number follows the patch tool's rule (its tools/common.py, plan_builds): one above the highest build of
the version that the index lists (0 when it lists none), and past every file of the version that the
channel serves but has not indexed (a publish that uploaded it and then failed), probed by file name
upwards. The build string's prefix is the one rattler-build renders for the recipe.

check prints what in the built package differs from the plan, which it reads back from the environment.

Versions are compared as conda compares dotted numbers (07 == 7, 1.0 == 1.0.0). Any other version of
these packages on the channel is refused, so that a pre-release never becomes a floor unseen.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

NAME = "isabelle-ai"
RECIPE = Path(__file__).resolve().parent.parent / "conda" / "metapackage" / "isabelle-ai" / "recipe.yaml"
# Our pipelines' address of the channel, which the download counter does not count (CHANNEL_OPERATIONS.md).
CHANNEL = "https://conda-ci.qiyuan.me"
# The edge refuses urllib's default User-Agent (HTTP 403).
USER_AGENT = "isabelle-packaging-ci-isabelle-ai-plan"
# Each run requirement of the recipe -> the environment variable that carries its floor.
FLOORS = {"isabelle-minilang": "ISABELLE_AI_FLOOR_MINILANG",
          "isabelle-mcp": "ISABELLE_AI_FLOOR_MCP",
          "isabelle-semantic-data": "ISABELLE_AI_FLOOR_SEMANTIC_DATA"}


class Refused(Exception):
    pass


def version_key(version):
    """conda's order of versions that are dotted numbers."""
    if not re.fullmatch(r"\d+(\.\d+)*", version):
        raise Refused(f"version {version!r} is not dotted numbers; tell the owner")
    parts = [int(part) for part in version.split(".")]
    while len(parts) > 1 and parts[-1] == 0:
        parts.pop()
    return tuple(parts)


def records(repodata):
    return [*repodata.get("packages", {}).values(), *repodata.get("packages.conda", {}).values()]


def floors(repodata):
    """{run requirement: the newest version of it that the index lists}."""
    newest = {}
    for name in FLOORS:
        versions = [r["version"] for r in records(repodata) if r.get("name") == name]
        if not versions:
            raise Refused(f"the channel's noarch index lists no {name}")
        newest[name] = max(versions, key=version_key)
    return newest


def filename(version, prefix, n):
    return f"{NAME}-{version}-{prefix}_{n}.conda"


def build_number(repodata, version, prefix, served):
    """served(file name) says whether the channel serves that file."""
    n = max((int(r["build_number"]) for r in records(repodata)
             if r.get("name") == NAME and version_key(r["version"]) == version_key(version)), default=-1) + 1
    while served(filename(version, prefix, n)):
        n += 1
    return n


def plan(repodata, version, render, served):
    """The environment the recipe is built with. render(environment) is the build string's prefix."""
    version_key(version)
    env = {FLOORS[name]: v for name, v in floors(repodata).items()}
    prefix = render({**env, "ISABELLE_AI_VERSION": version, "ISABELLE_AI_BUILD_NUMBER": "0"})
    n = build_number(repodata, version, prefix, served)
    return {**env, "ISABELLE_AI_BUILD_NUMBER": str(n), "ISABELLE_AI_FILE": filename(version, prefix, n)}


def check(index, environ):
    """What in a built package's info/index.json differs from the plan in environ."""
    try:
        want = {"name": NAME, "version": environ["ISABELLE_AI_VERSION"],
                "build_number": int(environ["ISABELLE_AI_BUILD_NUMBER"]), "subdir": "noarch"}
        floor = {name: environ[var] for name, var in FLOORS.items()}
    except KeyError as missing:
        return [f"the plan's {missing} is not in the environment"]
    problems = [f"{key} is {index.get(key)!r}, not {value!r}" for key, value in want.items() if index.get(key) != value]
    depends = index.get("depends", [])
    pairs = [m.groups() for d in depends if (m := re.fullmatch(r"(\S+) >=(\S+)", d))]
    if len(pairs) != len(depends) or sorted(name for name, _ in pairs) != sorted(FLOORS):
        return problems + [f"depends is {depends}, not one `<package> >=<floor>` for each of {sorted(FLOORS)}"]
    return problems + [f"the floor of {name} is {v}, not {floor[name]}"
                       for name, v in pairs if version_key(v) != version_key(floor[name])]


def get(url, method="GET"):
    """The body at url, b"" for a HEAD; None when the channel serves nothing there."""
    try:
        with urllib.request.urlopen(urllib.request.Request(url, method=method, headers={"User-Agent": USER_AGENT}),
                                    timeout=120) as response:
            return response.read()
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise


def render(rattler_build, env):
    """The build string's prefix (without _<n>) that rattler-build renders for the recipe."""
    run = subprocess.run([rattler_build, "build", "--recipe", str(RECIPE), "--render-only"],
                         env={**os.environ, **env}, capture_output=True, text=True)
    if run.returncode != 0:
        raise Refused(f"rattler-build cannot render {RECIPE}:\n{run.stderr}")
    [output] = json.loads(run.stdout)
    return output["recipe"]["build"]["string"].rsplit("_", 1)[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    planning = commands.add_parser("plan", help="print the floors, the build number and the file name")
    planning.add_argument("--rattler-build", default="rattler-build", metavar="path")
    planning.add_argument("--channel", default=CHANNEL, metavar="url")
    commands.add_parser("check", help="compare a built package with the plan in the environment").add_argument(
        "index", type=Path, help="the package's info/index.json")
    args = parser.parse_args()
    try:
        if args.command == "plan":
            if "ISABELLE_AI_VERSION" not in os.environ:
                raise Refused("ISABELLE_AI_VERSION is not set")
            channel = args.channel.rstrip("/")
            repodata = json.loads(get(f"{channel}/noarch/repodata.json") or b"{}")
            env = plan(repodata, os.environ["ISABELLE_AI_VERSION"], lambda e: render(args.rattler_build, e),
                       lambda fn: get(f"{channel}/noarch/{fn}", method="HEAD") is not None)
            print("".join(f"{key}={value}\n" for key, value in env.items()), end="")
        else:
            problems = check(json.loads(args.index.read_text()), os.environ)
            for problem in problems:
                print(f"::error::{problem}")
            sys.exit(1 if problems else 0)
    except Refused as error:
        sys.exit(f"error: {error}")


if __name__ == "__main__":
    main()
