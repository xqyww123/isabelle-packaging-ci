"""scripts/check_pristine.py: which differences from the official tree it lets through."""
import gzip
import hashlib
import importlib.util
import os
import sys
from pathlib import Path

import pytest

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location(
    "check_pristine", Path(__file__).resolve().parent.parent / "scripts" / "check_pristine.py")
assert spec and spec.loader
cp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cp)

HEAP = "heaps/polyml-5.9.2_x86_64_32-linux/HOL"
POLYML_LA = "contrib/polyml-5.9.2-6/x86_64-linux/libpolyml.la"
PERMISSIONS = "contrib/cygwin/isabelle/permissions/755.gz"
SASL_LA = "contrib/cygwin/lib/sasl2_3/libplain.la"
EMPTY = "contrib/x/empty"
MARKER = f"{EMPTY}/.conda-keep"
MARKER_ENTRY = ["file", hashlib.sha256(cp.MARKER_BYTES).hexdigest()]
OFFICIAL = {
    "bin/isabelle": ["file", "a1"],
    "etc/settings": ["file", "s1"],
    "etc/options": ["file", "o1"],
    "etc/components": ["file", "c1"],
    "lib/link": ["link", "../bin/isabelle"],
    HEAP: ["file", "h"],
    POLYML_LA: ["file", "la"],
    EMPTY: ["empty"],
}
PACKAGED = {
    "bin/isabelle": ["file", "a1"],
    "etc/settings": ["file", "s2"],
    "etc/options": ["file", "o1"],
    "etc/components": ["file", "c2"],
    "lib/link": ["link", "../bin/isabelle"],
    HEAP: ["file", "h"],
    MARKER: MARKER_ENTRY,
}
WIN_OFFICIAL = {**OFFICIAL, PERMISSIONS: ["file", "p1"], SASL_LA: ["file", "la"]}
WIN_PACKAGED = {**PACKAGED, PERMISSIONS: ["file", "p2"], "bin/isabelle.bat": ["file", "b"]}

# One row per EXPECTED entry: its kind, platform and pattern, and the path it names in the win-64 fixtures.
NAMED = [
    ("changed", "*", "etc/settings", "etc/settings"),
    ("changed", "*", "etc/components", "etc/components"),
    ("changed", "win-64", r"contrib/cygwin/isabelle/permissions/755\.gz", PERMISSIONS),
    ("added", "win-64", "bin/isabelle.bat", "bin/isabelle.bat"),
    ("missing", "*", r"contrib/polyml-[^/]+/[^/]+/libpoly(ml|main)\.la", POLYML_LA),
    ("missing", "win-64", r"contrib/cygwin/lib/sasl2_3/lib[^/]+\.la", SASL_LA),
]
LINE = {"changed": "differs from the official tree: ", "added": "not in the official tree: ",
        "missing": "missing from the package: "}


def test_named_lists_every_expected_entry():
    assert sorted(row[:3] for row in NAMED) == sorted(
        (kind, subdir, p) for kind, by_subdir in cp.EXPECTED.items() for subdir, ps in by_subdir.items() for p in ps)


def test_the_packaging_changes_pass():
    assert cp.compare("linux-64", OFFICIAL, PACKAGED) == []


def test_the_windows_packaging_changes_pass_on_win_64():
    assert cp.compare("win-64", WIN_OFFICIAL, WIN_PACKAGED) == []


@pytest.mark.parametrize("change, line", [
    (lambda p: p.update({"bin/isabelle": ["file", "a2"]}), "differs from the official tree: bin/isabelle "),
    (lambda p: p.update({"etc/options": ["file", "o2"]}), "differs from the official tree: etc/options "),
    (lambda p: p.update({"lib/link": ["link", "elsewhere"]}), "differs from the official tree: lib/link "),
    (lambda p: p.update({"lib/link": ["file", "a1"]}), "differs from the official tree: lib/link "),
    (lambda p: p.update({HEAP: ["file", "h64"]}), f"differs from the official tree: {HEAP} "),
    (lambda p: p.pop(HEAP), f"missing from the package: {HEAP}"),
    (lambda p: p.pop("bin/isabelle"), "missing from the package: bin/isabelle"),
    (lambda p: p.update({"heaps/polyml-5.9.2_x86_64-linux/HOL": ["file", "h"]}),
     "not in the official tree: heaps/polyml-5.9.2_x86_64-linux/HOL"),
    (lambda p: p.update({"src/new.ML": ["file", "n"]}), "not in the official tree: src/new.ML"),
    (lambda p: p.update({"bin/isabelle.bat": ["file", "b"]}), "not in the official tree: bin/isabelle.bat"),
    (lambda p: p.pop(MARKER), f"missing from the package: {MARKER}"),
    (lambda p: p.update({MARKER: ["file", "k"]}), f"differs from the official tree: {MARKER} "),
    (lambda p: p.update({"bin/.conda-keep": MARKER_ENTRY}), "not in the official tree: bin/.conda-keep"),
])
def test_any_other_difference_fails(change, line):
    packaged = dict(PACKAGED)
    change(packaged)
    wrong = cp.compare("linux-64", OFFICIAL, packaged)
    assert len(wrong) == 1 and wrong[0].startswith(line), wrong


def with_difference(kind: str, path: str) -> tuple:
    """The win-64 fixtures, with a difference of this kind at path."""
    official, packaged = dict(WIN_OFFICIAL), dict(WIN_PACKAGED)
    official.pop(path, None)
    packaged.pop(path, None)
    if kind != "added":
        official[path] = ["file", "official"]
    if kind != "missing":
        packaged[path] = ["file", "packaged" if kind == "changed" else "official"]
    return official, packaged


