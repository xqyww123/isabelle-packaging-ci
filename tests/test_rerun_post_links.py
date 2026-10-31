"""conda/rerun_post_links.py on a fake prefix: which post-links it re-runs, in what order, with what."""
import importlib.util
import json
import os
import sys
from pathlib import Path

import pytest

# conda/ is the recipe directory, and rattler-build ships all of it in info/recipe/: no __pycache__ there.
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location(
    "rerun_post_links", Path(__file__).resolve().parent.parent / "conda" / "rerun_post_links.py")
assert spec and spec.loader
rerun = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rerun)

pytestmark = pytest.mark.skipif(os.name == "nt", reason="the fake post-links are bash scripts")


def install(prefix: Path, name: str, depends: list, version="1.0", build_number=0, script=True, rc=0):
    (prefix / "conda-meta").mkdir(parents=True, exist_ok=True)
    (prefix / "conda-meta" / f"{name}-{version}-{build_number}.json").write_text(json.dumps(
        {"name": name, "version": version, "build_number": build_number, "depends": depends}))
    if script:
        (prefix / "bin").mkdir(exist_ok=True)
        (prefix / "bin" / f".{name}-post-link.sh").write_text(
            f'echo "$PKG_NAME $PKG_VERSION $PKG_BUILDNUM $PREFIX $PWD" >> "$PREFIX/ran"\nexit {rc}\n')


def ran(prefix: Path) -> list:
    f = prefix / "ran"
    return f.read_text().splitlines() if f.exists() else []


def test_reruns_the_direct_dependents_dependencies_first(tmp_path):
    install(tmp_path, "isabelle", ["python"])
    install(tmp_path, "a-feature", ["isabelle ==2026 0", "z-base ==1.0 0"], version="2.0", build_number=3)
    install(tmp_path, "z-base", ["isabelle ==2026 0"])
    install(tmp_path, "semantic-data", ["a-feature"])               # depends on isabelle only indirectly
    install(tmp_path, "python", [])
    rerun.main(tmp_path)
    bin_ = tmp_path / "bin"
    assert ran(tmp_path) == [f"z-base 1.0 0 {tmp_path} {bin_}", f"a-feature 2.0 3 {tmp_path} {bin_}"]


def test_a_failing_post_link_does_not_stop_the_others(tmp_path):
    install(tmp_path, "isabelle", [])
    install(tmp_path, "a", ["isabelle"], rc=1)
    install(tmp_path, "b", ["isabelle"])
    rerun.main(tmp_path)
    assert [line.split()[0] for line in ran(tmp_path)] == ["a", "b"]


def test_a_dependent_without_a_post_link_is_skipped(tmp_path):
    install(tmp_path, "isabelle", [])
    install(tmp_path, "a", ["isabelle"], script=False)
    install(tmp_path, "b", ["isabelle"])
    rerun.main(tmp_path)
    assert [line.split()[0] for line in ran(tmp_path)] == ["b"]


def test_the_script_directory_is_first_on_path(tmp_path):
    install(tmp_path, "isabelle", [])
    install(tmp_path, "a", ["isabelle"])
    (tmp_path / "bin" / ".a-post-link.sh").write_text('echo "${PATH%%:*}" >> "$PREFIX/ran"\n')
    rerun.main(tmp_path)
    assert ran(tmp_path) == [str(tmp_path / "bin")]
