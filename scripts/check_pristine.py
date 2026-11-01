"""Assert that a conda package's isa/ is the official Isabelle tree plus the packaging changes.

    check_pristine.py manifest <tree> <manifest.json>
        record the official tree (pack.sh step 1a, before anything changes it)
    check_pristine.py markers <tree> <manifest.json>
        put the empty marker into each officially empty directory (pack.sh step 2)
    check_pristine.py permissions <tree>
        win-64: make Cygwin's permission lists name only what ships (pack.sh step 3)
    check_pristine.py compare <subdir> <manifest.json> <package.conda>

The comparison is against what users get: the sha256 of every file in the package's
info/paths.json, and the targets of its symlinks.  A conda payload has no directories, so an
officially empty directory must come back holding pack.sh's empty marker (step 2).  Every other
difference must be named in EXPECTED, and every entry there must name one: anything else fails
the check and is listed.  File modes are not compared: rattler-build writes 0644, or 0755 for a
file its owner may execute, so the release's read-only sources ship writable on Unix (on
win-64, Cygwin's postinstall sets them from its permission lists).
"""
import gzip
import hashlib
import json
import os
import re
import sys
import tarfile
import zipfile
from typing import IO, Iterator

MARKER, MARKER_BYTES = ".conda-keep", b""

# What the package differs in, per platform (conda subdir; "*" is every platform).
EXPECTED = {
    "changed": {"*": ["etc/settings",           # pack.sh 1c: a user directory per environment
                      "etc/components"],        # pack.sh 1d: no bundled nunchaku
                "win-64": [r"contrib/cygwin/isabelle/permissions/755\.gz"]},  # pack.sh 3: no *.la
    "added": {"win-64": ["bin/isabelle.bat"]},  # pack.sh 1b: the Windows launcher
    "missing": {"*": [r"contrib/polyml-[^/]+/[^/]+/libpoly(ml|main)\.la"],  # pack.sh 1e: libtool archives
                "win-64": [r"contrib/cygwin/lib/sasl2_3/lib[^/]+\.la"]},    # pack.sh 1e
}


def entries(kind: str, subdir: str) -> list:
    return EXPECTED[kind].get("*", []) + EXPECTED[kind].get(subdir, [])


def sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def shipped(tree: str) -> Iterator[tuple]:
    """(relative path, path) of every file and symlink under tree: what a conda payload carries."""
    for root, dirs, files in os.walk(tree):
        for name in dirs + files:
            path = os.path.join(root, name)
            if os.path.islink(path) or os.path.isfile(path):
                yield os.path.relpath(path, tree).replace(os.sep, "/"), path


def manifest(tree: str) -> dict:
    """{relative path: ["file", sha256] | ["link", target] | ["empty"]}, the last for empty directories."""
    result = {rel: ["link", os.readlink(path)] if os.path.islink(path) else ["file", sha256(path)]
              for rel, path in shipped(tree)}
    for root, dirs, files in os.walk(tree):
        if root != tree and not dirs and not files:
            result[os.path.relpath(root, tree).replace(os.sep, "/")] = ["empty"]
    return result


def markers(official: dict) -> list:
    """Where the empty markers go: into each empty directory of the manifest."""
    return [f"{p}/{MARKER}" for p, v in official.items() if v == ["empty"]]


def write_markers(tree: str, official: dict) -> int:
    paths = markers(official)
    for m in paths:
        path = os.path.join(tree, m)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(MARKER_BYTES)
    return len(paths)


def restrict(listed: list, files: set) -> list:
    """The entries of a Cygwin permission list that name a shipped path: one of `files` (relative
    paths, as shipped() yields them), a directory above one (conda creates no other), or the tree."""
    keep = {"."}
    for rel in files:
        while rel:
            keep.add(rel)
            rel = rel.rpartition("/")[0]
    return [p for p in listed if p in keep]


def permissions(tree: str) -> None:
    files = {rel for rel, _ in shipped(tree)}
    lists = os.path.join(tree, "contrib", "cygwin", "isabelle", "permissions")
    for name in sorted(os.listdir(lists)):
        path = os.path.join(lists, name)
        with gzip.open(path) as f:
            listed = [os.fsdecode(p) for p in f.read().split(b"\0") if p]
        kept = restrict(listed, files)
        if kept != listed:                      # an unchanged list keeps its official bytes
            with open(path, "wb") as f:
                f.write(gzip.compress(b"".join(os.fsencode(p) + b"\0" for p in kept), mtime=0))
        print(f"{name}: kept {len(kept)} of {len(listed)} path(s)")


def unzstd(f: IO[bytes]) -> IO[bytes]:
    """A decompressing stream: the standard library's from Python 3.14, else the zstandard module."""
    try:
        from compression import zstd  # type: ignore[import-not-found]
        return zstd.ZstdFile(f)
    except ImportError:
        import zstandard
        return zstandard.ZstdDecompressor().stream_reader(f)  # type: ignore[return-value]


def package(conda: str) -> dict:
    """The same shape as manifest(), for the isa/ part of a .conda file (which has no ["empty"])."""
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


def as_packaged(official: dict) -> dict:
    """The official tree as a conda package carries it: each empty directory holds the marker."""
    marker = ["file", hashlib.sha256(MARKER_BYTES).hexdigest()]
    return {p: v for p, v in official.items() if v != ["empty"]} | {m: marker for m in markers(official)}


def compare(subdir: str, official: dict, packaged: dict) -> list:
    """The differences EXPECTED does not name, and the entries of EXPECTED that name none, one line each."""
    expected = as_packaged(official)
    unused = {(kind, p) for kind in EXPECTED for p in entries(kind, subdir)}

    def named(kind, path):
        p = next((p for p in entries(kind, subdir) if re.fullmatch(p, path)), None)
        unused.discard((kind, p))
        return p is not None
    wrong = []
    for path in sorted(expected.keys() | packaged.keys()):
        if path not in packaged:
            if not named("missing", path):
                wrong.append(f"missing from the package: {path}")
        elif path not in expected:
            if not named("added", path):
                wrong.append(f"not in the official tree: {path}")
        elif expected[path] != packaged[path] and not named("changed", path):
            wrong.append(f"differs from the official tree: {path}  {expected[path]} -> {packaged[path]}")
    return wrong + [f"EXPECTED {kind} entry {p} names nothing in the {subdir} package" for kind, p in sorted(unused)]


def main(args: list) -> int:
    match args:
        case ["manifest", tree, out]:
            with open(out, "w") as f:
                json.dump(manifest(tree), f)
            return 0
        case ["markers", tree, official]:
            with open(official) as f:
                n = write_markers(tree, json.load(f))
            print(f"restored {n} empty directory(ies) via {MARKER} markers")
            return 0
        case ["permissions", tree]:
            permissions(tree)
            return 0
        case ["compare", subdir, official, conda]:
            with open(official) as f:
                wrong = compare(subdir, json.load(f), package(conda))
            for line in wrong:
                print(f"::error::{line}")
            if wrong:
                print(f"::error::the {subdir} package's isa/ is not the official tree plus exactly the packaging "
                      "changes (scripts/check_pristine.py EXPECTED)")
                return 1
            print(f"OK: the package's isa/ is the official {subdir} tree plus the packaging changes")
            return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
