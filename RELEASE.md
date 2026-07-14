# Releasing Isabelle to conda.qiyuan.me

### ☐ 1. Are the patches you develop against the ones that will actually ship?

```bash
scripts/check_patch_sync.sh
```

**CI installs the patch tool from a pinned PyPI version (`MBI_VERSION` in `build.yml`). It never
looks at your checkout.** So a patch you added locally and forgot to publish is a patch your users
will not get — while **CI goes green, the packages build, install, and run**. The Isabelle you ship
is simply not the one you tested. **Nothing else catches this.**

### ☐ 2. If the patch set changed, then you must do three things (all of them)

1. Publish a new version to **PyPI**.
2. Bump **`MBI_VERSION`** in `build.yml`.
3. Bump **`build_number`** (the `-f build_number=` below).

Step 3 is not a formality. The build string *is* that number — the hg changeset was dropped from it
to fit Windows' MAX_PATH (`conda/recipe.yaml:30`). So a changed patch set produces an
**identically named package**, and conda cannot tell it is new.

Forget it and `publish` will **refuse to overwrite an already-published filename**. That refusal is
the safety net, not a fault.

### ☐ 3. Release

```bash
gh workflow run release.yml --repo xqyww123/isabelle-packaging-ci -f build_number=<N>
# or:  git tag v2025.2 && git push origin v2025.2
```

---

## What that runs, unattended

```
build     Jobs A-H: fetch source -> patch -> build_release -> build heaps on all five
                    platforms -> package -> install and RUN each package on its own
                    platform, asserting the shipped heap loads and HOL is not rebuilt
publish   push to R2, then pull every package back from the CDN and check its sha256
smoke     on four clean runners, install from the real URL and run it:
            conda create -c https://conda.qiyuan.me --override-channels isabelle
            isabelle version
```

`smoke` is not a repeat of Jobs F-H. Those install from a *local* channel and prove the **packages**
work; `smoke` installs from the real URL and proves the **channel** does — that the bytes reached
R2, that `conda-index` named them correctly, and that conda's solver can act on it. Either can fail
while the other is green.

What a user then runs:

```bash
conda install -c https://conda.qiyuan.me isabelle
```

---

The evidence behind every decision here — and what is still unverified — is in `PACKAGING_DESIGN.md`.
