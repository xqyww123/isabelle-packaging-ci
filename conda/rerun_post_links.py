"""Re-run the post-link of every installed package that depends on `isabelle` directly.

The `isabelle` package's post-link runs this.  Re-installing isabelle (`--force-reinstall`, or a
new build) re-links every file of the package, which undoes the feature packages' patches in
$PREFIX/isa, and its pre-unlink deletes the Isabelle user directory with every component
registration in it; but conda runs only the hooks of the packages a transaction replaces, so
this is what brings them back (PACKAGING_DESIGN.md §11.2).  So every such post-link must be safe
to re-run (RELEASE_CHECKLIST.md §4).

Only direct dependents count, dependencies first.  Each script runs as conda runs a post-link
(run_script in conda/core/link.py): in the activated environment, which it inherits from the
isabelle post-link that runs this, from the script's directory with it first on PATH, and with
PKG_NAME, PKG_VERSION and PKG_BUILDNUM set.  Exit codes are ignored: one failing package must not
keep the others' registrations away.
"""
import json
import os
import subprocess
from pathlib import Path

WINDOWS = os.name == "nt"


def package(dep: str) -> str:
    """The package name of a `depends` entry such as `isabelle ==2026 0`."""
    return dep.split()[0]


def direct_dependents(prefix: Path) -> dict:
    """The conda-meta records of the installed packages whose `depends` names `isabelle`."""
    records = (json.loads(p.read_text(encoding="utf-8")) for p in (prefix / "conda-meta").glob("*.json"))
    return {r["name"]: r for r in records if any(package(d) == "isabelle" for d in r.get("depends", []))}


def dependencies_first(records: dict) -> list:
    order, seen = [], set()

    def visit(name):
        if name not in seen:
            seen.add(name)
            for dep in records[name].get("depends", []):
                if package(dep) in records:
                    visit(package(dep))
            order.append(name)
    for name in sorted(records):
        visit(name)
    return order


def main(prefix: Path) -> None:
    records = direct_dependents(prefix)
    for name in dependencies_first(records):
        if WINDOWS:
            script = prefix / "Scripts" / f".{name}-post-link.bat"
            command = [os.environ.get("COMSPEC", "cmd.exe"), "/d", "/c", str(script)]
        else:
            script = prefix / "bin" / f".{name}-post-link.sh"
            command = ["bash", str(script)]
        if script.is_file():
            subprocess.run(command, cwd=script.parent, env={
                **os.environ, "PREFIX": str(prefix), "PKG_NAME": name,
                "PKG_VERSION": records[name]["version"], "PKG_BUILDNUM": str(records[name]["build_number"]),
                "PATH": os.pathsep.join((str(script.parent), os.environ.get("PATH", "")))})


if __name__ == "__main__":
    main(Path(os.environ["PREFIX"]))
