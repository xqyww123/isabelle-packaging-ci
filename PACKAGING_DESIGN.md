# Isabelle + AoA packaging and release plan (empirically verified edition)

> **Status of this document**: this is the **authoritative reference** for packaging and releasing. A round of work on
> 2026-07-11/12 **overturned and rewrote** the earlier design — the old plan (reuse the Isabelle that users already have
> installed + a conda post-link that writes global settings) is void; the reasons are in §9.
> Every conclusion in this document is marked with its **source of evidence**; everything marked "measured" was run on a
> real machine / real CI, not inferred.
>
> **For the state from 2026-10-31 on (Isabelle2026), see §11.** In one sentence: the `isabelle` package is **the official
> platform bundle as it is** (together with the Pure/HOL heaps that come with the official bundle), plus a few packaging
> changes; the CI no longer builds anything itself and applies no patches, and patches are distributed by feature packages
> instead. §1, §2, §4, §5.0–5.2, §7.9 and §7.11 describe the Isabelle2025-2-era approach of "building a patched version
> ourselves"; they are kept as a record, and each of those sections says so at its start.

---

## 1. Goal

Release the AoA toolchain under `contrib/` (`Isa-Mini`, `Isa-REPL`, `Isabelle_RPC`, `Semantic_Embedding`,
`Performant_Isabelle_ML`, `auto_sledgehammer`), so that users can install it and `by aoa` in Isabelle.

【No longer true from 2026-10-31 on: patches are distributed by feature packages instead, and the `isabelle` package is
unpatched; see §11.】

Prerequisite fact: the Isabelle that AoA depends on **must carry the patches of `my_better_isabelle_prover`**
(`register_thy` is a hard dependency of Isa-REPL, `pide_control` a hard dependency of Isabelle-MCP).
So "releasing AoA" unavoidably means "releasing a patched Isabelle".

---

## 2. Core decision

【The decision of the Isabelle2025-2 era, superseded by §11 from 2026-10-31 on: we no longer build anything ourselves, we
package the official platform bundles directly.】

**We run our own official-grade release pipeline for a "patched Isabelle", produce a complete bundle for each platform,
and publish them to conda.**

- Take the exact changeset of a release from the **official hg repository**;
- apply our patches and **`hg commit`**;
- run **the official `Admin/build_release`** (no reinventing the wheel);
- for each platform, produce a bundle with the same structure as the official one (including a **prebuilt, patched HOL
  heap**);
- automate it with GitHub CI;
- package the bundles as conda packages and publish them to a self-hosted channel.

Three hard facts that support this decision (details in §3):
1. **For conda to manage it cleanly, the files must be inside the package** — conda does not track anything a post-link
   downloads at all.
2. **Heaps differ per platform and cannot be shared**, and **the official bundles already ship a prebuilt HOL heap** — to
   give an official-grade experience, we have to build the patched heap ourselves, once per platform.
3. **The patches change Pure/ML and Scala**, and take effect only through `scala_build` and `build_heaps` —
   which `build_release` does by its nature.

---

## 3. List of empirical facts (the foundation of this plan)

### 3.1 conda mechanics

| Fact | Evidence |
|---|---|
| post-link **cannot be interactive** | `Popen(stdout=PIPE)` + `communicate()`, `stdin=None` (`conda/gateways/subprocess.py:58,62`) |
| post-link's **stdout is not reliably shown on success** | the conda-build documentation says explicitly "do not write to stdout/stderr unless there is an error" |
| **conda does not track files a post-link creates in `$PREFIX`** | not in the package's `info/files` → `conda remove` does not delete them, `conda list` does not show them, not reproducible |
| **pre-unlink is not guaranteed to run** | when users delete an env directory directly, the packages' scripts are not run one by one → external side effects may remain forever |
| ⇒ **"conda manages it cleanly" ⟺ "the files are inside the package"** | this is mechanism, not policy |
| **the industry has abandoned "post-link downloads"** | `cudatoolkit-dev` (downloads in post-link) **was archived on 2025-10-01**; modern CUDA puts all files into packages, split with `outputs` + aggregated by a metapackage |
| conda-build's rules for post-link | "avoid it if you can", "touch only the files being installed", "depend only on rm/cp/mv/ln" |
| conda-forge constraints | offline builds + SHA256 locking + the channel cannot be deleted from or altered (reproducible) |

### 3.2 conda naming and versions

- A package's identity = the three parts **`name-version-build`**, separated by `-` ⇒ **a version cannot contain `-`**.
- ⇒ **`Isabelle2025-2` must be written as conda version `2025.2`**.
- The build string **is only the build number** (every character of it costs Windows MAX_PATH, §3.6); the official
  changeset is in the package description and in `isa/etc/ISABELLE_ID`. The version is derived from the release name
  (`Isabelle2026` → `2026`), computed in one place only, `scripts/pack.sh`.
- **Changed content in the same version ⇒ bump the build number** (`_0` → `_1`); never overwrite in place with `--force`
  (clients cache by filename, so users would get the old package).
- Ordering: conda's own VersionOrder (numeric parts compare by value; `dev` is special; an epoch `N!` has the highest
  priority).
- **The package name `isabelle` is completely free** (measured with the anaconda.org API: `conda-forge/isabelle` → 404; a
  site-wide search for `name=isabelle` finds only `isabelle-client`, which is a different name). Moreover, conda package
  names are **namespaced per channel**; there is no global claim on a name.

### 3.3 conda channel — **self-hosted, on Cloudflare R2**

- **Only the channel owner can upload.** To let several people publish ⇒ create an **Organization** and add the
  maintainers as members.
- **Others need no permission from you** to publish packages on their own channel that depend on yours. But **conda
  resolves dependencies by package name, not bound to a channel** ⇒ **the installer must be able to see your channel**
  (`-c <your channel>` or in `.condarc`), otherwise `PackagesNotFoundError`.
  A downstream author **cannot weld the source of a dependency into the package** — making the channel discoverable is
  the end users' responsibility.

