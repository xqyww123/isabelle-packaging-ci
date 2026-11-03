# Release steps of two packages that have not moved yet

How to release any package: the SKILL conda-release (`.claude/skills/conda-release/SKILL.md`). `RELEASE.md` sends
here for the steps of `isabelle-semantic-data` (item 3) and `isabelle-ai` (item 4).

## 9. Release

3. **`isabelle-semantic-data` is built on a big-memory machine, not on the runner**: rattler-build needs about twice
   the archive in RAM, and the payload is 19 GB. The runner still does everything else: `release-semantic-db.yml`
   takes the finished `.conda` through its `prebuilt` input and runs the unchanged sanity check, artifact handoff,
   immutability guard and smoke on it. The package is built from the owner's snapshot on Hugging Face, so what was
   synced is what ships, never a local database (the snapshot is uploaded beforehand, and only on the owner's order,
   by the SKILL sync-semantic-embedding-db). Then, on a machine with ≥ 40 GB RAM, ≥ 60 GB disk and a fast link (cslh19
   did it: export 1 min, rattler-build 8 min, upload 30 min):

   1. An environment with the **channel's own library**, so the export is the one CI would have run:

      ```sh
      micromamba create -p env --override-channels -c https://conda-ci.qiyuan.me -c conda-forge python=3.12 "isabelle-semantic-embedding>=0.3.0" huggingface_hub zstd
      ```
   2. Download the snapshot, with the cached HF token:
      `hf_hub_download(repo_id="ANTPG/MLML-data", repo_type="dataset", filename="contrib/Semantic_Embedding/Isabelle_Semantic_Embedding.tar.zst")`.
      The path it returns is a **symlink**: `readlink -f` it, since `zstd` refuses symlinked inputs and `stat` without
      `-L` reports the link's size. Check the size against MLML's `data/manifest.json`.
   3. `zstd -dc … | tar -x` somewhere with room, then export and delete the extracted database:

      ```sh
      SEMANTIC_DB_DIR=<the tarball's single top directory> env/bin/isabelle-semantics export payload
      ```
   4. Build with rattler-build at the version the workflow pins, on `conda/data/isabelle-semantic-data/recipe.yaml`
      from `main`, with `SEMANTIC_DATA_PAYLOAD` set to the absolute path of step 3's `payload` directory and
      `SEMANTIC_DATA_VERSION` set to the version of that payload's own `MANIFEST.json` (not MLML's
      `data/manifest.json`):

      ```sh
      env/bin/python -c "import json; from Isabelle_Semantic_Embedding.snapshot_sync import version_of_created_at as v; print(v(json.load(open('payload/MANIFEST.json'))['created_at']))"
      ```

      Pass `--build-num <N>` (the `build_number` you dispatch in step 6; 0 for a new snapshot), `--no-test` and
      `-c https://conda-ci.qiyuan.me -c conda-forge`, and put **`TMPDIR` on a real disk**: rattler-build stages the
      archive under `/tmp`, which on cslh19 is a 32 GB tmpfs that a 9 GB archive fills.
   5. Upload the `.conda` to the dataset `ANTPG/MLML-data` under `contrib/Semantic_Embedding/conda/`
      (`HfApi().upload_file(..., repo_id="ANTPG/MLML-data", repo_type="dataset")`, commit message naming the machine).
      This is a release artifact, not a dev-sync file: it is **not** added to `data/manifest.json`.
   6. One dispatch, started and watched by the SKILL conda-release, "7. Start and watch a run":

      ```sh
      gh workflow run release-semantic-db.yml -R xqyww123/isabelle-packaging-ci -f prebuilt=contrib/Semantic_Embedding/conda/<name>.conda -f build_number=<N> -f dry_run=false
      ```

      The sanity step fails when the package's version or build number disagrees with the manifest or with
      `build_number`. The build number is inside the uploaded `.conda`: when the SKILL gives a new run another build
      number ("8. The build number"), start again at step 3 (step 4 moved the payload into the package; the new export
      is a new version), build with that number, and upload the new file in step 5.
4. **`isabelle-ai` goes last, after the packages its floors name, and its floors are the channel's newest at that
   moment, every release, no exceptions.** The metapackage has no content: its `depends` list IS the release. Before
   dispatching `release-isabelle-ai.yml`, set each floor in `conda/metapackage/isabelle-ai/recipe.yaml`
   (`isabelle-minilang`, `isabelle-mcp`, `isabelle-semantic-data`) to the newest version published on the channel,
   whether or not the old floor "still works": a lagging floor means `conda update isabelle-ai` updates nothing and
   users never get the new versions. The floor edit is a release step, not a fix: commit it by the SKILL's "2.
   Rules", in a commit the owner approves, and push it to `main` before the dispatch; the dispatch builds `main`'s
   recipe, and the sanity step checks only the dependency names. A version already published whose floors must move
   is republished under the **same version** with the workflow's `build_number` input bumped (`publish-conda.yml`'s
   immutability guard refuses only an identical filename; `conda install isabelle-ai=X` takes the highest build).
