"""scripts/check_pristine.py: which differences from the official tree it lets through."""
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
PERMISSIONS = "contrib/cygwin/isabelle/permissions/755.gz"
SASL_LA = "contrib/cygwin/lib/sasl2_3/libplain.la"
OFFICIAL = {
    "bin/isabelle": ["file", "a1"],
    "etc/settings": ["file", "s1"],
    "etc/options": ["file", "o1"],
    "etc/components": ["file", "c1"],
    "lib/link": ["link", "../bin/isabelle"],
    HEAP: ["file", "h"],
    "contrib/polyml-5.9.2-6/x86_64-linux/libpolyml.la": ["file", "la"],
    "contrib/vscodium-1.135/x86_64-windows/resources/app/obj/x.tlog": ["file", "t"],
}
PACKAGED = {
    "bin/isabelle": ["file", "a1"],
    "etc/settings": ["file", "s2"],
    "etc/options": ["file", "o1"],
    "etc/components": ["file", "c2"],
    "lib/link": ["link", "../bin/isabelle"],
    HEAP: ["file", "h"],
    "contrib/x/empty/.conda-keep": ["file", "k"],
}
WIN_OFFICIAL = {**OFFICIAL, PERMISSIONS: ["file", "p1"], SASL_LA: ["file", "la"]}
WIN_PACKAGED = {**PACKAGED, PERMISSIONS: ["file", "p2"], "bin/isabelle.bat": ["file", "b"]}


def test_the_packaging_changes_pass():
    assert cp.compare("linux-64", OFFICIAL, PACKAGED) == []


def test_the_windows_packaging_changes_pass_on_win_64():
    assert cp.compare("win-64", WIN_OFFICIAL, WIN_PACKAGED) == []


@pytest.mark.parametrize("change, kind", [
    (lambda p: p.update({"bin/isabelle": ["file", "a2"]}), "differs"),
    (lambda p: p.update({"etc/options": ["file", "o2"]}), "differs"),
    (lambda p: p.update({"lib/link": ["link", "elsewhere"]}), "differs"),
    (lambda p: p.update({"lib/link": ["file", "a1"]}), "differs"),
    (lambda p: p.update({HEAP: ["file", "h64"]}), "differs"),
    (lambda p: p.pop(HEAP), "missing"),
    (lambda p: p.pop("bin/isabelle"), "missing"),
    (lambda p: p.update({"heaps/polyml-5.9.2_x86_64-linux/HOL": ["file", "h"]}), "not in the official"),
    (lambda p: p.update({"src/new.ML": ["file", "n"]}), "not in the official"),
    (lambda p: p.update({"bin/isabelle.bat": ["file", "b"]}), "not in the official"),     # win-64 only
    (lambda p: p.update({"contrib/x/empty/.conda-keep.sh": ["file", "k"]}), "not in the official"),
])
def test_any_other_difference_fails(change, kind):
    packaged = dict(PACKAGED)
    change(packaged)
    wrong = cp.compare("linux-64", OFFICIAL, packaged)
    assert len(wrong) == 1 and kind in wrong[0]


@pytest.mark.parametrize("official, packaged", [
    ({**OFFICIAL, "contrib/other/lib/libfoo.la": ["file", "x"]}, PACKAGED),                   # only polyml's
    ({**OFFICIAL, SASL_LA: ["file", "la"]}, PACKAGED),                                        # win-64 only
    ({**OFFICIAL, PERMISSIONS: ["file", "p1"]}, {**PACKAGED, PERMISSIONS: ["file", "p2"]}),   # win-64 only
])
def test_the_windows_and_named_exceptions_do_not_reach_further(official, packaged):
    assert len(cp.compare("linux-64", official, packaged)) == 1


@pytest.mark.skipif(os.name == "nt", reason="symlinks")
def test_manifest_records_files_and_links(tmp_path):
    (tmp_path / "bin").mkdir()
    (tmp_path / "bin" / "isabelle").write_text("x")
    (tmp_path / "empty").mkdir()
    (tmp_path / "lib").symlink_to("bin")
    m = cp.manifest(str(tmp_path))
    assert m == {"bin/isabelle": ["file", "2d711642b726b04401627ca9fbac32f5c8530fb1903cc4db02258717921a4881"],
                 "lib": ["link", "bin"]}