#### ❌ anaconda.org cannot host us (verified)
- **A free account has only 3 GB of package storage** (the official FAQ verbatim: "up to 3GB of storage space for any
  packages you upload").
- **Paying does not offer a self-service way to get more either**: on the pricing page's FREE / $15 / $50 / Custom, the
  storage numbers (5/10/20 GB) **are "cloud notebook storage", not anaconda.org's package hosting quota**; the official
  documentation **does not mention at all** that paying adds package storage.
- Our need: the `isabelle` package is **~1 GB × 4 platforms ≈ 4 GB / per version**, and it **accumulates per version and
  build number**.
  ⇒ **3 GB does not hold even one version; it would overflow the moment we go live.**

#### ✅ Decision: a self-hosted channel, statically hosted on R2
A conda channel is essentially **a tree of static files + a `repodata.json` per platform**; any HTTP server can serve as a
channel.

| Item | Value |
|---|---|
| **R2 bucket** | **`conda`** (a new, dedicated bucket, publicly readable) |
| **S3 API endpoint** | `https://<R2_ACCOUNT_ID>.r2.cloudflarestorage.com` (bucket name `conda`) |
| **channel domain (what users use)** | **`https://conda.qiyuan.me`** (R2 custom domain → bucket root) |
| **users' command** | `conda install -c https://conda.qiyuan.me isabelle` |
| **CI credentials** | `CONDA_R2_ACCESS_KEY_ID` / `CONDA_R2_SECRET_ACCESS_KEY` / `CONDA_R2_TOKEN_VALUE` (locally in `secret.sh`, **gitignored**; in CI as GitHub secrets) |
| **upload** | any S3-compatible client (`aws s3 --endpoint-url=…` / `rclone` / boto3) |
| **index** | after every upload, run `conda index` (or `rattler-index`) to regenerate each `repodata.json`, then upload those |

The channel's directory layout (= the bucket root):
```
conda.qiyuan.me/
├── noarch/          repodata.json + *.conda
├── linux-64/        repodata.json + *.conda
├── linux-aarch64/
├── win-64/
├── osx-64/
└── osx-arm64/
```

**Why a subdomain and not `qiyuan.me/conda`**: an R2 custom domain is a mapping **host name → bucket root**;
a top-level path would need an extra Cloudflare Worker for path routing, one more moving part that can break.

**Why a dedicated bucket**: the CI needs **write** access — its token should be able to write only this bucket, and
**must never have the right to write the production bucket of the semantic DB** (least privilege); moreover, conda
packages accumulate per version, so their lifecycle/retention policy is entirely different from the DB's.

#### ✅ Working end to end (measured)
```
$ conda create -n smoke -c https://conda.qiyuan.me --override-channels channel-smoke-test
  channel-smoke-test  0.1.1  h4616a5c_0     ← resolved, downloaded and installed from our own channel
```
The custom domain **takes effect immediately**; Content-Type / compression negotiation / CORS **need no attention**;
**R2 multipart upload works** (a large 1 GB package is OK).
`channel-smoke-test` **stays on the channel as a long-term health probe** — whenever it installs, the chain is working.

#### CDN caching: **a propagation delay, not a correctness problem** (wording corrected)

**It affects only the manifest, not the packages themselves** (measured): Cloudflare decides caching **by file
extension** ⇒

| File | Cloudflare behaviour |
|---|---|
| `repodata.json` | **DYNAMIC (not cached)** |
| **`repodata.json.zst`** | **HIT, `max-age=14400` (4h)** ← the only one cached |
| `*.conda` (the packages themselves) | **DYNAMIC (not cached)** |

conda prefers the `.zst` ⇒ **a newly published version may become visible only up to 4 hours later** (measured: we
published 0.1.1, and a clean conda installed 0.1.0).

**This is not "publishing the wrong package"; it is a delay**: package files are **immutable** (their names contain
version+build), and **we do not delete old packages** ⇒
users who get a stale index only install an **old version that really exists and works**; nothing breaks.
Brief inconsistency between edge nodes is **normal** in package ecosystems (conda-forge / PyPI both have CDNs), and users
do not all update at the same moment anyway.

**How long the delay is** (measured + inferred from the mechanism): one layer's TTL is **4h**; **the conda client also
caches repodata for 4h itself** (it honours `cache-control`) ⇒ stacked, **a theoretical maximum of ~8h** (+4h more if
Tiered Cache is on).
In practice it is often much shorter (low-traffic objects are evicted from the edge fairly quickly).

**The only real correctness risk**: if one day we **delete/withdraw** a package, a stale index would point to a file that
is gone → 404.
⇒ **Avoidance: never delete packages; for changed content only bump `build_number`** (which is our rule anyway).

#### ✅ The right fix: Cloudflare's defaults are **the opposite** of what we need; two Cache Rules correct them

| | What it should be | Cloudflare's default |
|---|---|---|
| **manifest** (`repodata*`) — **mutable** | **should not be cached** | ❌ cached for 4h, of all things |
| **package** (`*.conda`) — **immutable** | **should be cached** (fast downloads for users, fewer hits on the origin) | ❌ not cached, of all things |

```
1)  path contains "repodata"   → Bypass cache            (the manifest is always fresh)
2)  path ends with ".conda"    → Cache, Edge TTL 1 month (packages are immutable, so caching is 100% safe, pure gain)
```
With rule 1 set, **`--no-zst` is not needed at all**. `conda index --no-zst` is only **the substitute when we have no zone
permissions** (same effect: no `.zst` is produced → conda falls back to the `.json`, which is not cached anyway).
Our repodata is only **a few KB** (compare conda-forge's linux-64 at ~200MB), so whether it is compressed does not matter.

#### Toolchain (decided by measurement)
| Stage | Tool | Notes |
|---|---|---|
| build the package | **`rattler-build`** | a single Rust binary, ~2 seconds; produces a modern `.conda` directly; conda-build is in maintenance mode |
| index | **`conda-index`** | the official implementation, with an incremental sqlite cache (`<channel>/<subdir>/.cache/`), friendly to large 1GB packages |
| upload | **`rclone` ≥1.74** (the conda-forge build) | ⚠️ **Ubuntu's own 1.60 has two bugs against R2**: without `--s3-no-check-bucket` → 403; **the first attempt of every PUT always fails** (a 1GB package is uploaded twice) |

```bash
# credentials (the remote is configured through environment variables; nothing is written to disk)
source secret.sh
export RCLONE_CONFIG_R2_TYPE=s3 RCLONE_CONFIG_R2_PROVIDER=Cloudflare RCLONE_CONFIG_R2_REGION=auto
export RCLONE_CONFIG_R2_ACCESS_KEY_ID="$CONDA_R2_ACCESS_KEY_ID"
export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$CONDA_R2_SECRET_ACCESS_KEY"
export RCLONE_CONFIG_R2_ENDPOINT=https://<R2_ACCOUNT_ID>.r2.cloudflarestorage.com

rattler-build build --recipe recipe/recipe.yaml --output-dir output
python -m conda_index $CH --no-zst --no-bz2 --channeldata --channel-name conda.qiyuan.me
rclone sync $CH R2:conda/ --s3-no-check-bucket --exclude '.cache/**' \
       --s3-chunk-size 64M --s3-upload-concurrency 4 --transfers 2 --progress
```

**Notes for large packages**:
- **Keep a local channel directory identical to the bucket** — `conda index` indexes only local files, and
  `rclone sync` **deletes the files in the bucket that are not there locally**. Before publishing, pull it back first with
  `rclone sync R2:conda/ $CH/`.
- **Keep the local `.cache/` (the incremental sqlite index)**, but **exclude it from the upload**.
- Package files are **immutable**: for changed content **bump `build_number`**, never reuse a filename (users' pkgs caches
  and the CDN would both serve stale copies).
- **Egress is free** (R2), so distributing 1GB packages costs no bandwidth.

### 3.4 Isabelle's release mechanism (at source level, `src/Pure/Admin/build_release.scala`)

【Background knowledge. From 2026-10-31 on the CI no longer runs `build_release`: the official platform bundles are its
output, and we download them directly (§11).】

- **`Isabelle2025-2` = hg changeset `89701cf1768e`** (`.hgtags`; matches the release's `etc/ISABELLE_ID`).
- **The exact sources are available only from the official hg** (`https://isabelle.in.tum.de/repos/isabelle`);
  the GitHub mirror `isabelle-prover/mirror-isabelle` has **git tags only up to 2021**, so the 2025-2 tree cannot be had
  from it (its master is the development line after 2025-2; do not use it).
- **⚠️ `build_release` makes its archive from "the committed hg rev", not from the working directory**
  (`hg.archive(rev=id)`, build_release.scala:439-453). **If you change the working directory and do not commit, the
  patches are dropped entirely.** This is the easiest pitfall to fall into.
- **Stage one, `build_release_archive`**: `hg archive` → `other_isabelle.init`
  (= download the native components + **`scala_build`** (compiles the patches into `lib/classes/isabelle.jar`))
  → **`build_doc -a` (needs a complete TeX Live)** → purge `Admin/`/`heaps`/`.hg` → produce
  **the generic source archive `Isabelle2025-2.tar.gz`** (with compiled Scala, no heap).
- **Stage two**: for each platform → **download** the precompiled native components (polyml/jdk/E/Z3/cygwin…) from the
  official component repository (**`https://isabelle.sketis.net/components`**); the versions are those of **the
  `Admin/components/main` that comes with that rev**, **not those of the mirror's tip**, which has drifted to
  polyml-5.9.2-4/jdk-25 → **`build_heaps`** → assemble the bundle per platform.
- **`build_heaps` cannot cross architectures**: if the local machine's family ≠ the target platform and no
  `build_host_<platform>` SSH host is configured ⇒ **it fails outright**.
  The official model = one coordinating machine + one SSH build host per platform.
- **`-b SESSIONS` is empty by default**; the official release checklist (`Admin/Release/CHECKLIST`) actually passes
  **`-b HOL`** ⇒ the official bundles **carry a HOL heap**.
- **`-S ARCHIVE`**: skips stage one (**and with it hg, TeX and scala_build**) and goes straight to assembling the platform
  bundles ⇒ **every platform job can reuse the same archive**.
  - 【measured】 If `build_release_archive` finds an existing archive, it **reuses it and skips the whole build_doc
    step** (saves ~30 minutes).
- **Platform differences**: linux/linux_arm → `.tar.gz`; **macOS is a single universal bundle** (on one Apple Silicon
  machine, two builds with `ML_system_apple` false/true produce both heaps, x86_64-darwin + arm64-darwin);
  windows → launch4j `.exe` + 7z self-extractor. **Isabelle does not release arm64-windows** ⇒ "5 architectures" are
  **4 bundles** in Isabelle's terms.
- **bootstrap**: a bare hg checkout needs only `Admin/init` (`components -I` → `components -a` → `scala_build`),
  bootstrapped by the repository's own `isabelle_setup.jar`; **no pre-installed Isabelle is needed**.

### 3.5 heap (measured, compared against downloaded pristine official bundles)

- Heaps live in `heaps/<ML_IDENTIFIER>/`, and **`ML_IDENTIFIER` encodes the polyml version + architecture + OS**:

  | Platform | ML_IDENTIFIER |
  |---|---|
  | Linux x64 | `polyml-5.9.2_x86_64_32-linux` |
  | Linux ARM | `polyml-5.9.2_arm64_32-linux` |
  | Windows x64 | `polyml-5.9.2_x86_64_32-windows` |

- **The sha256 of the Pure heap differs on all three platforms**; it differs even for **the same architecture on
  different OSes** (Linux-x64 vs Windows-x64, both `x86_64_32`). A Poly/ML saved state (magic number `POLYSAVE`) is
  inherently specific to architecture+OS.
  ⇒ **Heaps cannot be shared across platforms; each platform must build its own.**
- **The official pristine bundles ship prebuilt `Pure` and `HOL` heaps** (HOL ~208MB).
- Heaps **are redistributable and do not embed the absolute `ISABELLE_HOME` path** (confirmed by the owner) ⇒ they can be
  distributed with the package.

#### ⭐ A heap is a **hierarchical increment (delta)**, not a full image

A child session's heap **stores only the difference from its parent session**; at run time Poly/ML's
`SaveState.loadHierarchy ["Pure", "HOL", ...]` loads them chained by hierarchy. Measured (same machine, same
ML_IDENTIFIER):

| heap | size |
|---|---|
| `Pure` | 31 MB |
| `HOL` (parent = Pure) | 336 MB |
| **`Main` (parent = HOL)** | **3.8 MB** |

**This changes the cost estimate**:
- **Adding `Main` is almost free** (+3.8 MB, near-instant build time — it is only one `Main_Doc` theory on top of HOL).
- Likewise, **our own AoA session heaps (the `Minilang_AoA` chain) are deltas too, not full images of hundreds of MB** ⇒
  if we ever want to prebuild them so users can use them out of the box, **package size is no obstacle**; the real cost
  is only **CI build time** (the whole chain Auto_Sledgehammer / Semantic_Embedding / Isa_REPL / Minilang has to run).

#### `Main` is a real session (do not be misled by `(doc)`)
`src/Doc/ROOT:310`: `session Main (doc) in "Main" = HOL +`, containing theory `Main_Doc`.
`isabelle sessions -a` lists it, and `isabelle sessions -b Main` gives the dependency chain `Pure → HOL → Main`.
**Our toolchain uses `Main` as its default session** (the official release has only `-b HOL`, without `Main`) ⇒
~~**We must use `-b HOL,Main`.**~~ 【From 2026-10-31 on the package holds only the official Pure and HOL heaps (decided by
the owner): `Main` is built by whoever uses it, on first use, in that environment's user directory; it is only a small
delta on top of HOL.】

#### 🔴🔴 `heaps/*/log/<S>.db` **must ship with the heap** (measured 2026-07-12; it nearly made the whole pipeline worthless)

The name `log/` is misleading: **`log/<S>.db` is not a log; it is the session database**.
When `isabelle build` decides whether "a session is built and current", **it looks up this db, not whether the heap file
exists**. The official bundles carry these files.

The CI's Job B–E once ran `rm -rf heaps/*/log` before uploading the heap artifacts, with this result:

| | the first real build after installing the package |
|---|---|
| **without** `log/*.db` | `Building HOL ...` → **a full 20 minutes recompiling HOL** |
| **with** `log/*.db` | `Finished (0:00:01)` → **10 seconds, the heap is loaded directly** |

In both cases the package installs normally and `isabelle version` runs — **those 350MB of heap are just dead weight**.

⚠️ **`isabelle build -n` is a false-positive check and cannot be used for acceptance**: without the db it still reports
"nothing to build", while a real build immediately recompiles HOL. **Acceptance must really run a session built on top of
`Main`, and fail when it sees `Building HOL`.**

### 3.6 Windows (measured on a real Win11 VM + GitHub CI)

- `bin/isabelle` is **a Cygwin bash script without an extension**; `cmd /c isabelle` → **9009 not recognized**.
  ⇒ We must provide an `isabelle.bat` wrapper:
  ```bat
  @echo off
  setlocal
  set "ISABELLE_HOME=<Isabelle root directory>"
  set "HOME=%HOMEDRIVE%%HOMEPATH%"
  set "LANG=en_US.UTF-8"
  set "CHERE_INVOKING=true"
  set "CYGWIN=nodosfilewarning"
  set "PATH=%ISABELLE_HOME%\bin;%PATH%"
  "%ISABELLE_HOME%\contrib\cygwin\bin\bash.exe" --login -c "exec isabelle \"$@\"" isabelle %*
  endlocal
  ```
- **【measured · confirmed by screenshot】 `isabelle.bat jedit` really brings up the complete GUI**: window title
  `Isabelle2025-2/HOL - Scratch.thy`, **`Prover: ready`**, the Documentation panel complete, the HOL heap loaded. **The
  biggest unknown on the Windows side is closed.**
#### ✅ `isabelle.bat` finalized (the console-hang problem fixed and accepted)

**The original problem**: the chain `cmd → bash → bash → java` is entirely synchronous ⇒ the console stays hanging, and
**closing it kills jEdit** (java is attached to the launching console and receives `CTRL_CLOSE_EVENT`).

**Final solution: cygwin's `run.exe`** (GUI subsystem, hidden console) to detach.
**File: `/home/qiyuan/qemu-win/isabelle.bat`**.

> ### 🔴 Not finished: **it must go into `<ISABELLE_HOME>\bin\` and locate itself**
> The current version **hard-codes the path** (`set "ISABELLE_HOME=C:\isa\Isabelle2025-2"`) — a leftover of the testing
> phase. **conda installs into a `$PREFIX` that differs for every user/environment; a version with a hard-coded path is
> useless.**
>
> **It must become**:
> - **Location: `<ISABELLE_HOME>\bin\isabelle.bat`** (the same place as `bin/isabelle` on Linux/macOS
>   ⇒ the instructions for users are the same everywhere: "add `<ISABELLE_HOME>/bin` to PATH"; Windows resolves
>   `isabelle` to the `.bat` through `PATHEXT`)
> - **Self-location**: `pushd "%~dp0.." && set "ISABELLE_HOME=%CD%" && popd` — **no absolute path may be hard-coded**
>
> **Two points to verify** (in progress):
> 1. **Recursion**: `bin/` will hold both `isabelle` (the Cygwin bash script) and `isabelle.bat`.
>    cmd finds the `.bat` through PATHEXT; Cygwin bash **does not know PATHEXT** and should find the bash script ⇒
>    **no infinite recursion `.bat`→bash→`.bat`**.
>    **Must be confirmed by measuring `type -a isabelle`.**
> 2. **Relocatability**: after the whole tree is copied to another path, `isabelle.bat` must still work fully. **This is
>    the criterion for whether it can go into a conda package.**
>
> The layout in the conda package:
> ```
> $PREFIX/opt/Isabelle2025-2/bin/isabelle.bat   ← the real one (self-locating)
> $PREFIX/Scripts/isabelle.bat                  ← a one-line forwarder (conda's Windows bin directory, on PATH after activate)
> ```

Two candidates were **rejected by measurement**:
- **`start "" /b` rejected**: a probe (`GetConsoleProcessList`) proved that java **is still attached to the same
  console** (`VERDICT: ATTACHED`) → closing the window still kills jEdit. It cures only "hanging", not "being killed".
- **The launch4j `.exe` cannot replace `isabelle jedit`**: `JEdit_Main.main` **parses no options at all** (it special-cases
  only `-init`); the logic/session comes from **environment variables that the bash `jedit` script exports from
  `-l/-d/-R/-i`** ⇒ the exe cannot express `-l HOL-Analysis`, it also skips `scala_build`, and it has no `-b` at all; it
  is also configured with a singleInstance mutex.

**Telling GUI from `jedit -b`: a faithful replica of the `getopts` specification**
(`src/Tools/jEdit/lib/Tools/jedit`: `getopts "A:BFD:J:R:bd:fi:j:l:m:no:p:su"`), **27/27 of the matrix passed when
measured**. The naive "synchronous if the arguments contain `-b`" **is wrong in both directions**:
- `isabelle getenv -b ISABELLE_HOME` → should be synchronous; naive treats it as GUI;
- `isabelle jedit -d -b` (`-b` is the value of `-d`) → should be GUI; naive treats it as synchronous.

**Acceptance (all measured)**: `jedit` **returns in 0.22s** + the GUI comes up (screenshot `Prover: ready`) + **jEdit
survives closing the launching console** (probe `VERDICT: DETACHED`); `jedit -b` is still synchronous, exit=0;
`getenv -b` exit=0; `build`'s exit codes 0/2 are passed through correctly.
Escape hatches: `ISABELLE_BAT_SYNC=1` (force synchronous, a fallback for CI), `ISABELLE_BAT_DRYRUN=1` (only print the
GUI/SYNC decision).

#### ⚠️ Found along the way: an **upstream Isabelle bug** (not ours, but it will bite users)

`lib/scripts/getfunctions`: `platform_path() { cygpath -i -C UTF8 -w -p "$@"; }`
— **`-p` is the "path list" mode**, and `:` is taken as a separator:
```
C:\isa\t\Probe_Arg.thy          →  C;C:\isa\t\Probe_Arg.thy    ← destroyed
/cygdrive/c/isa/t/Probe_Arg.thy →  C:\isa\t\Probe_Arg.thy      ← correct
Probe_Arg.thy                   →  Probe_Arg.thy               ← correct
```
⇒ **`isabelle jedit C:\absolute\path.thy` cannot open the file on Isabelle2025-2 in the first place** (it opens an empty
buffer of the same name + an I/O error).
**Workaround: pass a POSIX path or a relative path. This must go into the user documentation.**
(Ironically, the launch4j `.exe` does not have this problem — it bypasses `platform_path`.)
- **⚠️ The Session 0 trap**: a shell that came in through SSH is in **Session 0 (no desktop)**; the real desktop is
  Session 1. Consequences:
  - the official SFX **cannot install silently under SSH** (it gets stuck at a GUI prompt nobody answers) ⇒ extract with
    `7z x` + run `-init` separately;
  - **the GUI must be launched into Session 1** (`schtasks /it`);
  - **from Session 0 the windows of Session 1 cannot be enumerated ⇒ `MainWindowTitle` is always empty.
    Window-title assertions are unreliable; the screenshot is the ground truth.** This directly decides how the CI GUI
    test is designed (see §7).
- **The one-time `-init`** (restore the Cygwin symlinks + `rebaseall` + `postinstall`) must run first, otherwise
  `isabelle` is broken; headless, it **can complete unattended** (measured). A conda/tar install bypasses the SFX's
  AutoInstall ⇒ **this step must be done explicitly** (least hassle: run `-init` on a real Windows build machine, then
  package).
- **The form of the environment variables** (as a native Windows Python inherits them from the Isabelle settings
  environment):
  ```
  ISABELLE_ROOT      = C:\isa\Isabelle2025-2                      [native]
  CYGWIN_ROOT        = C:\isa\...\contrib\cygwin                  [native]
  ISABELLE_HOME      = /cygdrive/c/isa/Isabelle2025-2             [POSIX]
  ISABELLE_HOME_USER = /cygdrive/c/Users/x/.isabelle/...          [POSIX]
  (there are no *_WINDOWS variants; ISABELLE_HOME_USER has no counterpart variable in native form)
  ```
  Measured: `cygpath -w $ISABELLE_HOME == $ISABELLE_ROOT`.
  ⇒ **Isabelle_RPC's path bug is fixed** (`Isabelle_RPC_Host/paths.py`, commit `5b9580c`):
  `/cygdrive` goes through a pure string rule (no subprocess, no locale ⇒ safe for non-ASCII user names),
  and cygpath is only the fallback for Cygwin-internal paths, reading bytes.

#### 🔴 **The conda install path must not contain non-ASCII characters** (an upstream defect, not our fault)

When installed under `C:\中文 目录\Isabelle 2025-2`, `isabelle build` / `jedit -b` report
**`could not find java.dll`**. `getenv -b ISABELLE_HOME` itself is **correct** (self-location works);
what breaks is the java launcher that comes with Isabelle.

**A control experiment proves it has nothing to do with us**: bypassing `isabelle.bat` completely and calling
`bin/isabelle` directly with the tree's own Cygwin bash **gives the same error**. ⇒ The upstream launcher does not
support non-ASCII paths.
**This must go into the user documentation: on Windows, the path of a conda env must not contain non-ASCII characters.**
(A path **with spaces**, on the other hand, is no problem at all: `C:\Program Files\Isabelle 2025-2` passed when
measured.)

#### `isabelle.bat` self-location: the "one-line" form is broken
```bat
pushd "%~dp0.." && set "ISABELLE_HOME=%CD%" && popd     ← wrong
```
cmd expands `%CD%` **when it parses the whole line**, so it gets the cwd from **before** `pushd`. Measured
(cwd=`C:\Windows`): it gives `ISABELLE_HOME=C:\Windows`. **It must be split into three lines.**
This pitfall is insidious: when users happen to type the command inside ISABELLE_HOME, it **looks right**.

#### 🔴🔴🔴 **MAX_PATH: the win-64 package does not install on default Windows** (measured on a real machine 2026-07-13, new finding)

**This is currently the most serious roadblock for win-64.** On a default Windows 11 (`LongPathsEnabled = 0`):
```
InvalidArchiveError: [Errno 2] No such file or directory:
 'C:\Miniconda3\pkgs\isabelle-…\opt\Isabelle2025-2\contrib\vscodium-…\
  …\node_addon_api_except.lastbuildstate'          ← 262 characters = MAX_PATH+2
conda create LASTEXITCODE=1  →  the env was never created
```
- **The longest path relative to `$PREFIX` in the payload is 212 characters** — **an MSBuild junk file (`.tlog`) in
  vscodium's `node_modules`**.
- **Unpacking happens in the pkgs cache, so users cannot escape it by choosing a short env path**:
  `C:\Users\bob\miniconda3\pkgs\isabelle-…\` (60) + 212 = **272 > 260**.
- Deleting that one file is not enough: the next longest is 195, which **still overflows** for an ordinary
  `C:\Users\<name>\AppData\Local\miniconda3` root directory.

**`LongPathsEnabled` is `0` by default on Windows 11**
([MS documentation](https://learn.microsoft.com/en-us/windows/win32/fileio/maximum-file-path-limitation)); changing it
needs **an administrator to edit the registry + a reboot**, and on top of that each application has to opt in in its own
manifest (Python 3.6+ does).

#### ❌ Setting `LongPathsEnabled` beforehand from a conda script — **impossible** (three independent reasons)
1. **Too late in the sequence**: conda's order is download → **unpack into the pkgs cache** → link → post-link.
   **It breaks at "unpack into the pkgs cache"**, which happens **before any script runs**. A prerequisite package does
   not help either — conda unpacks **all** packages before it starts linking.
2. It needs **administrator** rights (HKLM), and conda usually runs unelevated.
3. It takes effect only after a **reboot**.

⇒ **The only way out is to make the paths shorter.** That is also the conclusion of the conda ecosystem
([conda#7203](https://github.com/conda/conda/issues/7203); the culprit is almost always `node_modules`).

#### ✅ Decision (approved by the owner 2026-07-13): **keep vscodium, shorten only the paths we control**

**`isabelle vscode` is mainstream and cannot be dropped** (the owner explicitly rejected "dropping vscodium").
**Do not touch Isabelle's own tree structure either** (the proposal to rename the vscodium component was rejected). Five
changes, all in `pack.sh` / `conda/recipe.yaml`, **invisible both to users and to Isabelle**:

| # | Change | Saves |
|---|---|---|
| 1 | **in-package root `opt/Isabelle2025-2/` → `isa/`** (only which subdirectory of the conda prefix we put the tree in) | 15 |
| 2 | **build string `isabelle-2025.2-68fdb1877e0c_0` → `isabelle-2025.2-0`** (the changeset moves into the metadata) | 12 |
| 3 | **drop vscodium's `**/obj/**`** (MSBuild's `.tlog`/`.lastbuildstate`, not read at run time) 【this step deleted 2026-11-01 (owner): the official Isabelle2026 bundles have no `obj/`, so there is nothing to delete】 | the 208 one |
| 4 | inject `<ISABELLE_HOME>\bin\isabelle.bat` | — |
| 5 | put back the 83 empty directories | — |

**Result (Isabelle2025-2): the longest in-package path is 180** (measured). For the values of Isabelle2026 see step 4 of
`pack.sh`: the longest is 182 (VSCodium's own path), the limit 183, a margin of 1, and from build number 10 on a margin of
0; the owner accepted this on 2026-10-31. `pack.sh` asserts it only for win-64.

#### ✅✅ Re-test on a real machine passed (2026-07-14, `LongPathsEnabled = 0`, default Windows 11)

**First set the VM's `LongPathsEnabled` back to 0 + reboot + confirm** (confirmed once before and once after the test);
otherwise it is a false pass.
The env was created at `C:\Users\isabelle\miniconda3\envs\isabelle\` (the typical "Just Me" layout; **no cheating with a
short path**).

| # | Check | Result |
|---|---|---|
| 1 | `conda create` on **default Windows** | ✅ **rc=0, 85 seconds**. Longest path on disk **223 / 259, a margin of 36 characters** |
| 2 | PowerShell `isabelle version` after activate | ✅ `Isabelle2025-2`; `ISABELLE_HOME` locates itself to the `…/isa` inside the env |
| 3 | **`isabelle vscode`** | ✅ **VSCodium starts, the Isabelle extension is installed, `bad` is marked red exactly and `good` is clean (⊗1 ⚠0)**. ⇒ **dropping `obj/` did not hurt VSCode** |
| 4 | `isabelle jedit` | ✅ screenshot: `Prover: ready`, the bad lemma with a red dot + red background + red squiggle |
| 5 | prebuilt heap | ✅ a real build in 24 seconds, **`Building HOL` did not appear even once** |
| 6 | the `could not find /tmp` warning | ✅ **gone** (the effect of putting back the 75 empty directories) |
| 7 | Cygwin heals itself | ✅ the marker is gone, **947/947** symlinks all restored |

**The decision "75, not 83" was confirmed by measurement:** after `cygwin_init`, the 5 directories `var/lib/rebase/*.d`
**are created by `rebaseall` itself**, and **no `.conda-keep` got mixed into them**. Had we put markers there, their
content would have been added by `cat` to rebase's DLL list. 【From 2026-11-01 on, changed so that every empty directory of the
official bundle gets one, the 5 rebase ones included, and the marker is an **empty file** (owner): `rebaselst` skips empty
content (`rebaselst:47-48, 54-55`), so an empty marker is harmless in the rebase directories; this way Cygwin's directory
permission list need not be rewritten. How many were placed: see "restored N empty directory(ies)" printed by step 2 of
`pack.sh` (measured on Isabelle2026 win-64: 80).】

#### 🔴 The remaining three (not blockers, but they must go into the user documentation)

1. **Two path-length limits, each of which must not exceed 259 characters (both including the trailing `\`); the first
   one bites first:**
   - **conda's pkgs directory + `isabelle-<version>-<build>\` + the longest in-package path.** conda first unpacks the
     package into the pkgs cache (measured above); past the limit it is `InvalidArchiveError`; this is the limit `pack.sh`
     asserts.
   - **The env path prefix + the longest in-package path.** Past the limit, putting the files into the environment fails.

   The longest in-package path is VSCodium's own file, which we do not control. For Isabelle2026 it is 182: the pkgs
   directory may have at most 61 characters (60 from build number 10 on; with a 20-character user name, the default
   `C:\Users\<user name>\AppData\Local\miniconda3\pkgs\` is exactly 60), and the env prefix at most 77 — `pack.sh` prints both
   numbers every time on win-64. When a VSCodium upgrade makes the path longer, `pack.sh`'s assertion goes red in the CI,
   instead of users' `conda create` breaking.
   (If we really want a margin, we can rename `contrib/vscodium-<version>/` to `contrib/vscodium/`; `$COMPONENT` refers to
   itself, so this is safe. **The owner has chosen not to do this for now.**)
2. **The install path must not contain non-ASCII characters** (a limitation of the upstream JVM launcher, see above).
3. **🔴 On Windows the path convention for file arguments is "split", and both sides fail silently** (measured during
   an independent re-check):

   | Command | What path it wants | What happens if you pass the wrong one |
   |---|---|---|
   | **`isabelle vscode <file>`** | **native Windows** (`C:\...`) | passing `/cygdrive/...` → **silently opens an empty Plain-Text buffer** |
   | **`isabelle jedit <file>`** | **cygwin** (`/cygdrive/c/...`) | passing `C:\...` → **silently opens an empty buffer**; the path is assembled as `%WINDIR%\System32\C;C:\...` |
   | **`isabelle build -d <dir>`** | **cygwin** | passing `C:\...` → a hard error `*** Illegal character ":" in path element` |

   The root cause of the `vscode` row is `src/Tools/VSCode/src/vscode_main.scala:286`: `more_args` is handed to vscodium
   **as it is**; **upstream does no path conversion**. **The two "silently opens an empty file" rows are especially
   dangerous** — users will think the file is empty.
   **This is upstream Isabelle behaviour, not a defect of our package**, but it must go into the user documentation.

**A slow first call is expected**, but users who do not know will think it hangs, so the documentation should mention it:
the first `isabelle` call of any kind takes about 90 seconds (Cygwin heals itself); the first `isabelle vscode` about 3.5
minutes (it installs the extension).

#### 🔴 The conda payload **has no directory entries**; all 83 empty directories were lost

A conda package holds only files, no directory entries ⇒ the **83 empty directories** of the official bundle all
disappear after installation, including `contrib/cygwin/{tmp, var/tmp, dev/shm, home}` and **`var/lib/rebase/*.d`
(`rebaseall`'s state directories)**.

Consequence: every `isabelle` call prints `bash.exe: warning: could not find /tmp, please create!` (3–9 times).
**Not fatal** (build and GUI still work), but the missing `rebaseall` state directories should not go live.
⇒ **The recipe's build script must put the empty directories back** (replaying `find -type d -empty`).

#### ✅ **Cygwin heals itself — no post-link needed, the problem does not exist** (measured on a real machine, overturning the earlier worry)

Earlier we thought it was an **unsolved problem** that "`build_release` strips the Cygwin symlinks, so something has to
run `cygwin_init` on users' machines, and conda does not track the files a post-link creates". **Measurement showed it is
no problem at all:**

| | State |
|---|---|
| **before** the first `isabelle` call | the `uninitialized` marker is there, **all 947 symlinks are missing** |
| run `isabelle version` | rc=0, **took 88.1 seconds** |
| **after** | the marker is **gone**, and all symlinks are restored as `!<symlink>…` with the `System` attribute |
| second call | 20.8 seconds |

Mechanism: `getsettings:118` runs `isabelle.setup.Setup` every time → `Environment.init` → `cygwin_init`
→ restore the symlinks + `rebaseall` + `postinstall`. **The first call pays about 90 seconds, and after that it is fine.**
【Correction 2026-11-01: neither rc=0 nor the marker being gone proves that the initialization succeeded — `getsettings`
discards `Setup`'s error output and does not look at its exit code, and `cygwin_init` deletes the marker at its very
start. A check showed that it did indeed fail (CI run 41267104571). The cause (from reading the sources): `getsettings`
runs it inside Cygwin's bash, and Cygwin's `rebaseall` refuses when it sees Cygwin processes other than ash/dash ("only ash
or dash processes are allowed during rebasing", exit 2), so `postinstall` never runs; restoring the symlinks comes before
`rebaseall`, which is why the table above looks fine. The official native launcher starts the JVM directly and does not
have this problem.
Now `windows/isabelle.bat`, while the marker is still there and before it starts bash, runs Isabelle's own
`Setup cygwin_init` with the package's java, and on failure reports an error and exits; `build.yml`'s `install-windows`
asserts that the first call succeeds and that `postinstall` wrote `etc/passwd`, and makes it fail once as a negative
control.】

#### ✅ Recursion-safe + relocatable (measured on a real machine)
- **Recursion**: this was a potentially fatal hazard — `getsettings:62` puts `bin/` at the **very front** of PATH, and
  `bin/isabelle` ends with `exec isabelle java …` (which **looks PATH up again** in bash). If Cygwin appended `.bat`,
  every internal tool would recurse infinitely. **But Cygwin appends only `.exe`, not `.bat`**
  ([Cygwin User's Guide](https://cygwin.com/cygwin-ug-net/using-specialnames.html):
  *"for programs that end in `.bat` and `.com`, you cannot omit the extension"*).
  Measured: `type -a isabelle` has only one entry, `isabelle version` rc=0.
- **Relocatability**: the whole tree robocopied to `C:\other\` (29742 files / 2.342 GiB / 0 FAILED),
  all four acceptance checks pass, and `C:\isa` does not appear in PATH at all. **This is the precondition for a conda
  package to work, and it is met.**

### 3.7 CI runners (confirmed)

| Target platform | Free official runner | label |
|---|:--:|---|
| x86_64-linux | ✅ | `ubuntu-latest` |
| **arm64-linux** | ✅ (GA 2025-08, free for public repos) | `ubuntu-24.04-arm` |
| x86_64-windows | ✅ | `windows-latest` |
| arm64-darwin | ✅ | `macos-15` (`macos-14` is retired 2026-11-02) |
| x86_64-darwin | ✅ | `macos-15-intel` (the only Intel image left; `macos-13` is retired, and its jobs stay queued forever) |

⇒ **There is a free official runner for every platform; nothing needs to be self-hosted.**
⚠️ **GitHub's standard runners have no KVM/nested virtualization ⇒ QEMU cannot go into the CI** (a local VM can only be a
local verification tool).

---

## 4. Release pipeline (end-to-end blueprint)

【The pipeline of the Isabelle2025-2 era, kept as a record. For the pipeline from 2026-10-31 on, see §5.5.】

```
① fetch       hg clone https://isabelle.in.tum.de/repos/isabelle   (--stream, measured 226MB / 108s)
              hg update -r Isabelle2025-2                          (= 89701cf1768e)

② patch       my_better_isabelle_prover's version-keyed diffs (patches/Isabelle2025-2/…)
              patch -p1 -F0                                        (measured: 13 patches apply cleanly)
              ⚠️ on a bare checkout, `isabelle version` is not "Isabelle2025-2" (ISABELLE_IDENTIFIER is not written)
                 ⇒ the version key must be given explicitly; it cannot rely on auto-detection

③ commit      hg commit -m "our patches"      → REV'
              ⚠️ crucial! build_release makes its archive from the committed rev; without a commit the patches are lost

④ bootstrap   Admin/init  (= components -I + components -a + scala_build)

⑤ build       Admin/build_release -r REV' -R Isabelle2025-2 -b HOL,Main -p <platform>
                stage one → scala_build compiles the .scala patches into isabelle.jar
                          → build_doc (needs a complete TeX)
                          → generic source archive  Isabelle2025-2.tar.gz
                stage two → download the native components + build_heaps (builds the HOL heap from the patched .ML) + assemble the bundle

⑥ output      Isabelle2025-2_linux.tar.gz / _linux_arm.tar.gz / _macos.tar.gz / .exe
              + Isabelle2025-2.tar.gz (the generic source archive, for the other platforms to reuse with -S)

⑦ package     → conda package (version 2025.2) → self-hosted channel
```

### ✅✅ Verification status on five platforms (2026-07-15; all "installed and really run")

| Platform | installed + CLI + heap really loaded | GUI (jEdit really checks a proof) | How it was verified |
|---|---|---|---|
| linux-64 | ✅ | ✅ | Job F (CI) |
| linux-aarch64 | ✅ | ✅ | Job H (CI) |
| win-64 | ✅ | ✅ jEdit + **VSCode** | real Windows VM, re-checked by hand (ruling out contamination from an old tree) |
| osx-64 (through Rosetta) | ✅ **and asserted to really run x86** | 🔶 to be wired in | macos-install-probe (CI); 2b asserts `ISABELLE_PLATFORM64=x86_64-darwin` |
| osx-arm64 | ✅ | 🔶 to be wired in | macos-install-probe (CI) |

- **"Installed and run" = a real `conda create` → `isabelle version` → a real build of a session on top of `Main`,
  asserting that `Building HOL` does not appear.**
  **All** five platforms passed — not "can be packaged" but "runs".
- macOS GUI: that the runner has a window server is confirmed by measurement (see §5.2); a real jEdit screenshot check is
  **to be wired in**.
- ⚠️ A complete **A→H→publish→smoke run that is green in one round** has not happened yet (the platforms were verified in
  separate rounds/side paths); the release round will be the first end to end.

---

### ✅ Proven (Linux, run end to end on the local machine — the earliest single-platform prototype)

`hg clone` → 13 patches → `hg commit` (`5acc266a8fba`, parent = `89701cf1768e`) →
`Admin/build_release -b HOL -p linux` → **`BUILD_RELEASE_EXIT=0`**.

It produced **`Isabelle2025-2_linux.tar.gz` (895 MB)**, verified after unpacking:

| Check | Result |
|---|---|
| `bin/isabelle version` | `Isabelle2025-2` ✓ |
| `etc/ISABELLE_ID` | `5acc266a8fba` (our patch commit) ✓ |
| patched HOL heap | `heaps/polyml-5.9.2_x86_64_32-linux/HOL` (208MB) ✓ |
| the patches are in the finished **source** tree | register_thy / show_types_nv / lsp.scala ✓ |
| the patches are compiled into **`lib/classes/isabelle.jar`** | `theory_status`/`command_at_position`/`output_at_position`/`cancel_execution` are all in the compiled output ✓ |

**⇒ The chain "Scala patches go into the jar through scala_build, ML patches go into the HOL heap through build_heaps" is
fully confirmed.**

---

## 5. CI matrix (**redesigned from measurements**)

【§5.0–5.2 are the matrix from when we built Isabelle ourselves, kept as a record; of them, these facts still hold:
Windows' `LOCALAPPDATA`, `ML_IDENTIFIER` being empty, and `log/<S>.db` having to travel with the heap. For the matrix from
2026-10-31 on, see §5.5.】

### 5.0 Four iron rules (all measured; they alone determine the shape of the matrix)

**① Packaging can only be done on Linux/macOS — including the Windows `.exe`.**
`Admin/build_release -p windows` **cannot run on Windows**; it fails hard on a real machine:
```
*** java.lang.IllegalArgumentException: requirement failed: Linux or macOS platform required
```
Root cause, `src/Pure/Admin/component_windows_app.scala:13-16`:
```scala
def tool_platform(): String = {
  require(Platform.is_unix, "Linux or macOS platform required")
```
Both `launch4j_jar()` and `seven_zip()` go through it, and the Windows branch needs both.
**Conclusive evidence**: the unpacked `windows_app` component contains only `arm64-linux` / `x86_64-darwin` /
`x86_64-linux`, **no `x86_64-windows`** — **the toolchain that makes the `.exe` has no Windows version at all**.
⇒ **The `.exe` is cross-built from Linux. A "Windows packaging job" does not exist at all.**
The official `Admin/Release/CHECKLIST:82` confirms it: *"on fast Linux machine, with access to build_host for each
platform"*.

**② Heaps can only be built natively on their own platform** (§3.5; across architectures it is impossible).

**③ GitHub runners cannot SSH into each other** ⇒ the official `build_host_<platform>` mechanism **cannot be used on
GitHub**.

**④ 🔴🔴 A heap artifact must be uploaded together with `heaps/*/log/<S>.db` — without it, the heap is 350MB of dead
weight.**
The name `log/` **is misleading**: `log/<S>.db` **is not a log; it is the session database**. When `isabelle build` decides
whether "a session is built and current", **it looks up this db, not whether the heap file exists**. The official bundles
carry them.
The CI once ran `rm -rf heaps/*/log` before uploading, with the result that the package installed, `isabelle version`
ran, and **even `isabelle build -n` reported "nothing to build" (a false positive)**, but a real build immediately
recompiled HOL for 20 minutes.
⇒ **Acceptance must never use `isabelle build -n`; it must really run a session built on top of `Main`, and fail when it
sees `Building HOL`.** (Details in §3.5)

⇒ **Packaging and building heaps must be decoupled.**

### 5.1 Matrix

```
Job A  [ubuntu-latest]        fetch → patch → hg commit
                              Admin/build_release -r REV' -p linux,linux_arm,windows,macos
                                                  (without -b!)
                              → generic source archive + 4 platform bundles (none with a heap; the Windows .exe included)
                              ⚠️ only this job needs hg, TeX, Admin/

Job B [ubuntu-latest]     ┐
Job C [ubuntu-24.04-arm]  │   each on its native runner:
Job D [macos-14]          ├─  isabelle build -o system_heaps -b HOL,Main
Job E [windows-latest]    ┘   (macOS runs twice, ML_system_apple=false/true → both architectures)
                              → upload heaps/<ML_IDENTIFIER>/ as an artifact

Job F  [ubuntu-latest]        download the 4 bundles + all heaps
                              → inject the heaps into each bundle (tar ones: just put them in; Windows: rebuild the SFX .exe with 7zz)
                              → rattler-build makes the conda packages (per-platform)
                              → conda index --no-zst --no-bz2      ← required! see the CDN pitfall in §3.3
                              → rclone sync → R2 (conda.qiyuan.me)
```

- **`Admin/` must exist in the tree that runs build_release** (4 independent measured reasons): the entry script itself is
  in `Admin/`; `isabelle build_release` **is not a registered tool** (`*** Unknown Isabelle tool`); in the archive
  `Admin/` **has been purged** (entry count = 0); Windows packaging reads `~~/Admin/Windows/{launch4j,Cygwin}` (`~~` = the
  ISABELLE_HOME of the **build machine**); the `build_host_*` options are declared in `Admin/etc/options` (without it,
  `-b` fails outright with "Unknown option").
- `-S` **itself does not need hg** (measured: hg was not even installed in the guest, and `-S` never touched
  `Mercurial.self_repository()`).
- Speed-ups: `hg clone` can be cached; `~/.isabelle/contrib` (the native components) can be cached.
- ⚠️ **The only link not yet verified: building the heap natively on a Windows runner** (in the VM it got stuck at
  `build_heaps`'s tar step, but that was QEMU being too slow; on a real runner it is very likely feasible, **not
  tested**).

### 5.1.1 🔴 Three source-level corrections (found while implementing the CI; **they overturn what this document wrote earlier**)

**① Job B–E must consume the "platform bundles", not the "generic source archive"**
What we wrote earlier, "take the generic archive → `isabelle components -a`", **does not work**:
- `build_release` **purges `Admin/` from the archive** (`build_release.scala:540`) ⇒ the `Admin/components/main`
  directory that `components -I` wants to write into the user settings **does not exist** ⇒ `getfunctions:293` reports
  **"Bad component catalog file" → exit 2**.
- In the archive's `etc/components`, the bundled components exist only as **comment lines** (`#bundled:polyml-…`,
  written by `record_bundled_components`), and `getfunctions:302` **skips all `#` lines** ⇒ `ISABELLE_COMPONENTS_MISSING`
  is empty ⇒ **`isabelle components -a` is a silent no-op** (what turns the comments into real `contrib/…` entries is
  `activate_components`, which runs **only in the per-platform bundle stage**).
- **⇒ The generic archive has no Poly/ML and no JDK; `isabelle build` cannot even start.**

**The right way**: each heap job **unpacks its own platform's bundle** (whose `contrib/` is already activated) and runs
`isabelle build` directly.
⇒ **Job A should upload a separate artifact for each bundle**, so that each heap job downloads only its own.

**② Windows: setting `TEMP`/`TMP`/`TMPDIR` **has no effect** — you must set `LOCALAPPDATA`**
Under Cygwin, `lib/scripts/getsettings:30` **overwrites them unconditionally**:
```bash
TMPDIR="$(cygpath -u "$LOCALAPPDATA")/Temp"     # ← the TMPDIR you set is simply overwritten
```
and `ISABELLE_TMP_PREFIX` is derived from it. **The only lever that moves scratch off the 33GB C: drive is
`LOCALAPPDATA`** (likewise `HOME`/`USER_HOME`, which are otherwise derived from `$USERPROFILE`).
⇒ Job E sets these, and before it starts **asserts that `ISABELLE_TMP_PREFIX` really lands on `D:`**.

**③ `ML_IDENTIFIER` is not a settings variable**
In 2025-2, `isabelle getenv ML_IDENTIFIER` **prints nothing** (it is computed on the Scala side).
⇒ To get the heap directory name, the only way is to read it with `ls heaps/`.

**④ Cygwin bootstrap on Windows (Job E)**
After 7z unpacks the SFX, use the main class of `isabelle_setup.jar` to trigger `Environment.cygwin_init()`
(its own comment is *"init (e.g. after extraction via 7zip)"*) — it restores the stripped symlinks + runs
`rebaseall`/`postinstall`; after that, every build goes through `<cygwin>\bin\bash.exe` (consistent with what Isabelle
itself does).

### 5.2 macOS (measured on CI, `macos-14`)

- **One `macos-14` is enough, with zero prerequisites. Rosetta 2 is preinstalled and works out of the box**
  (`arch -x86_64` just works, `oahd` is running).
- **The components really carry both architectures**: under `polyml` there are 4 platform directories
  (`arm64-darwin`/`arm64_32-darwin`/`x86_64-darwin`/`x86_64_32-darwin`), and all four `poly` **really run successfully** on
  the arm machine. (z3 / vampire / spass etc. are x86_64 only → **they rely on Rosetta**.)
- **🎯 Heaps for both architectures on one machine: measured success**: one run each with `ML_system_apple=false/true` →
  two different ML_IDENTIFIERs, different sha256.
  **HOL ×2 = 1h44m** (x86 through Rosetta 55m + arm native 50m; **the Rosetta penalty is only ~10%**). Far below the 6h
  limit.
- ⚠️ The ML_IDENTIFIER is the **`_32` variant** (`x86_64_32-darwin` / `arm64_32-darwin`), because the default is
  `ML_system_64=false`; `ML_system_apple` switches only apple/non-apple, **not 32/64**.
- `macos-13` **is dead in practice** (queued 1h50 with nobody picking it up) — but **we do not need it**.
- The official macOS bundle **already ships both heaps** ⇒ if we only repackaged the official bundle, no rebuild would be
  needed; **but we apply patches, so we must rebuild**.
- Practical pitfalls: downloading from dist **requires `?token=Isabelle`** (otherwise 403); **`isabelle getenv -o` does
  not exist** (write `$ISABELLE_HOME_USER/etc/preferences` as build_release does); **`isabelle process` does not exist in
  the release bundle**.

#### ✅ **The macOS GUI can be tested in CI** (measured by a probe 2026-07-15, overturning the earlier "cannot be tested" judgement)

> Earlier this place said "macOS runners are headless, the GUI cannot be tested", based on the official documentation
> and [#8951](https://github.com/actions/runner-images/issues/8951).
> **That judgement is wrong for `macos-14`.** Job G's probe (`launchctl print gui/$(id -u)` + `screencapture -x`)
> measured:
> ```
> RESULT: screencapture SUCCEEDED -> PNG image data, 1920 x 1080, 8-bit/color RGBA
> macOS runner HAS a usable window server
> ```
> **The `macos-14` runner has a usable window server; the screenshot succeeded.** So a real jEdit screenshot check like
> on Linux/Windows is **feasible**.

**Lesson: probe first, assert afterwards.** That probe was deliberately made to "never turn the job red, only print what it
measured", precisely to turn "unknown" into "measured" — and the answer it measured was **the opposite** of the online
sources + my earlier inference.
Had we hard-coded "the macOS GUI cannot be tested" straight from the documentation, we would have permanently missed a
platform we could cover.

**Verified**: macOS's CLI, both heaps, a real build (asserting that HOL is not rebuilt), osx-64 really running x86
through Rosetta (§ see verify_install's 2b assertion).
**GUI**: that the runner has a window server is confirmed; a real jEdit screenshot check is **to be wired in** (Linux's
`verify_gui.sh` drives Xvfb; macOS has a real window server and needs no Xvfb, so the launch path has to be written
separately: jEdit goes through Quartz).

### 5.4 CI vs release: architecture decision (**option A**)

**Principle: publishing is nearly irreversible** (once a package is on the channel, users may already have pulled it; it
can neither be deleted nor overwritten)
⇒ **Publishing must never be a side effect of a push; it must be a deliberate act.**
That act is dispatching `release.yml` by hand (workflow_dispatch) — it still runs in Actions, it is just **not triggered by
a push**.
Pushing a tag does not publish: a tag cannot carry inputs (the build number), so it could only publish the defaults.

```
.github/workflows/
  build.yml    ← reusable (on: workflow_call): defines all the jobs (§5.5). Defined only once.
  ci.yml       ← on: push / pull_request   → calls build.yml → local verification → done. **Never touches the channel**
  release.yml  ← on: workflow_dispatch → calls build.yml → local verification
                 → upload to R2 → post-publish check
```

**Why "rebuild at release time" (option A) and not "promote the CI artifacts" (option B)**:
- the release process is **self-contained and stateless**; it does not depend on "whether some CI run still exists";
- what goes out **is guaranteed to be the bytes just verified in the same run**;
- the cost of rebuilding is entirely acceptable for a release rhythm of **a few times a year** (about 2–4 hours when we
  compiled the heaps ourselves; from 2026 on no heaps are compiled, and only downloading, packaging and the install checks
  remain);
- this is also **the mainstream way** in the PyPI/cargo ecosystems.
- **When to switch to B**: when releases become frequent, or the uncertainty of rebuilding starts to bite. Not needed now.

#### Verification split in two (**neither half is affected by CDN delay**)
| What is verified | How | Where |
|---|---|---|
| **whether the package is right** (recipe, dependencies resolve, it installs, `isabelle version` runs, the heap loads) | **install from a local channel directory**: `conda create -c file:///.../channel` | **CI** (deterministic, no network) |
| **whether the bytes were uploaded correctly** | HTTP GET that `.conda` directly and compare the sha256 (**`.conda` is not cached by the CDN, always fresh**) | **release process** |
| whether the channel index is fresh | no need to care; the CDN catches up by itself (§3.3) | — |

#### Release credentials
- **`CONDA_R2_ACCESS_KEY_ID` / `CONDA_R2_SECRET_ACCESS_KEY` / `CONDA_R2_TOKEN_VALUE` have been set as GitHub secrets of
  `isabelle-packaging-ci`**, and `release.yml` uses them on `ubuntu-latest` to `rclone sync` to R2.
- Security surface: public repository ⇒ **PRs from forks cannot get the secrets** (enforced by GitHub); only people with
  write access can dispatch; the R2 token **can write only the one bucket `conda`**.
- ⚠️ Shortcoming: **Cloudflare R2 has no GitHub OIDC federation** (AWS does) ⇒ only **long-lived keys** can be used.
  Mitigation: least privilege + rotation when needed.

#### GitHub artifacts (measured/checked)
- **Actions and artifacts are free for public repositories** (official: *"GitHub Actions usage is free for public
  repositories that use standard GitHub-hosted runners"*) ⇒ GB-sized outputs do not use up a paid quota.
- **Retained for 90 days** by default (public repositories can set 1–90 days).

### 5.3 Runner disk (measured on CI, 2026-07) — **risk resolved**

Our peak need: **`ISABELLE_TMP` about 22 GB + the build tree about 8 GB ≈ 30 GB occupied at the same time**.

| Runner | Available out of the box | 30 GB peak, measured | Action |
|---|---|---|---|
| `ubuntu-latest` | **89 GB** (145G root disk) | ✅ succeeded, 59 GB left | **nothing to do** |
| `ubuntu-24.04-arm` | **110 GB** | ✅ succeeded, 80 GB left | no need to free space; but **the disk is 2.5 times slower** (170 vs 430 MB/s) |
| `windows-latest` | C: 33.5 GB / **D: 147 GB** | RUNNER_TEMP is already on D: | ⚠️ see the 🔴 below — **setting `TEMP`/`TMP`/`TMPDIR` has no effect; you must set `LOCALAPPDATA`** |
| `macos-14` | **only 40 GB** (Xcode takes 263 GB) | only 10 GB left, too risky | ⚠️ **the extra Xcodes must be deleted** (measured: 90 seconds frees 42 GB → 82 GB) |

**Two circulating claims overturned by measurement:**
1. **"A runner has only 14 GB"** — that is the **lower bound GitHub guarantees**, not reality; the root disk is now **145
   GB**.
2. **"`/mnt` is a separate 74 GB temporary disk"** — **outdated**. `/mnt` is now just an empty directory on the root
   partition, and `/dev/sdb1` does not exist.

**This also settles that pitfall from the local machine**: **on the runner, `/tmp` is on the 145 GB ext4 root disk, not a
tmpfs** ⇒ on Linux, `ISABELLE_TMP_PREFIX` being hard-coded to `/tmp/isabelle-$USER` **is not a problem on CI and need not
be overridden**.

**Defensive measure**: GitHub promises only 14 GB ⇒ add a `df` assertion before starting, and run the cleanup only below a
threshold (deleting preinstalled toolchains by hand with `rm -rf` measured **33 GB freed in 25 seconds**, much faster than
the 3–5 minutes of `jlumbroso/free-disk-space`).

**A larger runner is neither usable nor necessary**: personal accounts cannot use them + public repositories are charged
for them, and its 150 GB ≈ the 145 GB of a standard runner.

⚠️ **`macos-14` has only 3 cores / 7 GB of memory** — and it also has to build the HOL heap ×2 (both architectures),
**which is slow and may run short of memory**.

### 5.5 The matrix from 2026-10-31 on (Isabelle2026)

What each job does and why is defined by the header of `.github/workflows/build.yml` and the comments of each job; here we
list only the shape:

```
tests              [ubuntu-latest]   the unit tests of tests/; conda waits for them to pass
bundles            [ubuntu-latest]   download the five official platform bundles, check them against releases/<R>/SHA256SUMS → one artifact
conda              [ubuntu-latest]   scripts/pack.sh makes the conda packages one by one (including check_pristine.py's assertions)
                                     → install linux-64 from a local channel and really run it; the user directories of two environments of the same name; the post-link re-run
install-macos      [macos-15, macos-15-intel]   osx-arm64 and osx-64 are each installed and run on a native machine (with a GUI check on arm in addition)
install-linux-arm  [ubuntu-24.04-arm]   linux-aarch64: install, run, GUI check
install-windows    [windows-latest]  win-64: install, the first `isabelle` call (Cygwin's initialization, with a negative control for failure), the post-link re-run (.bat)
```

This document and the comments always call these jobs by their job id (the left column of the table above), not by
letters (owner, 2026-11-01).

No more heap compiling: the Pure and HOL heaps that come with the official bundles are the official default 32_in_64
variant (`x86_64_32-*`, `arm64_32-*`), and go into the package as they are.
From 2026 on, macOS has two official bundles (`_macos` is Intel, `_macos_arm` is arm), each matching one osx subdir.
`release.yml`, as before, first runs the whole `build.yml`, then publishes, then smoke-tests from the live channel (five
platforms, pinning the build just published and checking `ISABELLE_ID`).

---

## 6. conda package structure (design, not implemented)

```
<metapackage>                   noarch, depends on everything below (name to be decided, without the aoa prefix)
├── isabelle                    per-platform, version 2025.2  ← our patched Isabelle (with a prebuilt HOL heap)
├── <component package>          noarch generic  ← the .thy/.ML/jar of the six repositories + component configuration (name to be decided)
├── isamini                     noarch python
├── isabelle-rpc               noarch python
├── isarepl                     noarch python
└── isabelle-semantic-embedding per-platform (the only one with a native wheel)
```

- **channel**: `https://conda.qiyuan.me` (R2 bucket `conda`, see §3.3).
- **The `isabelle` package = option A (all files inside the package)**, not a post-link download (see §3.1).
- version **`2025.2`**; the upstream changeset + a patch identifier go into the build string; changed content bumps the
  build number.
- **Prebuilt heaps**: `Pure` + `HOL` + **`Main`** (`-b HOL,Main`). `Main` is only 3.8 MB (heaps are hierarchical deltas,
  see §3.5).
  **AoA's own session heaps (the `Minilang_AoA` chain) are not prebuilt for now** — users build them on first use
  (confirmed acceptable).
  If we want to prebuild them some day, **size is no obstacle** (they are deltas too); the cost is only CI time.
- Heavy native dependencies (torch/faiss/CUDA) are pulled from conda-forge; we do not produce them.
- ⚠️ **The faiss blas-variant pitfall**: the conda solver may randomly install a faiss build that lacks mkl → import
  crashes. We must pin `libblas=*=*openblas` (or install the complete mkl). (Note: PyPI's `faiss-cpu` wheel bundles
  openblas and does not have this pitfall.)

### 6.1 Alternative distribution form: tarball (conda-pack / uv + venv-pack)

"Vendor everything → one tar per platform → unpack and use, no activation" is also entirely feasible, and it **naturally
satisfies "usable without installing conda"**:
- Python side: **`uv`** (can bring a standalone relocatable CPython) + `venv-pack`; or conda + `conda-pack`.
- Cost: **one tar per platform** (Python native extensions and heaps are both platform-specific; no way around it).
- **No conflict** with the conda packages: the same build outputs can both be published to the channel and attached as
  release tars.

---

## 7. Known pitfalls and countermeasures

| Pitfall | Countermeasure | Status |
|---|---|---|
| **patches not committed are dropped by `hg.archive`** | must `hg commit`, then use `-r REV'` | built into the process |
| **`build_doc` needs a complete TeX Live** | install it only in the archive job (`texlive-science` with stmaryrd, `texlive-latex-extra`, `latexmk` …) | solved |
| **`/tmp` is a tmpfs and cannot hold `ISABELLE_TMP`** | `build_heaps` tars the whole bundle+contrib into `ISABELLE_TMP`, **measured peak 22GB**. On Linux `ISABELLE_TMP_PREFIX` is hard-coded to `/tmp/isabelle-$USER` (`TMPDIR` takes effect only on Windows) ⇒ **override `ISABELLE_TMP_PREFIX` in the user settings to point at a big disk** | solved |
| **user-settings clash** | the release name makes `other_isabelle`'s `ISABELLE_HOME_USER` collide with the real configuration of an Isabelle already installed on the build machine ⇒ use an **isolated HOME**. A clean CI runner does not have this problem | solved |
| **component version drift** | must use **the `Admin/components/main` that comes with that rev**, not the mirror's tip | known |
| **Windows `.bat` console hang** | detach with `start ""`, or run the GUI through the official launch4j exe | **to be fixed** |
| **the one-time `-init` on Windows** | a conda/tar install bypasses the SFX AutoInstall ⇒ must be done explicitly; least hassle is to run `-init` on the build machine, then package | known |
| **Session 0: window-title assertions are unusable** | the CI's GUI test **must rely on screenshots**; a deterministic assertion can only check that the process is alive | ✅ **implemented** (see §7.10) |
| **no `7zz` on Ubuntu** | `7zz` is the executable name of 7-Zip's **upstream** distribution. Debian/Ubuntu's `7zip` package (23.01+dfsg) installs a **p7zip-style `7z`** (`dpkg -L 7zip` → `/usr/bin/{7z,7za,7zr,p7zip}`, **no `7zz`**). ⇒ When unpacking the Windows SFX `.exe`, **do not hard-code the name**: `SEVENZIP=$(command -v 7zz \|\| command -v 7z)` | solved |
| **rattler-build runs the recipe tests across platforms by default** | the default is `--test native-and-emulated`. When packaging **win-64** on Linux it runs `isabelle.bat version` → **127** → and **quarantines a perfectly good package into `broken/`**. ⇒ **must use `--test native`** | solved |

### 🔴🔴 `cmd && echo ok` under `set -e` is a **fake guard that can never fail**

This line in `build.yml` was meant to "verify that 7zz is usable":
```bash
7zz i > /dev/null && echo "7zz: $(7zz | head -2 | tail -1)"
```
**It cannot do that.** bash's `set -e` **exempts every command of an `&&`/`||` list except the last**.
So when `7zz` does not exist, the whole line just silently returns nonzero, and **the step is still green**.

The actual consequence (run `29208082084`): `command not found` **was already printed in the install step**, and swallowed;
the real explosion was postponed to `pack.sh` **25 minutes later**, by which time the first 4 packages had already been
built (wasted work).

**Rule: a guard must be written in a form that can make the step fail.**
```bash
command -v 7zz >/dev/null || command -v 7z >/dev/null || { echo "::error::no 7z binary"; exit 1; }
```
When writing a CI check, **first ask yourself: when the thing checked is missing, does this check really turn the step
red?** If not, it is decoration.

**Another form of the same disease: cross-platform recipe tests are either fatal or fake.**
When rattler-build packages **osx-64 / osx-arm64** on Linux, the test takes the unix branch and runs the macOS package's
bash script **on Linux**. And `isabelle version` only echoes a settings variable —
**it "passes" without touching any Darwin binary at all**. Those two green ticks in the CI log **proved nothing**.
⇒ Use `--test native`. The real acceptance relies on build.yml's install checks (the `conda` and `install-*` jobs: install
into a conda env + really build a session + judge a GUI screenshot), which are much stronger than in-recipe tests.

## 7.10 ✅ GUI verification: Xvfb + jEdit + Claude Code judges the screenshot (implemented and verified locally)

`scripts/verify_gui.sh` (CI repo). **The GUI is the only place headless assertions cannot reach** —
`isabelle version` and `isabelle build` **still all pass** on a package "whose jEdit dies as soon as it starts".

**The criterion is not "a window appeared" (an empty window satisfies that).** The theory holds **one lemma that must
succeed + one that must fail** (`2+2=5`), and the error marker is required to land **exactly on the line that should
fail**. Only this upgrades "the interface rendered" to "the prover really checks proofs through the GUI". A negative
control was done (empty screen → the model answers `started: no`).

- **Authentication uses only `CLAUDE_CODE_OAUTH_TOKEN`** (`claude setup-token`, on the **subscription quota**).
  🔴 **Never set `ANTHROPIC_API_KEY`** — it has **higher priority** in Claude Code's authentication chain, and setting it
  silently switches from the subscription to metered billing.
- **Rate limiting does not mean the package is broken.** The subscription quota **shares one pool** with the owner's
  interactive use (measured: it has been used up).
  ⇒ **Only "the model gave a verdict and the verdict is bad" may turn the CI red; "the model could not give a verdict"
  (rate limit / logged out / API failure) is only a `::warning::`.** A really broken GUI always comes back in the form
  `structured_output.started = "no"`, so no discriminating power is lost.
  【From 2026-11-01 on (owner): at release time (`release.yml` passes `require_gui_verdict: true`) a GUI check without a
  verdict fails, and the release stops before the upload; the model answering `unclear` for the `bad`/`good` lines also
  counts as no verdict. `ci.yml` still only warns. The remedies are in step 3 of `RELEASE.md`; the rule is written in
  `gui_judge.sh`'s `unjudged`.】
- ~~**The `ML_system_64` must be inferred from the package's heap directory name and written into the preferences of
  the temporary HOME.**~~【Void from 2026-10-31 (item 13: the official default 32_in_64 heaps go into the package as they
  are, so there is no variant to pin; and those preferences were written into a directory that the Isabelle in conda never
  reads), `pin_ml` has been deleted.】 When the variant does not match, Isabelle **does not warn; it silently rebuilds
  HOL**, and jEdit builds it in a **GUI dialog** whose output **does not go into `jedit.log`** ⇒ the screenshot check would
  **pass, all green, falsely**, while the package's heap is not used at all.
  So the script asserts that the `Isabelle build` dialog must not appear; `verify_install.sh`'s real build asserts that
  HOL is not recompiled.
- The headless build's `Building HOL` check and the GUI screenshot check **complement each other and cannot replace each
  other**: the former is deterministic and needs no model in the loop; the latter covers the jEdit path. **Keep both.**

---

## 7.9 ✅ Settled: **apply only the `user` category of patches** (confirmed by the owner 2026-07-12)

【Void from 2026-10-31 on: the `isabelle` package applies no patches at all, §11.】

**Decision**: the released Isabelle **applies only the `user` category of `my-better-isabelle-prover`**.

- **`by aoa` does not need `register_thy`** (confirmed by the owner — the earlier inference "AoA needs register_thy" was
  wrong).
- **The conda package of `Isa-REPL` applies the `register_thy` patch automatically in its own install script** (its own
  special handling, not the isabelle package's business).
  ⚠️ Note: that changes Pure's ML sources ⇒ **the heaps go stale and are rebuilt on demand** (Isabelle handles this
  automatically, but on first use users have to wait for HOL to be rebuilt).

### 🔴 CI must install the patch tool from the **git source**, not from PyPI

```
git log:  593f64b  expose_foreign     ← added after 0.2.0
          666327c  Release 0.2.0      ← the only one on PyPI
local:    0.3.0 (has categories.toml + --category)
```
⇒ **PyPI's 0.2.0 has neither `--category` nor `expose_foreign` (one of the three user patches).**
⇒ In CI, change it to **`pip install git+https://github.com/xqyww123/my_better_isabelle_prover`**
(which gets 0.3.0: categories + expose_foreign). Once 0.3.0 is on PyPI we can switch back.

### 🔴🔴 Unresolved conflict: **someone else is removing `pide_control` + `perspective_eof_clamp` from 2025-2**

The local working tree of `my_better_isabelle_prover` has **staged but uncommitted deletions** — another agent is retiring
these two features.
Its commit `37c2848` says explicitly: on Isabelle2025-2, the default `patch` **"applies exactly one pure-ML patch,
`expose_foreign`"**.

| Point in time | the `user` set (2025-2) |
|---|---|
| **now** (git remote HEAD) | `pide_control` (5 files) + `perspective_eof_clamp` (1) + `expose_foreign` (1) = **7 patches** |
| **once that agent pushes the retirement** | **only `expose_foreign` remains** (1 pure-ML patch) |

**Consequence**: the CI's assertions (which check that `theory_status`/`cancel_execution` made it into the sources and the
jar) **will suddenly fail and the build goes red**
— this is **a loud failure, not a silent error** (a good thing), but **we must first decide which one is intended**:

- **(a)** the released package carries `pide_control` + `perspective_eof_clamp` + `expose_foreign`
  ⇒ that agent must be asked **not to push the retirement**, or the CI must **pin a commit**.
- **(b)** the released package **carries only `expose_foreign`**
  ⇒ **Isabelle-MCP's PIDE extensions no longer go into the released package**; the CI's assertions must change
  accordingly.

**⇒ Awaiting the owner's decision.**

### Category table (`patches/categories.toml`)

| category | features | Purpose (the tool author's own words) |
|---|---|---|
| **user** | `pide_control`, `perspective_eof_clamp`, `expose_foreign` | *"needed by the user-facing systems (Isabelle-MCP; Semantic_Embedding's SIMD FFI)"* |
| **dev** | `register_thy`, `show_types_nv`, `expose_map_syn` | *"needed only by developer/experiment infrastructure (Isa-REPL, Isa-Mini's translator, AoA agent injector)"* |

CLI: `--category {user,dev,all}`, **and the default is `user`** (from 0.3.0 on).

### Two problems that must be solved first

**① PyPI has only 0.2.0, without the category feature**
In CI, `pip install my-better-isabelle-prover` → installs **0.2.0** → **applies all 6 patches**.
⇒ To apply only user, **0.3.0 must first be published to PyPI** (that repository is maintained by **someone else**),
**or** the CI must install from the git source.

**② Applying only user ⇒ the released Isabelle does not support `by aoa`**
`register_thy` is in the **dev** category, and it is **a hard dependency of Isa-REPL**; Isa-REPL in turn is in the AoA
chain (`Minilang_AoA = Minilang + Isa_REPL + …`).
⇒ **A package with only the user patches is aimed at Isabelle-MCP + Semantic_Embedding users, not at AoA.**
AoA users have to run `patch --category all` themselves.

**⇒ Awaiting the owner's confirmation: is this what is intended?** If so, the positioning of the release must be
adjusted accordingly (this document's §1 "Goal" says "so that users can `by aoa`", which contradicts it).

---

## 7.11 🔴 The patch tool **must be pinned**, and **the full procedure for updating the patch set**

【Void from 2026-10-31 on: the CI no longer installs the patch tool, and `MBI_VERSION` and `scripts/check_patch_sync.sh`
have been deleted, §11.】

**The former way (wrong)**: `pip install "git+https://github.com/xqyww123/my_better_isabelle_prover"`
— **no pin, it takes HEAD**. Consequence: whenever someone pushes to that repo, **the Isabelle we release quietly
changes**, while the package **still has the same name** (see below). The build is not reproducible.

**Now**: `MBI_VERSION="0.3.0"` in `build.yml`, installing **a fixed version from PyPI** — PyPI versions **are immutable**,
which is exactly what a release needs. (Note that the CI **does not look at** the submodule pin in `MLML`; that is for
local development.)

### 🔴 Why "changing the patch set" must **also** bump `build_number`

For MAX_PATH, conda's build string was shortened from `<hg-changeset>_<n>` to **just the build number**
(`recipe.yaml:30-43`, saving 12 characters). ⇒ **When the patch set changes, the package name is still
`isabelle-2025.2-0`.** conda **cannot tell that it is a new package**.

**The safety net**: `release.yml` **refuses to overwrite a published filename** ⇒ if you forget the bump, **the release
fails loudly**, instead of silently giving users old bytes. **This is by design, not by coincidence.**

### The full procedure for updating the patch set → **see `RELEASE.md`**

In one sentence: change the patches → **publish a new version to PyPI** → bump `MBI_VERSION` → bump `ISA_BUILD_NUMBER` →
trigger `release.yml`.

**The only mistake that really bites: the patches were changed only locally and not published to PyPI.**
The CI installs a fixed version from PyPI and **does not look at** MLML's submodule ⇒ patches that work for you locally
**never reach users**, while the CI is all green and the package goes out as usual. The classic "works on my machine".
The first item of `RELEASE.md` is there to stop exactly this.
(The reverse, "local is behind the published version", **is not a problem** — you are the source of the changes.)

## 8. To-do list

【The list as of 2026-07, kept as a record; the CI, recipe and GUI check items in it landed long ago.】

| # | Item | Status |
|---|---|---|
| A | fix the `isabelle.bat` console hang (detach) | ✅ **done** (§3.6, `run.exe` + a getopts replica, 27/27 acceptance) |
| B | test the `-S` build on Windows | ✅ **done — the conclusion is "there is no Windows packaging job at all"** (§5.0) |
| G | macOS dual-architecture verification | ✅ **done** (§5.2, a single `macos-14`, HOL×2 = 1h44m) |
| — | GitHub runner disk | ✅ **done** (§5.3, risk resolved) |
| — | conda channel on R2 | ✅ **working end to end** (§3.3, including the serious CDN pitfall and its fix) |
| **C** | **set up the CI** (Job A–F of §5.1 + the three workflows of §5.4) | 🔄 **Job A ✅ ran green; Job B–F to do** |
| C-A | **Job A (bundles for all platforms, no heap) — ✅ ran and verified on real CI** | run [`29201707387`](https://github.com/xqyww123/isabelle-packaging-ci/actions/runs/29201707387) success **33m20s**, output **5.8 GB**; step (8) verified `ISABELLE_ID` + **the patches are in `isabelle.jar`** + **the Windows `.exe` is cross-built from Linux**; `hg clone` is cached (skipped by later runs) |
| C1 | ⚠️ the only thing not verified: **building the heap natively on a Windows runner** | to verify (can be tried directly in Job E) |
| **J** | 🔴 **make `isabelle.bat` self-locating + move it into `<ISABELLE_HOME>\bin\`** (now it hard-codes the path and **cannot go into a conda package**); measure recursion and relocatability | 🔄 **in progress** |
| E | conda recipes: the `isabelle` package (the bundle inside the package) + component packages + Python packages + metapackage | to do |
| F | the CI's GUI screenshot test (Session 0 ⇒ **window-title assertions are unusable; the screenshot is the ground truth**; optionally Claude Code judges the image, suggested as advisory at first) | to do |
| H | AFP is not yet handled in the packaging plan | to do |
| I | Cloudflare dashboard: Browser Cache TTL → Respect Existing Headers; Bypass cache for the `repodata` path (**needs zone permissions; has to be clicked by hand**) | to do |

> **D (adding a `build-release` subcommand to `my_better_isabelle_prover`) is cancelled** — that repository is
> maintained by **someone else**.
> The orchestration goes into **our own** `isabelle-packaging-ci`, which calls the patch tool as a **black box**
> (`pip install my-better-isabelle-prover` + `my-better-isabelle patch`).

**Infrastructure (ready, reusable)**
- **Windows 11 QEMU VM**: `/home/qiyuan/qemu-win/`, `./run-win-vm.sh` → after ~20 seconds it can be driven
  non-interactively with `ssh -i ssh/id_win -p 2222 isabelle@localhost`; screenshots are possible (QEMU monitor
  `screendump`).
  **Real GUI verification that the CI cannot do can only be done here.**
- **CI repository**: `xqyww123/isabelle-packaging-ci` (kept long-term).
- **Linux build prototype**: `/home/qiyuan/isa_release_proto/` (hg clone + the patched tree + outputs).

---

## 9. The overturned old plan (archived + reasons it was overturned)

> The old plan: **do not release Isabelle, but reuse the Isabelle that users already have installed**; the conda packages
> carry only the AoA components, and a post-link writes the component paths into the user's global
> `$ISABELLE_HOME_USER/etc/settings` (`init_component`), so that "it works without activating conda".

**Why it was overturned:**

1. **conda does not track these side effects at all**: whatever a post-link writes outside `$PREFIX`, `conda remove` does
   not delete and `conda list` does not show; and the `pre-unlink` the cleanup depends on **is not guaranteed to run** (it
   does not run when an env directory is deleted) ⇒ users' Isabelle may be polluted forever. The industry has already
   voted with its feet: `cudatoolkit-dev`, which downloads in post-link, **has been archived and abandoned**.
2. **The patches cannot be avoided**: AoA needs a patched Isabelle (`register_thy` is a hard dependency of Isa-REPL).
   And **patching users' own Isabelle in place** is not only a deeper version of the same "untracked side effect" problem
   (changing a foreign source tree + needing a recompile + needing to rebuild heaps), but **no package manager endorses
   such a thing** — when any package manager "supports patches", it always means "**patching sources that I build
   myself**" (Nix/Homebrew/Debian/RPM/conda-build all do it this way). To get package-manager-level cleanliness, the only
   way is to **distribute a patched Isabelle that we build ourselves**.
3. **The heaps cannot be avoided either**: the official bundles ship a prebuilt HOL heap; we change Pure/ML ⇒ we cannot
   reuse the official heaps ⇒ we must rebuild them ourselves for each platform (§3.5). That already amounts to "running
   the release process ourselves".

**Conclusion**: "reuse users' Isabelle" looks convenient, but in fact it pushes all the dirtiest work (change in place +
recompile + rebuild heaps + untrackable + unreliable cleanup) onto the post-link; whereas "release a patched Isabelle
ourselves" moves that work to **the CI's build time**, and the output is a complete package that is clean, trackable and
reproducible. The latter is the right way.

---

## 10. Related documents

- `AOA_DESIGN.md`, `CONDA_ISABELLE_BRIDGE.md`, `RELEASE_PLAN.md` — **products of the exploration phase, all superseded
  by this document**, for archaeology only.
- `contrib/my_better_isabelle_prover/` — the patch tool `isabelle-patch-control` and the release of the feature packages
  (§11); decision 12 of its `ai-artifacts/ISABELLE_PATCH_CONTROL_PLAN.md` is the set of requirements on this repository.
- `contrib/Isabelle_RPC/Isabelle_RPC_Host/paths.py` — Windows path normalization (commit `5b9580c`).

---

## 11. The unpatched build and feature packages (from 2026-10-31 on, Isabelle2026)

### 11.1 What the `isabelle` package is

- **The official platform bundles as they are.** The CI downloads the five platform bundles from
  `https://isabelle.in.tum.de/website-<R>/dist/` and checks them against `releases/<R>/SHA256SUMS` (the values the
  Isabelle site publishes, registered in the repository once per release); `etc/ISABELLE_ID` must equal
  `releases/<R>/ISABELLE_ID` (the official changeset).
  We no longer run `build_release` ourselves (owner, 2026-10-31): without patches there is no reason to build it
  ourselves, and checking "the same as the official one" requires downloading the official bundles anyway.
- **The heaps are the official ones** that come with the bundles, Pure and HOL, i.e. the official default 32_in_64 variant
  (`ML_system_64 = false`), and they go into the package as they are (owner, 2026-10-31).
- On **macOS**, `isa/` is the official app's `Contents/Resources/` (i.e. `ISABELLE_HOME`); the app's shell (launcher,
  `Info.plist`) does not go into the package.
- **The differences from the official tree** — which files, the file contents, symlink targets — are defined by
  `EXPECTED` in `scripts/check_pristine.py`, and every package is asserted against it once it is built: a difference not
  on the list fails, and so does an entry on the list that is not used. The official empty directories must appear in the
  package as the empty marker file `.conda-keep` (a conda package has no directories). File permission bits are not
  compared (the script's description says why). The reason for each change is in the comment of the corresponding step of
  `scripts/pack.sh`, and is not repeated here.
- **Only Isabelle2026 and later are supported** (owner, 2026-10-31). The steps for adding a new release are in step 0 of
  `RELEASE.md`. The version is derived by `pack.sh` (`Isabelle2026` → `2026`).
- The release note required by point 8 of decision 12 of the patch tool plan ("`Foreign`, `RunCall`, `CInterface` are
  gone from the unpatched Isabelle") is not written from 2026 on: the unpatched Isabelle2026 itself provides `Foreign`
  (owner, 2026-10-31).

### 11.2 Exception (owner ruling 2026-10-23): feature packages rewrite `$PREFIX/isa` through post-link

The principles of §3.1 and §9 — everything ships inside the package, a post-link creates nothing that conda does not
track, users' Isabelle is not patched in place — still hold for the **contents** of the `isabelle` package: from now on
it is an unpatched build, carrying no patches at all. Patches are distributed by feature packages instead, one conda
package per feature (isabelle-expose-foreign, isabelle-light-locale, …), which isabelle-patch-control applies to
`$PREFIX/isa` in the package's post-link and reverses in its pre-unlink. The `isabelle` package's post-link takes part in
this exception too: it re-runs the post-links of the installed packages that depend on it directly
(`conda/rerun_post_links.py`). This step is necessary because when `isabelle` is reinstalled (`--force-reinstall` or an
upgrade to a new build), conda re-links every file of the package, and the patches the features applied in `$PREFIX/isa`
are gone with it; the `isabelle` package's pre-unlink in addition deletes the whole Isabelle user directory, the
component registrations included (`conda/recipe.yaml`); and conda runs only the hooks of the packages replaced in the
current transaction: after `--force-reinstall isabelle`, only `isabelle`'s own post-link has a chance to bring the
features and the registrations back; after an upgrade to a new build, the feature packages are replaced along with it and
re-patch through their own post-links, and only the component registrations still rely on `isabelle`'s post-link to be
restored. It is written in Python (so the `isabelle` package depends on python, and installing it needs
`-c conda-forge`); this is a deviation from the §3.1 principle "a post-link does nothing", of the same kind as the
component packages' `components -u` hooks. This is a deliberate exception to §9, for these reasons:

1. The package manager manages the patches, and users decide for themselves which patches to install: install
   isabelle-light-locale and you have light locale, do not and you do not; the dependencies (light depends on
   future_assign_interrupt, which depends on expose_foreign) are guaranteed by the conda solver, the versions by exact
   pins, and each feature package also pins exactly the `isabelle` build it is made for.
2. The `isabelle` package stays pristine: the invariant that can be checked is that Isabelle's sources are the same as
   the official release and that `etc/ISABELLE_ID` is the official changeset, which the CI guarantees with assertions
   (§11.1). The only differences from the official release in files and contents are the packaging changes, and their
   list is `EXPECTED` in `scripts/check_pristine.py`; the heaps are the official ones.
3. The authority for the patches is the git repository of the Isabelle sources (the migration plan); the feature packages
   are generated automatically from the diffs between release tags, and the release gate guarantees that the round trip
   is consistent.

Boundaries and costs:
- Only the tree `$PREFIX/isa` that the channel itself publishes is changed. An Isabelle that users installed themselves
  is not supported (outside a conda environment, the tool runs only when it is given the feature directory explicitly).
- conda does not track the files a feature creates (light has three); they disappear when the pre-unlink reverses the
  feature successfully, which is the same kind of thing as a component package unregistering its own registration with
  `isabelle components -x` (RELEASE_CHECKLIST.md §4). Changes left behind when the pre-unlink cannot reverse everything
  are written by the hook, on the spot, into .messages.txt (the list of files and the steps to recover, written for two
  cases: "this command removes it" and "this command replaces it"); after the package is removed (rather than replaced),
  status cannot see them.
- The heaps that come with `$PREFIX/isa` no longer match once a feature that changes `src/` is applied; Isabelle rebuilds
  them on first use into that environment's user directory; the owner accepted this.
- Every write of the tool to the tree is an atomic per-file replacement; if one of the tool's own commands is
  interrupted, it leaves only a state in which "some files are already at the new level", and running apply or unapply
  once more completes it. If a conda transaction is interrupted (Ctrl-C) or some post-link fails, conda rolls back the
  whole transaction (conda prints `Rolling back transaction`): the package is withdrawn, and the changes a post-link has
  already written stay; the recovery is to reinstall `isabelle` (which replaces every file of the package and re-applies
  the installed features, at the cost of deleting that environment's user directory).
- `--force-reinstall isabelle` replaces every file of the package and deletes that environment's user directory. The
  sources under `$PREFIX/isa` are all managed by conda; users do not change them.
- Hooks always exit 0 (the rule of RELEASE_CHECKLIST.md §4 is unchanged), and the exit 0 is written in the hook text
  rather than left to the tool. The two contracts are in RELEASE_CHECKLIST.md §4: a package whose post-link touches
  `$PREFIX/isa` or the Isabelle user directory must depend on `isabelle` directly; the post-link of a package that
  depends on `isabelle` directly must be safe to re-run at any time. A package that depends on `isabelle` only indirectly
  (isabelle-semantic-data) is not re-run.
- For every new `isabelle` build that is published, all feature packages must be republished with the new pins (the
  batch release workflow does it in one run); component packages do not pin the build and need not be republished.