@pytest.mark.parametrize("difference", LINE)
@pytest.mark.parametrize("row", NAMED, ids=lambda row: row[3])
def test_each_entry_allows_only_its_own_kind(row, difference):
    kind, _, _, path = row
    wrong = cp.compare("win-64", *with_difference(difference, path))
    if difference == kind:
        assert wrong == []
    else:
        assert any(w.startswith(LINE[difference] + path) for w in wrong), wrong


@pytest.mark.parametrize("row", NAMED, ids=lambda row: row[3])
def test_an_entry_that_names_nothing_fails(row):
    kind, _, pattern, path = row
    official, packaged = dict(WIN_OFFICIAL), dict(WIN_PACKAGED)
    official[path] = packaged[path] = ["file", "same"]
    wrong = cp.compare("win-64", official, packaged)
    assert len(wrong) == 1 and wrong[0].startswith(f"EXPECTED {kind} entry {pattern} names nothing"), wrong


# An entry matches the whole path, and only on its own platform.
@pytest.mark.parametrize("official, packaged, line", [
    ({**OFFICIAL, "contrib/jdk-25/etc/settings": ["file", "j1"]}, {**PACKAGED, "contrib/jdk-25/etc/settings": ["file", "j2"]},
     "differs from the official tree: contrib/jdk-25/etc/settings "),
    ({**OFFICIAL, "etc/settings.orig": ["file", "j1"]}, {**PACKAGED, "etc/settings.orig": ["file", "j2"]},
     "differs from the official tree: etc/settings.orig "),
    ({**OFFICIAL, f"src/x/{POLYML_LA}": ["file", "la"]}, PACKAGED, f"missing from the package: src/x/{POLYML_LA}"),
    ({**OFFICIAL, "contrib/other/lib/libfoo.la": ["file", "x"]}, PACKAGED,
     "missing from the package: contrib/other/lib/libfoo.la"),
    ({**OFFICIAL, SASL_LA: ["file", "la"]}, PACKAGED, f"missing from the package: {SASL_LA}"),
    ({**OFFICIAL, PERMISSIONS: ["file", "p1"]}, {**PACKAGED, PERMISSIONS: ["file", "p2"]},
     f"differs from the official tree: {PERMISSIONS} "),
])
def test_entries_match_whole_paths_on_their_own_platform(official, packaged, line):
    wrong = cp.compare("linux-64", official, packaged)
    assert any(w.startswith(line) for w in wrong), wrong


@pytest.mark.skipif(os.name == "nt", reason="symlinks")
def test_manifest_records_files_links_and_empty_directories(tmp_path):
    (tmp_path / "bin").mkdir()
    (tmp_path / "bin" / "isabelle").write_text("x")
    (tmp_path / "empty").mkdir()
    (tmp_path / "lib").symlink_to("bin")
    assert cp.manifest(str(tmp_path)) == {
        "bin/isabelle": ["file", "2d711642b726b04401627ca9fbac32f5c8530fb1903cc4db02258717921a4881"],
        "lib": ["link", "bin"],
        "empty": ["empty"]}


def test_markers_turn_the_official_tree_into_what_the_package_carries(tmp_path):
    (tmp_path / "bin").mkdir()
    (tmp_path / "bin" / "isabelle").write_text("x")
    (tmp_path / "var" / "tmp").mkdir(parents=True)
    (tmp_path / "home").mkdir()
    official = cp.manifest(str(tmp_path))
    assert cp.write_markers(str(tmp_path), official) == 2
    assert cp.manifest(str(tmp_path)) == cp.as_packaged(official)


def write_list(path: Path, entries: list):
    path.write_bytes(gzip.compress(b"".join(e.encode() + b"\0" for e in entries)))


def read_list(path: Path) -> list:
    return [e.decode() for e in gzip.decompress(path.read_bytes()).split(b"\0") if e]


def test_restrict_keeps_the_files_the_directories_above_them_and_the_tree():
    assert cp.restrict([".", "lib", "lib/sasl", "lib/sasl/plain.dll", "lib/x.la", "unmarked"],
                       {"lib/sasl/plain.dll"}) == [".", "lib", "lib/sasl", "lib/sasl/plain.dll"]


def test_permissions_keeps_only_what_ships(tmp_path):
    lists = tmp_path / "contrib" / "cygwin" / "isabelle" / "permissions"
    lists.mkdir(parents=True)
    (tmp_path / "lib" / "sasl").mkdir(parents=True)
    (tmp_path / "lib" / "sasl" / "plain.dll").write_text("d")
    (tmp_path / "unmarked").mkdir()                        # empty: conda ships no such directory
    write_list(lists / "755.gz", ["lib/sasl/plain.dll", "lib/sasl/libplain.la"])
    write_list(lists / "directories.gz", [".", "lib", "lib/sasl", "unmarked", "contrib"])
    write_list(lists / "644.gz", ["lib/sasl/plain.dll"])
    unchanged = (lists / "644.gz").read_bytes()
    cp.permissions(str(tmp_path))
    assert read_list(lists / "755.gz") == ["lib/sasl/plain.dll"]
    assert read_list(lists / "directories.gz") == [".", "lib", "lib/sasl", "contrib"]
    assert (lists / "644.gz").read_bytes() == unchanged    # a list naming only what ships keeps its bytes
