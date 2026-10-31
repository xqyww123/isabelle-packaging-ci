"""Assert that a conda package's isa/ is the official Isabelle tree plus the packaging changes.

    check_pristine.py manifest <tree> <manifest.json>
        record the official tree (pack.sh, right after unpacking, before it changes anything)
    check_pristine.py compare <subdir> <manifest.json> <package.conda>

The comparison is against what users get: the sha256 of every file in the package's
info/paths.json, and the targets of its symlinks.  Every difference must match EXPECTED below;
any other one fails the check and is listed.  Directories are not compared: a conda payload has
no directory entries (pack.sh 1a).
"""
import hashlib
import json
import os
import re
import sys
import tarfile
import zipfile
from typing import IO

# What the package may differ in, per platform (conda subdir; "*" is every platform).
EXPECTED = {
    "changed": {"*": ["etc/settings",          # pack.sh 1d: a user directory per environment
                      "etc/options",           # pack.sh 1e: ML_system_64 = true
                      "etc/components"]},      # pack.sh 1f: no bundled nunchaku
    "added": {"*": [r"heaps/(?![^/]*_32-)[^/]+/.*",        # our 64-bit-word heaps (Jobs B-E)
                    r"(.*/)?\.conda-keep"],                 # pack.sh 5: empty directories
              "win-64": ["bin/isabelle.bat"]},              # pack.sh 1c: the Windows launcher
    "missing": {"*": [r"heaps/[^/]*_32-[^/]+/.*",           # the official 32-bit-word heaps
                      r"contrib/vscodium-[^/]+/.*/obj/.*",  # pack.sh 1b: MSBuild scratch
                      r"contrib/polyml-[^/]+/[^/]+/libpoly(ml|main)\.la"]},  # rattler-build drops *.la
}


def entries(kind: str, subdir: str) -> re.Pattern:
    patterns = EXPECTED[kind].get("*", []) + EXPECTED[kind].get(subdir, [])
    return re.compile("|".join(f"(?:{p})" for p in patterns))


def sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def manifest(tree: str) -> dict:
    """{relative path: ["file", sha256] | ["link", target]} for every non-directory under tree."""
    result = {}
    for root, dirs, files in os.walk(tree):
        for name in dirs + files:
            path = os.path.join(root, name)
            rel = os.path.relpath(path, tree).replace(os.sep, "/")
            if os.path.islink(path):
                result[rel] = ["link", os.readlink(path)]
            elif os.path.isfile(path):
                result[rel] = ["file", sha256(path)]
    return result


def unzstd(f: IO[bytes]) -> IO[bytes]:
    """A decompressing stream: the standard library's from Python 3.14, else the zstandard module."""
    try:
        from compression import zstd  # type: ignore[import-not-found]
        return zstd.ZstdFile(f)
    except ImportError:
        import zstandard
        return zstandard.ZstdDecompressor().stream_reader(f)  # type: ignore[return-value]


def package(conda: str) -> dict:
    """The same shape as manifest(), for the isa/ part of a .conda file."""
    with zipfile.ZipFile(conda) as z:
        names = z.namelist()
        info = next(n for n in names if n.startswith("info-"))
        pkg = next(n for n in names if n.startswith("pkg-"))
        with z.open(info) as f, tarfile.open(fileobj=unzstd(f), mode="r|") as t:
            paths = next(json.load(t.extractfile(m)) for m in t if m.name == "info/paths.json")  # type: ignore[arg-type]
        with z.open(pkg) as f, tarfile.open(fileobj=unzstd(f), mode="r|") as t:
            links = {m.name: m.linkname for m in t if m.issym()}
    result = {}
    for p in paths["paths"]:
        if p["_path"].startswith("isa/"):
            rel = p["_path"][len("isa/"):]
            result[rel] = ["link", links[p["_path"]]] if p["_path"] in links else ["file", p["sha256"]]
    return result


def compare(subdir: str, official: dict, shipped: dict) -> list:
    """The differences EXPECTED does not allow, one line each."""
    changed, added, missing = (entries(k, subdir) for k in ("changed", "added", "missing"))
    wrong = []
    for path in sorted(official.keys() | shipped.keys()):
        if path not in shipped:
            if not missing.fullmatch(path):
                wrong.append(f"missing from the package: {path}")
        elif path not in official:
            if not added.fullmatch(path):
                wrong.append(f"not in the official tree: {path}")
        elif official[path] != shipped[path] and not changed.fullmatch(path):
            wrong.append(f"differs from the official tree: {path}  {official[path]} -> {shipped[path]}")
    return wrong


def main(args: list) -> int:
    match args:
        case ["manifest", tree, out]:
            with open(out, "w") as f:
                json.dump(manifest(tree), f)
            return 0
        case ["compare", subdir, official, conda]:
            with open(official) as f:
                wrong = compare(subdir, json.load(f), package(conda))
            for line in wrong:
                print(f"::error::{line}")
            if wrong:
                print(f"::error::{len(wrong)} difference(s) from the official {subdir} tree that are not "
                      "packaging changes (scripts/check_pristine.py EXPECTED)")
                return 1
            print(f"OK: the package's isa/ is the official {subdir} tree plus the packaging changes")
            return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
